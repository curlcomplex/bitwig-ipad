"""Discover local native images and JNI declarations without loading app code."""
from collections import Counter
import os
from pathlib import Path
import struct
import subprocess
import zipfile

MACHO_MAGIC = {bytes.fromhex(value) for value in
               ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe',
                'bebafeca', 'cafebabf', 'bfbafeca')}
JNA_MEMBER = 'com/sun/jna/darwin-aarch64/libjnidispatch.jnilib'


def binary_format(header):
    if header[:4] in MACHO_MAGIC:
        return 'Mach-O'
    if header.startswith(b'\x7fELF'):
        return 'ELF'
    if header.startswith(b'MZ'):
        return 'PE'
    if header.startswith(b'!<arch>\n'):
        return 'static_archive'
    return None


def native_declarations(data):
    """Read class and native method descriptors from JVM classfile structures."""
    if not data.startswith(b'\xca\xfe\xba\xbe'):
        raise ValueError('not a classfile')
    offset = 8

    def integer(size):
        nonlocal offset
        if offset + size > len(data):
            raise ValueError('truncated classfile')
        value = int.from_bytes(data[offset:offset + size], 'big')
        offset += size
        return value

    count = integer(2)
    pool = [None] * count
    index = 1
    while index < count:
        tag = integer(1)
        if tag == 1:
            size = integer(2)
            pool[index] = data[offset:offset + size].replace(b'\xc0\x80', b'\x00').decode('utf-8', errors='surrogatepass')
            offset += size
        elif tag == 7:
            pool[index] = integer(2)
        elif tag in (5, 6):
            offset += 8
            index += 1
        elif tag in (3, 4, 9, 10, 11, 12, 17, 18):
            offset += 4
        elif tag in (8, 16, 19, 20):
            offset += 2
        elif tag == 15:
            offset += 3
        else:
            raise ValueError(f'unknown constant-pool tag {tag}')
        index += 1
    integer(2)
    owner = pool[pool[integer(2)]]
    integer(2)
    interfaces = integer(2)
    offset += 2 * interfaces

    def members():
        nonlocal offset
        for _ in range(integer(2)):
            access, name, desc = integer(2), integer(2), integer(2)
            for _ in range(integer(2)):
                integer(2)
                length = integer(4)
                offset += length
            yield access, name, desc

    for _ in members():
        pass
    return [(owner, pool[name], pool[desc], bool(access & 0x0008))
            for access, name, desc in members() if access & 0x0100]


def jni_escape(text):
    encoded = text.encode('utf-16-be', errors='surrogatepass')
    parts = []
    for (unit,) in struct.iter_unpack('>H', encoded):
        char = chr(unit)
        if char.isascii() and char.isalnum():
            parts.append(char)
        else:
            parts.append({'/': '_', '_': '_1', ';': '_2', '[': '_3'}.get(char, f'_0{unit:04x}'))
    return ''.join(parts)


def match_bindings(declarations, exports):
    signatures = {}
    for row in declarations:
        signatures.setdefault((row['class'], row['method']), set()).add(row['descriptor'])
    for row in declarations:
        owner, method, descriptor = row['class'], row['method'], row['descriptor']
        short = 'Java_' + jni_escape(owner) + '_' + jni_escape(method)
        long = short + '__' + jni_escape(descriptor[1:descriptor.index(')')])
        matches = [{'name': name, 'images': sorted(exports[name])}
                   for name in (short, long) if name in exports]
        if not matches:
            status = 'unresolved_or_runtime_registered'
        elif short in exports and len(signatures[owner, method]) > 1:
            status = 'ambiguous_short_export'
        else:
            status = 'export_name_match_runtime_unverified'
        row.update(status=status, candidate_exports=matches)


