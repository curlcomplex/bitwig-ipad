"""Prepare the supported local Surge XT desktop CLAP for an iPad host."""
import hashlib
import json
import plistlib
import re
import shutil
import struct
import subprocess
from pathlib import Path

BUNDLE_NAME = 'Surge XT.clap'
PLUGIN_ID = 'org.surge-synth-team.surge-xt'
HELPER_PATH = Path('MacOS/Bitwig Plug-in Host ARM64-NEON.app/Contents/MacOS/BitwigPluginHost-ARM64-NEON')
HELPER_SHA256 = '4c6b0ad2cd443a1362cfed13152921d0b9921fbeeeea436761a6aa69fb684195'
BIN = Path('Contents/MacOS/Surge XT')
DEVICE_IMAGE = 'SurgeXT.bundle'
VERSION = '1.3.4'
UNIVERSAL_SHA256 = '95bde486416d56671456ca3a7ff408bde4be7eb2c9b5027b51877c02ee8d8038'
ARM64_SHA256 = 'd7f7f9a352ea422c21d8847543c9452a5ab7804f959707d8b46fb188f85a9a1b'
REPLACED_FRAMEWORKS = {
    'AppKit', 'Cocoa', 'CoreServices', 'CoreGraphics', 'CoreVideo',
    'Foundation', 'ApplicationServices', 'DiscRecording',
}
# These desktop editor imports were not used by init, CLAP params/state or DSP.
# The adapted plug-in also stops advertising the desktop CLAP GUI extension.
EDITOR_IMPORTS = frozenset(name.encode() for name in '''
_OBJC_CLASS_$_NSAccessibilityElement
_OBJC_CLASS_$_NSAlert
_OBJC_CLASS_$_NSAppearance
_OBJC_CLASS_$_NSBitmapImageRep
_OBJC_CLASS_$_NSColorSpace
_OBJC_CLASS_$_NSControl
_OBJC_CLASS_$_NSDocumentController
_OBJC_CLASS_$_NSGraphicsContext
_OBJC_CLASS_$_NSNib
_OBJC_CLASS_$_NSStatusBar
_OBJC_CLASS_$_NSWorkspaceOpenConfiguration
_NSAccessibilityPostNotificationWithUserInfo
_NSAccessibilityUnignoredAncestor
_NSAccessibilityUnignoredChildrenForOnlyChild
_NSBeep
_CGDisplayRegisterReconfigurationCallback
_CGDisplayRemoveReconfigurationCallback
_CGEventCreateMouseEvent
_CGWarpMouseCursorPosition
_CGWindowListCreateImage
_CVDisplayLinkSetOutputCallback
_TransformProcessType
'''.split())


