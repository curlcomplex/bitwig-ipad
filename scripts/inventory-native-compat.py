#!/usr/bin/env python3
"""Inventory local ARM64 Bitwig binaries against the compiled iPad host bridges."""
import argparse
from bisect import bisect_right
from collections import defaultdict, deque
from functools import cache
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
from compat_discovery import correlate_jvm, discover, match_bindings

TARGETS = {
    'launcher': 'MacOS/BitwigStudio',
    'jni': 'Frameworks/libbitwig-jni.jnilib',
    'engine': 'MacOS/Bitwig Audio Engine ARM64-NEON.app/Contents/MacOS/BitwigAudioEngine-ARM64-NEON',
    'plugin_host': 'MacOS/Bitwig Plug-in Host ARM64-NEON.app/Contents/MacOS/BitwigPluginHost-ARM64-NEON',
    'mac_jvm': 'PlugIns/JavaVM-arm64.bundle/Contents/Home/lib/server/libjvm.dylib',
    'native_foundation': 'Frameworks/JavaNativeFoundation',
    'sqlite': 'Frameworks/libsqlitejdbc.jnilib',
}
ADAPTED = {
    'jni': 'libbitwig-jni.jnilib',
    'engine': 'BitwigAudioEngine.bundle',
    'native_foundation': 'JavaNativeFoundation',
    'sqlite': 'libsqlitejdbc.jnilib',
    'jna': 'libjnidispatch.jnilib',
}
ROLES = {'launcher': 'replaced_by_uikit_host', 'mac_jvm': 'replaced_by_ios_jvm',
         'plugin_host': 'optional_desktop_plugin_host'}
LOOKUPS = {'dlopen': 0, 'dlsym': 1, 'NSClassFromString': 0, 'NSSelectorFromString': 0,
           'objc_getClass': 0, 'objc_lookUpClass': 0, 'sel_registerName': 0,
           'CFBundleGetFunctionPointerForName': 1, 'CFBundleGetDataPointerForName': 1}
SELECTOR_LOOKUPS = {'respondsToSelector:', 'instancesRespondToSelector:', 'methodForSelector:',
                    'instanceMethodForSelector:', 'performSelector:', 'performSelector:withObject:'}

# Receiver evidence is deliberately explicit. A selector reference alone cannot
# identify its receiver or even distinguish an instance send from a class send.
FRAME_SELECTOR = 'constrainFrameRect:toScreen:'


def xcrun(*args):
    return subprocess.check_output(['xcrun', *map(str, args)], text=True)


def dyld(flag, image):
    return xcrun('dyld_info', '-arch', 'arm64', flag, image)


@cache
def linked_libraries(image):
    lines = dyld('-linked_dylibs', image)
    result = []
    for attributes, path in re.findall(r'^\s{8}(.*?)\s+((?:@|/)\S+)\s*$', lines, re.M):
        result.append((attributes.strip(), path))
    return result


@cache
def imports(image):
    return [(symbol, bool(weak), library) for symbol, weak, library in re.findall(
        r'^\s+(?:0x[\da-fA-F]+\s+)?(\S+)\s+(\[weak-import\])?\s*\(from (.+?)\)\s*$',
        dyld('-imports', image), re.M,
    )]


def objc_metadata(image):
    classes = {}
    methods = defaultdict(set)
    entries = {}
    for line in dyld('-objc', image).splitlines():
        interface = re.match(r'\s+@interface (\w+)\s*(?::\s*(\w+))?', line)
        if interface and '(' not in line and ' : ' in line:
            classes[interface[1]] = interface[2]
        method = re.match(r'\s+0x([\dA-Fa-f]+)\s+([+-])\[(\w+)(?:\([^)]*\))? (.+)\]$', line)
        if method:
            site, kind, cls, selector = method.groups()
            methods[cls].add((kind, selector))
            if int(site, 16):
                entries[int(site, 16)] = kind, cls, selector
    return classes, methods, entries


def selector_slots(image):
    # Use actual __objc_selrefs slots, excluding method definitions and strings.
    refs = {}
    metadata = xcrun('otool', '-arch', 'arm64', '-ov', image)
    for segment in re.findall(r'^Contents of \(([^,]+),__objc_selrefs\) section', metadata, re.M):
        section = xcrun('dyld_info', '-arch', 'arm64', '-section', segment, '__objc_selrefs', image)
        refs.update({int(address, 16): selection for address, selection in re.findall(
            r'^0x([\da-fA-F]+)\s+"([^"]+)"', section, re.M
        )})
    return refs