def archive_inventory(path, relative, scratch, images, declarations, counters, uninspected):
    try:
        with zipfile.ZipFile(path) as archive:
            for item in archive.infolist():
                if item.is_dir():
                    continue
                counters['archive_files'] += 1
                member = relative + '!/' + item.filename
                if item.filename.endswith('.class'):
                    counters['classfiles'] += 1
                    try:
                        methods = native_declarations(archive.read(item))
                    except (ValueError, IndexError, TypeError, OSError, RuntimeError) as error:
                        uninspected.append({'path': member, 'reason': str(error)})
                        continue
                    counters['classfiles_parsed'] += 1
                    for owner, name, descriptor, is_static in methods:
                        declarations.append({'archive': relative, 'entry': item.filename, 'class': owner,
                                             'method': name, 'descriptor': descriptor, 'static': is_static})
                    continue
                with archive.open(item) as stream:
                    detected = binary_format(stream.read(24))
                if not detected:
                    if item.filename.lower().endswith(('.dylib', '.jnilib', '.dll', '.so', '.jar', '.zip')):
                        uninspected.append({'path': member, 'reason': 'unrecognized native or nested archive format'})
                    continue
                local = None
                if detected == 'Mach-O':
                    local = scratch / f'archive-image-{len(images)}'
                    local.write_bytes(archive.read(item))
                images.append((member, local, detected, 'jna' if item.filename == JNA_MEMBER and relative == 'Java/libs.jar' else 'optional_archive_native'))
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        uninspected.append({'path': relative, 'reason': str(error)})


def discover(app, scratch, known):
    images, declarations, uninspected = [], [], []
    counters = Counter()
    for root, dirs, filenames in os.walk(app):
        root = Path(root)
        for name in sorted(dirs):
            path = root / name
            if path.is_symlink():
                uninspected.append({'path': path.relative_to(app).as_posix(),
                                    'reason': 'directory symlink not followed'})
                dirs.remove(name)
        dirs.sort()
        for name in sorted(filenames):
            path = root / name
            relative = path.relative_to(app).as_posix()
            counters['bundle_files'] += 1
            if path.is_symlink():
                uninspected.append({'path': relative, 'reason': 'file symlink not followed'})
                continue
            if path.suffix.lower() in ('.jar', '.zip'):
                counters['java_archives'] += 1
                archive_inventory(path, relative, scratch, images, declarations, counters, uninspected)
                continue
            if not path.is_file():
                uninspected.append({'path': relative, 'reason': 'not a regular file'})
                continue
            try:
                with path.open('rb') as stream:
                    detected = binary_format(stream.read(24))
            except OSError as error:
                uninspected.append({'path': relative, 'reason': str(error)})
                continue
            if detected:
                role = 'replaced_by_ios_jvm' if relative.startswith('PlugIns/JavaVM-arm64.bundle/') else 'optional_bundle_native'
                images.append((relative, path, detected, known.get(relative, role)))
            elif path.suffix.lower() in ('.dylib', '.jnilib', '.dll', '.so'):
                uninspected.append({'path': relative, 'reason': 'unrecognized native format'})
    records, inspectable = [], {}
    for relative, local, detected, role in images:
        record = {'path': relative, 'format': detected, 'role': role}
        records.append(record)
        if detected != 'Mach-O':
            record['status'] = 'unsupported_image_format'
            continue
        archs = subprocess.run(['xcrun', 'lipo', '-archs', str(local)], capture_output=True, text=True)
        if archs.returncode:
            record['status'] = 'architecture_uninspected'
            continue
        record['architectures'] = archs.stdout.split()
        record['status'] = 'arm64_slice_available' if 'arm64' in record['architectures'] else 'unsupported_architecture'
        if record['status'] == 'arm64_slice_available':
            inspectable[relative] = local
    return records, inspectable, declarations, dict(counters), uninspected


def correlate_jvm(declarations, logs):
    """HotSpot logs report method names, so overload/variant matches stay explicit."""
    import re
    observed = {}
    pattern = re.compile(r'\[jni,resolve\].*\[(Registering JNI native method|Dynamic-linking native method) ([^\] ]+)')
    for path in logs:
        with path.open(errors='replace') as stream:
            for line in stream:
                match = pattern.search(line)
                if not match:
                    continue
                action, identifier = match.groups()
                owner, _, method = identifier.rpartition('.')
                if not owner:
                    continue
                action = 'registered' if action.startswith('Registering') else 'dynamic_link'
                observed.setdefault((owner.replace('.', '/'), method), set()).add(action)
    rows = Counter((row['class'], row['method']) for row in declarations)
    for row in declarations:
        key = row['class'], row['method']
        row['runtime_observation'] = {
            'actions': sorted(observed.get(key, ())),
            'matching_declaration_rows': rows[key],
            'status': 'name_observed_descriptor_unverified' if key in observed else 'unobserved_in_supplied_logs',
        }
    return {'retained_logs': len(logs), 'unique_owner_method_names': len(observed),
            'matched_bundled_owner_method_names': len(rows.keys() & observed.keys())}