def invoke(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify_source(source):
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    if (info.get('CFBundleShortVersionString') != VERSION or
            info.get('CFBundleIdentifier') != PLUGIN_ID or
            digest(source / BIN) != UNIVERSAL_SHA256):
        raise ValueError('Expected the supported official universal Surge XT 1.3.4 CLAP release')


def skip_leb(data, offset, end):
    while offset < end:
        offset += 1
        if not data[offset - 1] & 0x80:
            return offset
    raise ValueError('Truncated Mach-O bind operand')


def mark_editor_imports(data, offset, size, imports):
    end = offset + size
    seen = set()
    while offset < end:
        opcode = data[offset] & 0xf0
        offset += 1
        if opcode == 0x40:  # BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM
            name_end = data.index(0, offset, end)
            name = bytes(data[offset:name_end])
            if name in imports:
                data[offset - 1] |= 1  # BIND_SYMBOL_FLAGS_WEAK_IMPORT
                seen.add(name)
            offset = name_end + 1
        elif opcode in (0x20, 0x60, 0x70, 0x80, 0xa0, 0xc0):
            offset = skip_leb(data, offset, end)
            if opcode == 0xc0:
                offset = skip_leb(data, offset, end)
        elif opcode not in (0x00, 0x10, 0x30, 0x50, 0x90, 0xb0):
            raise ValueError(f'Unsupported Mach-O bind opcode {opcode:#x}')
    return seen


def weaken_imports(data, imports):
    if struct.unpack_from('<I', data)[0] != 0xfeedfacf:
        raise ValueError('Expected a thin Mach-O image')
    commands = struct.unpack_from('<I', data, 16)[0]
    dyld = symtab = None
    position = 32
    for _ in range(commands):
        command, size = struct.unpack_from('<II', data, position)
        if command in (0x22, 0x80000022):  # LC_DYLD_INFO[_ONLY]
            dyld = struct.unpack_from('<10I', data, position + 8)
        if command == 2:  # LC_SYMTAB
            symtab = struct.unpack_from('<4I', data, position + 8)
        position += size
    if dyld is None or symtab is None:
        raise ValueError('Missing Mach-O bind metadata')
    seen = mark_editor_imports(data, dyld[2], dyld[3], imports)
    seen |= mark_editor_imports(data, dyld[6], dyld[7], imports)
    if seen != imports:
        raise ValueError('Unexpected set of desktop editor imports')

    symbols, count, strings, _ = symtab
    for index in range(count):
        entry = symbols + 16 * index
        name, kind, _, flags, _ = struct.unpack_from('<IBBHQ', data, entry)
        if kind & 0x0e or not name:
            continue
        start = strings + name
        if bytes(data[start:data.index(0, start)]) in imports:
            struct.pack_into('<H', data, entry + 6, flags | 0x40)  # N_WEAK_REF
    return data


def adapt_image(data, *, editor=False, imports=EDITOR_IMPORTS):
    weaken_imports(data, imports)
    if data.count(b'clap.gui\0') != 1:
        raise ValueError('Unexpected CLAP GUI extension lookup')
    return data if editor else data.replace(b'clap.gui\0', b'ipad.gui\0')


def stage_metadata_helper(contents, lib, build):
    source = contents / HELPER_PATH
    if digest(source) != HELPER_SHA256:
        raise ValueError('Expected official Bitwig 6.1.7 ARM64 Plug-in Host')
    data = bytearray(source.read_bytes())
    count = struct.unpack_from('<I', data, 16)[0]
    position = 32
    retained = []
    entry = None
    for _ in range(count):
        command, size = struct.unpack_from('<II', data, position)
        item = data[position:position + size]
        position += size
        if command == 0x80000028:  # LC_MAIN
            entry = struct.unpack_from('<Q', item, 8)[0]
            continue
        if command == 0xe:  # LC_LOAD_DYLINKER
            continue
        if command == 0x19 and item[8:24].rstrip(b'\0') == b'__PAGEZERO':
            struct.pack_into('<Q', item, 32, 0)
        retained.append(item)
    if not entry:
        raise ValueError('Missing original Plug-in Host entry point')
    commands = b''.join(retained)
    data[32:position] = commands.ljust(position - 32, b'\0')
    struct.pack_into('<III', data, 12, 8, len(retained), len(commands))  # MH_BUNDLE
    flags = struct.unpack_from('<I', data, 24)[0]
    struct.pack_into('<I', data, 24, flags & ~0x200000)  # MH_PIE
    instance = build / 'plugin-host-thin'
    instance.write_bytes(data)
    output = lib / 'BitwigPluginHost.bundle'
    invoke('xcrun', 'vtool', '-set-build-version', 'ios', '17.0', '27.2',
           '-replace', '-output', output, instance)
    mappings = {
        'AppKit': '@rpath/libSurgeAppKitBridge.dylib',
        'CoreFoundation': '@rpath/libSurgeCoreFoundationBridge.dylib',
        'CoreGraphics': '@rpath/libCoreGraphicsBridge.dylib',
        'CoreAudio': '@rpath/libAudioHALBridge.dylib',
        'AudioToolbox': '@rpath/libAudioToolboxBridge.dylib',
    }
    changes = []
    for line in subprocess.check_output(['otool', '-L', output], text=True).splitlines()[1:]:
        old = line.strip().split(' (compatibility')[0]
        match = re.match(r'/System/Library/Frameworks/([^/]+)\.framework/', old)
        if match:
            framework = match[1]
            new = mappings.get(framework, f'/System/Library/Frameworks/{framework}.framework/{framework}')
            changes += ['-change', old, new]
    invoke('xcrun', 'install_name_tool', *changes, '-add_rpath', '@loader_path', output)
    invoke('codesign', '--force', '--sign', '-', output)
    (lib / 'surge-plugin-host.json').write_text(json.dumps({'entry': entry}) + '\n')


def stage_desktop_frameworks(lib, cc, native, frameworks, *, editor):
    bridge = lib / 'libBitwigUIKit.dylib'
    surge = native / 'surge'
    for framework in sorted(frameworks):
        alias = lib / f'libSurge{framework}Bridge.dylib'
        options = [f'-Wl,-reexport_library,{bridge}', '-Wl,-rpath,@loader_path']
        sources = [native / 'Forward.c']
        if framework == 'AppKit':
            sources = [surge / 'AppKitKeys.m']
            if editor:
                sources.append(surge / 'EditorAppKit.m')
        if framework == 'CoreGraphics' and editor:
            sources = [surge / 'EditorDisplay.m']
        if framework == 'Foundation':
            sources = [surge / 'Foundation.m']
        if framework == 'CoreServices':
            options.append('-Wl,-reexport-lSystem')
        invoke(*cc, '-fobjc-arc', '-dynamiclib', *sources, *options,
               '-install_name', f'@rpath/{alias.name}', '-o', alias)
        invoke('codesign', '--force', '--sign', '-', alias)


def stage_bundle_loader(lib, cc, native, *, editor_headers=None, chow=False):
    bridge = lib / 'libBitwigUIKit.dylib'
    surge = native / 'surge'
    editor = editor_headers is not None
    core = lib / 'libSurgeCoreFoundationBridge.dylib'
    sources = [surge / 'CoreFoundation.m']
    options = []
    if editor:
        sources.append(surge / 'EditorEntry.m')
        options = ['-I', editor_headers, '-DBW_SURGE_EDITOR=1', '-DBW_SURGE_REMOTE=1',
                   bridge, '-framework', 'UIKit', '-Wl,-rpath,@loader_path']
    if chow:
        chow_entry = lib.parent / 'CHOWEditorEntry.o'
        invoke(*cc, '-fobjc-arc', '-c', surge / 'EditorEntry.m', '-I', editor_headers,
               '-DBW_SURGE_REMOTE=1', '-DBWRemoteEditor=BWCHOWRemoteEditor',
               '-DBWEditorEntry=BWCHOWEditorEntry', '-DBW_EDITOR_NAME="CHOW"', '-o', chow_entry)
        sources.append(chow_entry)
        options.append('-DBW_CHOW_EDITOR=1')
    invoke(*cc, '-fobjc-arc', '-dynamiclib', *sources, *options,
           '-framework', 'Foundation', '-Wl,-reexport_framework,CoreFoundation',
           '-install_name', f'@rpath/{core.name}', '-o', core)
    invoke('codesign', '--force', '--sign', '-', core)


def stage_surge(source, lib, sdk, cc, native, device, *, editor_headers=None, chow=None):
    verify_source(source)
    editor = editor_headers is not None
    destination = lib / BUNDLE_NAME
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination, symlinks=True)
    signature = destination / 'Contents/_CodeSignature'
    if signature.exists():
        shutil.rmtree(signature)

    surge = native / 'surge'
    stage_desktop_frameworks(lib, cc, native, REPLACED_FRAMEWORKS | ({'Carbon'} if chow else set()), editor=editor)
    if device:
        stage_bundle_loader(lib, cc, native, editor_headers=editor_headers, chow=chow)
    system = lib / 'libSurgeSystemBridge.dylib'
    invoke(*cc, '-dynamiclib', surge / 'System.c', '-Wl,-reexport-lSystem',
           '-install_name', f'@rpath/{system.name}', '-o', system)
    invoke('codesign', '--force', '--sign', '-', system)

    binary = destination / BIN
    thin = binary.with_name('.surge-arm64')
    invoke('xcrun', 'lipo', binary, '-thin', 'arm64', '-output', thin)
    if digest(thin) != ARM64_SHA256:
        raise ValueError('Unexpected Surge XT ARM64 binary')
    # Modify only a verified private copy before changing its platform or dependencies.
    thin.write_bytes(adapt_image(bytearray(thin.read_bytes()), editor=editor))
    invoke('xcrun', 'vtool', '-set-build-version', 'ios' if device else 'iossim',
           '17.0', '27.2', '-replace', '-output', binary, thin)
    thin.unlink()
    changes = ['-change', '/usr/lib/libSystem.B.dylib', f'@rpath/{system.name}']
    for line in subprocess.check_output(['otool', '-L', binary], text=True).splitlines()[1:]:
        old = line.strip().split(' (compatibility')[0]
        match = re.match(r'/System/Library/Frameworks/([^/]+)\.framework/', old)
        if not match:
            continue
        framework = match[1]
        if framework in REPLACED_FRAMEWORKS:
            new = f'@rpath/libSurge{framework}Bridge.dylib'
        else:
            path = f'{framework}.framework/{framework}'
            if not (sdk / 'System/Library/Frameworks' / (path + '.tbd')).is_file():
                raise ValueError(f'Missing iOS framework for Surge XT: {framework}')
            new = f'/System/Library/Frameworks/{path}'
        changes += ['-change', old, new]
    invoke('xcrun', 'install_name_tool', *changes, binary)
    if device:
        image = lib / DEVICE_IMAGE
        binary.replace(image)
        invoke('xcrun', 'install_name_tool', '-add_rpath', '@loader_path', image)
        invoke('codesign', '--force', '--sign', '-', image)
    else:
        invoke('codesign', '--force', '--sign', '-', destination)
    (lib / 'surge-clap.json').write_text(json.dumps({
        'plugin_id': PLUGIN_ID,
        'version': VERSION,
        'original_universal_sha256': UNIVERSAL_SHA256,
        'original_arm64_sha256': ARM64_SHA256,
        'desktop_gui': editor,
        'executable': DEVICE_IMAGE if device else str(BIN),
        'weak_desktop_imports': sorted(name.decode() for name in EDITOR_IMPORTS),
    }, indent=2) + '\n')
    if chow:
        stage_chow(chow, lib, cc, device=device)