def direct_dispatches(image, entries, slots, scope):
    """Resolve direct super calls with local selector and superclass evidence."""
    functions = sorted(int(match, 16) for match in re.findall(
        r'^\s+0x([\da-fA-F]+)\s+', dyld('-function_starts', image), re.M
    ))
    if not functions:
        return [], [], {}
    function_addresses = set(functions)
    instruction = re.compile(r'^0x([\da-fA-F]+)\s+(\S+)\s+(.*)')
    sends = []
    lookups = []
    registers = {}
    counts = defaultdict(int)
    recent = deque(maxlen=8)
    current = None
    with subprocess.Popen(['xcrun', 'dyld_info', '-arch', 'arm64', '-disassemble', str(image)],
                          stdout=subprocess.PIPE, text=True) as disassembly:
        for line in disassembly.stdout:
            call = instruction.match(line)
            if not call:
                registers.clear()
                recent.clear()
                continue
            address, opcode = int(call[1], 16), call[2]
            operand = call[3].split(';', 1)[0].strip().strip('"')
            if current != address and address in entries:
                current = address
                registers = {0: (entries[address][1], entries[address][0], 'method entry self')}
            elif address in function_addresses:
                registers.clear()
            if opcode not in ('bl', 'b'):
                destination = re.match(r'[xw](\d+)(?:,|$)', operand)
                if opcode.startswith('blr'):
                    registers = {key: value for key, value in registers.items() if 19 <= key <= 28}
                    recent.clear()
                elif opcode.startswith(('b.', 'cb', 'tb', 'ret', 'br', 'eret')):
                    registers.clear()
                    recent.clear()
                elif opcode == 'ldp':
                    for register in re.findall(r'[xw](\d+),', operand.split('[', 1)[0]):
                        registers.pop(int(register), None)
                elif opcode == 'stp' or opcode.startswith(('str', 'cmp', 'tst')):
                    pass
                elif destination:
                    register = int(destination[1])
                    origin = re.fullmatch(r'x\d+, x(\d+)', operand) if opcode == 'mov' else None
                    class_ref = re.search(r';.*\b_OBJC_CLASS_\$_(\w+)', line) if opcode == 'ldr' else None
                    literal = re.search(r';\s*"([^"]+)"', line) if opcode in ('ldr', 'add', 'adr') else None
                    if origin and int(origin[1]) in registers:
                        registers[register] = registers[int(origin[1])]
                    elif class_ref:
                        registers[register] = (class_ref[1], '+', 'class reference in disassembly')
                    elif literal:
                        registers[register] = (literal[1], None, 'annotated literal')
                    else:
                        registers.pop(register, None)
                recent.append(line)
                continue
            receiver = registers.get(0)
            arguments = registers
            if opcode == 'b':
                registers.clear()
            else:
                registers = {key: value for key, value in registers.items() if 19 <= key <= 28}
            if receiver and operand in ('_objc_alloc', '_objc_alloc_init') and receiver[1] == '+':
                registers[0] = (receiver[0], '-', receiver[2] + ' via allocation')
            if receiver and operand in ('_objc_retain', '_objc_retainAutoreleasedReturnValue'):
                registers[0] = receiver
            dispatch = operand.removeprefix('_objc_msgSend$') if operand.startswith('_objc_msgSend$') else None
            lookup = operand.removeprefix('_') if operand.removeprefix('_') in LOOKUPS else dispatch
            if operand in ('_objc_msgSend', '_objc_msgSendSuper2') or dispatch:
                counts['objc_direct_dispatch_instructions'] += 1
            if not dispatch and operand != '_objc_msgSendSuper2' and lookup not in LOOKUPS:
                recent.append(line)
                continue
            index = bisect_right(functions, address) - 1
            entry = entries.get(functions[index]) if index >= 0 else None
            kind, cls, caller = entry or (None, None, None)
            if lookup in LOOKUPS or lookup in SELECTOR_LOOKUPS:
                argument = arguments.get(LOOKUPS.get(lookup, 2))
                lookups.append({'address': hex(address), 'api': lookup, 'caller': caller,
                                'argument_status': 'inferred_literal' if argument and argument[1] is None else 'unresolved_from_direct_call',
                                'literal_candidate': argument[0] if argument and argument[1] is None else None})
            if dispatch == FRAME_SELECTOR and cls == 'BWWindow' and caller in {'moveInPixels:', 'windowDidExitFullScreen:'}:
                source = 'verified self dispatch in ARM64 disassembly'
                if caller == 'moveInPixels:' and scope == '6.1.4':
                    source += ' and observed 6.1.4 crash backtrace'
                sends.append((address, kind, cls, caller, FRAME_SELECTOR, 'self', source))
            elif dispatch and receiver and receiver[1]:
                sends.append((address, receiver[1], receiver[0], caller, dispatch,
                              'direct', receiver[2]))
            if dispatch and receiver and receiver[1] and opcode == 'bl':
                if dispatch in ('alloc', 'new') and receiver[1] == '+':
                    registers[0] = (receiver[0], '-', receiver[2] + ' via allocation')
                elif dispatch.startswith('init') and receiver[1] == '-':
                    registers[0] = receiver
            if operand == '_objc_msgSendSuper2' and entry:
                called = None
                address_register = None
                offset = 0
                for previous in reversed(recent):
                    prior = instruction.match(previous)
                    if not prior or int(prior[1], 16) < functions[index] or prior[2].startswith(('b', 'cb', 'tb', 'ret')):
                        break
                    if prior[2] == 'ldr' and not address_register:
                        load = re.match(r'x1, \[(x\d+), #(0x[\da-fA-F]+|\d+)\]', prior[3])
                        if load:
                            address_register, offset = load[1], int(load[2], 0)
                            continue
                    if address_register and prior[3].startswith(address_register + ','):
                        if prior[2] != 'adrp':
                            break
                        pages = int(prior[3].split(',', 1)[1].split(';', 1)[0].strip(), 0)
                        called = slots.get((int(prior[1], 16) & ~0xFFF) + pages * 0x1000 + offset)
                        address_register = None
                    elif re.match(r'[xw]1,', prior[3]):
                        break
                    if called and re.search(rf'\bsuper _OBJC_(?:META)?CLASS_\$_{re.escape(cls)}\b', previous):
                        sends.append((address, kind, cls, caller, called, 'super',
                                      'selector load and superclass reference in ARM64 disassembly'))
                        break
            recent.append(line)
        if disassembly.wait():
            raise RuntimeError(f'dyld_info disassembly failed for {image.name}')
    counts['objc_attributed_dispatch_instructions'] = len(sends)
    counts['dynamic_lookup_direct_calls'] = len(lookups)
    return sends, lookups, dict(counts)


