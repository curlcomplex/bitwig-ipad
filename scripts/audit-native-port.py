#!/usr/bin/env python3
"""Inventory the installed Bitwig ARM64 port boundary without changing its bundle."""
import collections
import hashlib
import json
import re
import struct
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = Path('/Applications/Bitwig Studio 6.1.4.app/Contents')
SDK = Path(subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip())
TARGETS = {
    'launcher': APP / 'MacOS/BitwigStudio',
    'jni': APP / 'Frameworks/libbitwig-jni.jnilib',
    'engine': APP / 'MacOS/Bitwig Audio Engine ARM64-NEON.app/Contents/MacOS/BitwigAudioEngine-ARM64-NEON',
    'plugin_host': APP / 'MacOS/Bitwig Plug-in Host ARM64-NEON.app/Contents/MacOS/BitwigPluginHost-ARM64-NEON',
    'jvm': APP / 'PlugIns/JavaVM-arm64.bundle/Contents/Home/lib/server/libjvm.dylib',
    'sqlite': APP / 'Frameworks/libsqlitejdbc.jnilib',
}

def output(*args):
    return subprocess.check_output(args, text=True)

result = {'scope': 'Static import inventory; SDK framework presence does not establish ABI or runtime compatibility.', 'sdk': str(SDK), 'binaries': {}, 'java': {}}
for name, path in TARGETS.items():
    imports = collections.defaultdict(list)
    for line in output('xcrun', 'nm', '-arch', 'arm64', '-um', str(path)).splitlines():
        match = re.search(r'external (\S+) \(from (.+)\)', line)
        if match:
            imports[match[2]].append(match[1])
    deps = [line.strip().split(' (compatibility')[0] for line in output('xcrun', 'otool', '-arch', 'arm64', '-L', str(path)).splitlines()[1:]]
    frameworks = {}
    for dep in deps:
        match = re.search(r'/([^/]+)\.framework/', dep)
        if match:
            framework = match[1]
            frameworks[framework] = {'public_ios_sdk_present': (SDK / 'System/Library/Frameworks' / (framework + '.framework')).is_dir(), 'import_count': len(imports[framework])}
    record = {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'dependencies': deps, 'imports_by_library': dict(imports), 'frameworks': frameworks, 'undefined_import_count': sum(map(len, imports.values()))}
    result['binaries'][name] = record
    absent = {key: val['import_count'] for key, val in frameworks.items() if not val['public_ios_sdk_present']}
    print(f'{name}: {record["undefined_import_count"]} imports; absent public iOS frameworks: {absent}')
for path in (APP / 'Java').glob('*.jar'):
    versions = collections.Counter()
    with zipfile.ZipFile(path) as archive:
        for entry in archive.infolist():
            if entry.filename.endswith('.class'):
                with archive.open(entry) as stream:
                    header = stream.read(8)
                if header[:4] == b'\xca\xfe\xba\xbe':
                    versions[struct.unpack('>H', header[6:8])[0]] += 1
    result['java'][path.name] = {'class_major_versions': dict(sorted(versions.items())), 'note': 'Multi-release entries included; maximum is not necessarily the required runtime version.'}
    print(f'{path.name}: class major versions {dict(sorted(versions.items()))}')
(ROOT / 'evidence/native-port-audit.json').write_text(json.dumps(result, indent=2) + '\n')