CHOW_BUNDLE = 'CHOWTapeModel.clap'
CHOW_DEVICE_IMAGE = 'CHOWTapeModel.bundle'
CHOW_BINARY = Path('Contents/MacOS/CHOWTapeModel')
CHOW_SHA256 = '57ebf3a5008165e36828165deb5a332574c6a29b11445270f66f793a3858c1df'
CHOW_ARM64_SHA256 = 'f36941617e706e396d181dcbb481d4f06eb954c25e2342aeca6999049000d642'
CHOW_FRAMEWORKS = {'AppKit', 'ApplicationServices', 'Carbon', 'Cocoa', 'CoreGraphics',
                  'CoreServices', 'DiscRecording', 'Foundation'}
CHOW_EDITOR_IMPORTS = frozenset(name.encode() for name in '''
_CGDisplayRegisterReconfigurationCallback
_CGDisplayRemoveReconfigurationCallback
_CGEventCreateMouseEvent
_CGWarpMouseCursorPosition
_NSAccessibilityPostNotificationWithUserInfo
_NSAccessibilityUnignoredAncestor
_NSAccessibilityUnignoredChildrenForOnlyChild
_NSBeep
_OBJC_CLASS_$_NSAlert
_OBJC_CLASS_$_NSAppearance
_OBJC_CLASS_$_NSBitmapImageRep
_OBJC_CLASS_$_NSGraphicsContext
_OBJC_CLASS_$_NSNib
'''.split())