def simulator_methods(simulator, classes):
    source = Path(__file__).with_name('inventory-objc-runtime.m')
    with tempfile.TemporaryDirectory() as directory:
        probe = Path(directory) / 'objc-methods'
        xcrun('--sdk', 'iphonesimulator', 'clang', '-target', 'arm64-apple-ios17.0-simulator',
              '-fobjc-arc', source, '-framework', 'UIKit', '-framework', 'Foundation', '-o', probe)
        return json.loads(xcrun('simctl', 'spawn', simulator, probe, *sorted(classes)))


def provider_aliases(path):
    filename = path.rsplit('/', 1)[-1]
    framework = re.search(r'/([^/]+)\.framework/', path)
    return {path, filename, filename.split('.')[0]} | ({framework[1]} if framework else set())


def import_kind(symbol):
    for prefix, kind in (
        ('_OBJC_CLASS_$_', 'objc_class'),
        ('_OBJC_METACLASS_$_', 'objc_metaclass'),
        ('_OBJC_IVAR_$_', 'objc_ivar'),
        ('_OBJC_EHTYPE_$_', 'objc_exception_type'),
    ):
        if symbol.startswith(prefix):
            return kind
    return 'native_symbol'  # Mach-O undefined entries also represent C data.


class Exports:
    def __init__(self, frameworks, sdk):
        self.frameworks = frameworks
        self.sdk = sdk
        self.sdk_libraries = {}

    @cache
    def read_tbd(self, path):
        # Let Apple's tool normalize the installed TBD format and filter the
        # device architecture. Current device SDKs may only spell it arm64e.
        libraries = []
        with tempfile.TemporaryDirectory() as directory:
            for arch in ('arm64', 'arm64e'):
                target = Path(directory) / f'{arch}.json'
                result = subprocess.run(['xcrun', 'llvm-readtapi', '-extract', f'--arch={arch}',
                                         '--filetype=tbd-v5', str(path), '-o', str(target)],
                                        text=True, capture_output=True)
                if result.returncode:
                    if f"doesn't have architecture '{arch}'" in result.stderr:
                        continue
                    raise RuntimeError(result.stderr.strip())
                document = json.loads(target.read_text())
                libraries.extend([document['main_library'], *document.get('libraries', [])])
        for library in libraries:
            targets = {item['target'] for item in library['target_info'] if item['target'] in {'arm64-ios', 'arm64e-ios'}}
            if not targets:
                continue
            names = {item['name'] for item in library['install_names'] if targets.intersection(item.get('targets', targets))}
            symbols = set()
            for group in [*library.get('exported_symbols', []), *library.get('reexported_symbols', [])]:
                if not targets.intersection(group.get('targets', targets)):
                    continue
                for kind in ('data', 'text'):
                    values = group.get(kind, {})
                    symbols.update(values.get('global', []))
                    symbols.update(values.get('weak', []))
                    for cls in values.get('objc_class', []):
                        symbols.update(('_OBJC_CLASS_$_' + cls, '_OBJC_METACLASS_$_' + cls))
                    symbols.update('_OBJC_IVAR_$_' + ivar for ivar in values.get('objc_ivar', []))
                    symbols.update('_OBJC_EHTYPE_$_' + cls for cls in values.get('objc_eh_type', []))
            reexports = {name for item in library.get('reexported_libraries', [])
                         if targets.intersection(item.get('targets', targets)) for name in item['names']}
            for name in names:
                current, linked = self.sdk_libraries.setdefault(name, (set(), set()))
                current.update(symbols)
                linked.update(reexports)

    @cache
    def direct(self, path):
        if path.startswith(('@rpath/', '@loader_path/')):
            image = self.frameworks / path.split('/', 1)[1]
            if image.is_file():
                exported = dyld('-exports', image)
                symbols = set(re.findall(r'^\s+0x[\da-fA-F]+\s+(\S+)', exported, re.M))
                return symbols, {dep for attr, dep in linked_libraries(image) if 're-export' in attr}
        if path.startswith('/'):
            location = self.sdk / path.lstrip('/')
            names = [location.with_suffix('.tbd')]
            framework = re.search(r'(/[^/]+\.framework)/', str(location))
            if framework:
                names.append(Path(str(location).split(framework[1], 1)[0] + framework[1]) / (location.name + '.tbd'))
            for stub in names:
                if stub.is_file() and path not in self.sdk_libraries:
                    self.read_tbd(stub)
            if path in self.sdk_libraries:
                return self.sdk_libraries[path]
        return None

    @cache
    def closure(self, path):
        seen, symbols, unknown = set(), defaultdict(set), set()
        pending = [path]
        while pending:
            provider = pending.pop()
            if provider in seen:
                continue
            seen.add(provider)
            result = self.direct(provider)
            if result is None:
                unknown.add(provider)
                continue
            exports, reexports = result
            for symbol in exports:
                symbols[symbol].add(provider)
            pending.extend(reexports)
        return symbols, sorted(unknown)


