#!/usr/bin/env python3
"""Check a committed source snapshot. This does not scan earlier history."""
import argparse
from collections import Counter
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ROOT_FILES = {'.gitignore', 'README.md', 'THIRD_PARTY.md', 'LICENSE', 'LICENSE.md'}
SOURCE_DIRS = {'docs', 'native', 'probe', 'scripts', 'tests'}
SOURCE_SUFFIXES = {'.c', '.h', '.js', '.lock', '.m', '.md', '.metal', '.patch',
                   '.py', '.rs', '.swift', '.toml', '.txt'}
PRIVATE_MARKERS = {
    'personal absolute path': rb'/Users/(?!Shared/)[A-Za-z0-9_.-]+/',
    'device UDID': rb'(?<![A-Fa-f0-9])[A-Fa-f0-9]{8}-[A-Fa-f0-9]{16}(?![A-Fa-f0-9])',
    'UUID-shaped identifier': rb'(?i)\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b',
    'literal signing team': rb'(?<![A-Z_])DEVELOPMENT_TEAM[\x22\x27:=\s]+[\x22\x27]?[A-Z0-9]{10}(?![A-Z0-9])',
    'key or pairing material': rb'-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----|<key>(?:HostPrivateKey|RootPrivateKey|EscrowBag)</key>\s*<data>',
    'access token pattern': rb'\b(?:ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|AKIA[A-Z0-9]{16}|sk-[A-Za-z0-9_-]{35,})\b',
    'embedded image': rb'data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/]{64,}',
    'Git LFS pointer': rb'^version https://git-lfs.github.com/spec/v1\n',
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tree', nargs='?', default='HEAD')
    args = parser.parse_args()
    revision = subprocess.check_output(
        ['git', '-C', str(ROOT), 'rev-parse', '--verify', '--end-of-options', args.tree + '^{tree}'],
        text=True,
    ).strip()
    listing = subprocess.check_output(['git', '-C', str(ROOT), 'ls-tree', '-r', '-z', revision])
    failures = Counter()
    count = 0
    for entry in listing.split(b'\0'):
        if not entry:
            continue
        count += 1
        metadata, filename = entry.split(b'\t', 1)
        mode, object_type, oid = metadata.decode('ascii').split()
        name = filename.decode('utf-8', errors='surrogateescape')
        path = Path(name)
        is_grid_java = path.suffix == '.java' and path.parts[:2] in {
            ('probe', 'grid-rate'), ('tests', 'grid-rate'),
        }
        is_plugin_refresh = name == 'probe/plugin-files/ManagedPluginRefresh.java'
        is_source = (name in ROOT_FILES or is_grid_java or is_plugin_refresh
                     or (path.parts[0] in SOURCE_DIRS and path.suffix in SOURCE_SUFFIXES))
        if mode not in {'100644', '100755'} or object_type != 'blob' or not is_source:
            failures['unexpected path or file type'] += 1
            continue
        data = subprocess.check_output(['git', '-C', str(ROOT), 'cat-file', 'blob', oid])
        try:
            data.decode('utf-8')
        except UnicodeDecodeError:
            failures['non-UTF-8 content'] += 1
        if b'\0' in data:
            failures['binary content'] += 1
        for label, marker in PRIVATE_MARKERS.items():
            if re.search(marker, data):
                failures[label] += 1
    if failures:
        for label, failed in sorted(failures.items()):
            print(f'{label}: {failed} files')
        raise SystemExit(1)
    print(f'Source snapshot checked: {count} files')


if __name__ == '__main__':
    main()