def stage_chow(source, frameworks, cc, *, device=False):
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    if (info.get('CFBundleIdentifier') != 'org.chowdsp.CHOWTapeModel' or
            info.get('CFBundleShortVersionString') != '2.11.0' or digest(source / CHOW_BINARY) != CHOW_SHA256):
        raise ValueError('Expected the official CHOW Tape Model 2.11.0 universal desktop CLAP')
    destination = frameworks / CHOW_BUNDLE
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination, symlinks=True)
    shutil.rmtree(destination / 'Contents/_CodeSignature', ignore_errors=True)
    binary = destination / CHOW_BINARY
    thin = destination / 'thin-arm64'
    invoke('xcrun', 'lipo', binary, '-thin', 'arm64', '-output', thin)
    if digest(thin) != CHOW_ARM64_SHA256:
        raise ValueError('Unexpected CHOW Tape Model ARM64 binary')
    thin.write_bytes(adapt_image(bytearray(thin.read_bytes()), editor=True, imports=CHOW_EDITOR_IMPORTS))
    invoke('xcrun', 'vtool', '-set-build-version', 'ios' if device else 'iossim', '17.0', '27.2', '-replace', '-output', binary, thin)
    thin.unlink()
    if not device:
        stage_desktop_frameworks(frameworks, cc, Path(__file__).resolve().parents[1] / 'native/compat', CHOW_FRAMEWORKS, editor=True)
    changes = []
    for line in subprocess.check_output(['otool', '-L', binary], text=True).splitlines()[1:]:
        old = line.strip().split(' (compatibility')[0]
        match = re.match(r'/System/Library/Frameworks/([^/]+)\.framework/', old)
        if not match:
            continue
        name = match[1]
        mapped = (f'@rpath/libSurge{name}Bridge.dylib' if name in CHOW_FRAMEWORKS else
                  f'/System/Library/Frameworks/{name}.framework/{name}')
        changes += ['-change', old, mapped]
    invoke('xcrun', 'install_name_tool', *changes, binary)
    if device:
        image = frameworks / CHOW_DEVICE_IMAGE
        binary.replace(image)
        invoke('xcrun', 'install_name_tool', '-add_rpath', '@loader_path', image)
        invoke('codesign', '--force', '--sign', '-', image)
    return destination