def receiver_status(receiver, kind, selector, classes, methods, missing_classes, runtime):
    chain = []
    while receiver and receiver not in chain:
        chain.append(receiver)
        if receiver in missing_classes:
            return {'status': 'blocked_by_missing_class', 'inheritance': chain}
        if (kind, selector) in methods.get(receiver, set()):
            return {'status': 'static_method_found', 'inheritance': chain, 'implementation': receiver}
        if receiver in runtime and receiver not in classes:
            declaration = next((encoding for dispatch, name, encoding in runtime[receiver]['methods']
                                if (dispatch, name) == (kind, selector)), None)
            if declaration:
                return {'status': 'simulator_method_found', 'inheritance': chain,
                        'implementation': receiver, 'type_encoding': declaration}
            receiver = runtime[receiver]['superclass']
            if receiver is None:
                return {'status': 'simulator_method_absent', 'inheritance': chain}
            continue
        receiver = classes.get(receiver)
    return {'status': 'system_method_unverified', 'inheritance': chain}


def inspect_image(image, component, version, exports, bridge_classes, bridge_methods, mappings, runtime):
    dependencies = [path for _, path in linked_libraries(image)]
    retargeted = mappings.get(component)
    records = []
    for symbol, weak, library in imports(image):
        possible = [path for path in dependencies if library in provider_aliases(path)]
        paths = [retargeted.get(path, path) for path in possible] if retargeted is not None else []
        evidence = set()
        unknown = set()
        for path in paths:
            provided, unchecked = exports.closure(path)
            evidence.update(provided.get(symbol, []))
            unknown.update(unchecked)
        status = 'original_image_only'
        if retargeted is not None:
            if library == '<weak-def-coalesce>':
                status = 'weak_definition_coalescing'
            elif evidence:
                status = 'static_export_found'
            elif not paths or unknown:
                status = 'provider_unverified'
            else:
                status = 'weak_export_absent' if weak else 'required_export_absent'
        records.append({'symbol': symbol, 'kind': import_kind(symbol), 'original_library': library,
                        'weak': weak, 'mapped_providers': paths, 'exported_by': sorted(evidence),
                        'unchecked_providers': sorted(unknown), 'status': status})

    classes, methods, entries = objc_metadata(image)
    missing_classes = {
        row['symbol'].removeprefix('_OBJC_CLASS_$_')
        for row in records if row['kind'] == 'objc_class' and row['status'] == 'required_export_absent'
    }
    lookup_classes = {**bridge_classes, **classes}
    lookup_methods = {name: bridge_methods.get(name, set()) | methods.get(name, set())
                      for name in bridge_methods.keys() | methods.keys()}
    slots = selector_slots(image)
    owners = defaultdict(set)
    for cls, declarations in lookup_methods.items():
        for kind, selector in declarations:
            owners[selector].add((cls, kind, 'binary_metadata'))
    for cls, details in runtime.items():
        if cls not in lookup_classes:
            for kind, selector, _ in details['methods']:
                owners[selector].add((cls, kind, 'simulator_runtime'))
    referenced = {selector: {'status': 'ambiguous_receiver', 'attributed_calls': [],
                             'candidate_declaration_owners': sorted(owners[selector])}
                  for selector in set(slots.values())}
    sends, dynamic, counts = direct_dispatches(image, entries, slots, version)
    for address, kind, receiver, caller, selector, dispatch, source in sends:
        if selector not in referenced:
            referenced[selector] = {'status': 'direct_dispatch_only', 'attributed_calls': [],
                                     'candidate_declaration_owners': sorted(owners[selector])}
        start = lookup_classes.get(receiver) if dispatch == 'super' else receiver
        referenced[selector]['attributed_calls'].append({
            'address': hex(address), 'receiver': receiver, 'kind': kind, 'dispatch': dispatch,
            'caller': caller, 'evidence': source,
            'confidence': 'inferred_local_dataflow' if dispatch == 'direct' else 'attributed',
            **receiver_status(start, kind, selector, lookup_classes, lookup_methods, missing_classes, runtime),
        })
    symbols = set(re.findall(r'^\s+0x[\da-fA-F]+\s+_((?:Java_|JNI_)[^\s]+)', dyld('-exports', image), re.M))
    return {
        'dependencies': dependencies,
        'imports': records,
        'defined_classes': {name: {'superclass': parent, 'methods': sorted(methods.get(name, set()))}
                            for name, parent in classes.items()},
        'selector_references': referenced,
        'selector_slot_count': len(slots),
        'direct_dispatch_counts': counts,
        'dynamic_lookup_calls': dynamic,
        'jni_exports': sorted(symbols),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--frameworks', type=Path, required=True, help='Built device host Frameworks directory')
    parser.add_argument('--jni-mappings', type=Path, required=True, help='native-host-device-library-mappings.json')
    parser.add_argument('--engine-mappings', type=Path, required=True, help='native-engine-device-adaptation.json')
    parser.add_argument('--simulator', help='Booted ARM64 iOS Simulator identifier for optional system method evidence')
    parser.add_argument('--runtime-version', choices=['6.1.4', '6.1.7'])
    parser.add_argument('--jvm-trace', type=Path, action='append', default=[],
                        help='Retained HotSpot trace file from the stated runtime version; repeat for rotated logs')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if bool(args.runtime_version) != bool(args.jvm_trace):
        parser.error('--runtime-version and at least one --jvm-trace must be provided together')
    sdk = Path(xcrun('--sdk', 'iphoneos', '--show-sdk-path').strip())
    host_map = json.loads(args.jni_mappings.read_text())
    engine_map = json.loads(args.engine_mappings.read_text())['dependency_mappings']
    mappings = {component: engine_map if component == 'engine' else host_map[filename]
                for component, filename in ADAPTED.items()}
    exports = Exports(args.frameworks, sdk)
    bridge_classes, bridge_methods, _ = objc_metadata(args.frameworks / 'libBitwigUIKit.dylib')
    apps = {}
    for supplied, expected_version in [(args.baseline, '6.1.4'), (args.candidate, '6.1.7')]:
        app = supplied / 'Contents'
        version = plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleShortVersionString']
        if version != expected_version:
            parser.error(f'expected {expected_version}, got {version}')
        apps[version] = app
    # Only the recognized launch set receives a projected dependency mapping.
    # Newly discovered native code remains optional until build/load evidence exists.
    with tempfile.TemporaryDirectory() as root:
        run_inventory(args, apps, Path(root), bridge_classes, bridge_methods, mappings, exports)


def run_inventory(args, apps, scratch, bridge_classes, bridge_methods, mappings, exports):
    known = {path: ROLES.get(component, 'active_device_engine' if component == 'engine' else component)
             for component, path in TARGETS.items()}
    discovered = {}
    for version, app in apps.items():
        folder = scratch / version
        folder.mkdir()
        discovered[version] = discover(app, folder, known)
    runtime = {}
    if args.simulator:
        class_prefix = '_OBJC_CLASS_$_'
        system_classes = {symbol.removeprefix(class_prefix)
                          for app in apps.values() for path in TARGETS.values()
                          for symbol, _, _ in imports(app / path) if symbol.startswith(class_prefix)}
        system_classes.update(parent for parent in bridge_classes.values() if parent)
        runtime = simulator_methods(args.simulator, system_classes - bridge_classes.keys())
    report = {
        'scope': 'Mach-O ARM64 imports, exports, Objective-C and direct lookup instructions are static evidence against the supplied bridges. Mapping is projected from original dependency paths. Name or export evidence does not establish ABI, active loading, or supported behavior. Indirect sends, register resolution with control-flow joins, dynamic lookups and forwarding are incomplete.',
        'system_methods': 'ARM64 iOS Simulator runtime. Device availability and ABI compatibility require separate verification.' if args.simulator else 'System runtime method lookup disabled.',
        'bridge_classes': {name: {'superclass': parent, 'methods': sorted(bridge_methods.get(name, set()))}
                           for name, parent in bridge_classes.items()},
        'versions': {},
        'discovery': {},
    }
    for version, (records, inspectable, declarations, counters, uninspected) in discovered.items():
        scanned = {}
        bindings = defaultdict(set)
        for record in records:
            relative = record['path']
            if relative not in inspectable:
                continue
            name = next((name for name, path in TARGETS.items() if path == relative), relative)
            if record['role'] == 'jna':
                name = 'jna'
            if name in ADAPTED and name != 'engine':
                record['role'] = 'adapted_host_library'
            try:
                scanned[name] = inspect_image(inspectable[relative], name, version, exports,
                                              bridge_classes, bridge_methods, mappings, runtime)
            except (subprocess.CalledProcessError, RuntimeError) as error:
                record['status'] = 'inspection_failed'
                uninspected.append({'path': relative, 'reason': type(error).__name__})
                continue
            record['status'] = 'arm64_inspected'
            for symbol in scanned[name]['jni_exports']:
                bindings[symbol].add(relative)
        match_bindings(declarations, bindings)
        report['versions'][version] = scanned
        report['discovery'][version] = {'images': records, 'denominators': counters,
                                        'uninspected': uninspected, 'jni_declarations': declarations}
        if version == args.runtime_version:
            report['discovery'][version]['jvm_observations'] = correlate_jvm(declarations, args.jvm_trace)
        print(f"{version}: {len(scanned)} of {len(records)} native candidates inspected as ARM64, "
              f"{len(declarations)} JNI declarations from {counters.get('classfiles_parsed', 0)} classfiles")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
