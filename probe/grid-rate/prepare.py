#!/usr/bin/env python3
"""Prepare an exact locally installed Grid compatibility class overlay."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

SOURCE = Path(__file__).resolve().parent
BITWIG_JAR = '6024752847797eb41e6fbc91e081211937931cc452a695ab78226321cefdac8d'
DEVICE_CLASSES = 'com/bitwig/flt/document/core/master/device/'
PATCHED = {
    'AiR': DEVICE_CLASSES + 'AiR.class',
    'utt': DEVICE_CLASSES + 'utt.class',
    'TLG': 'TLG.class',
    'aKf': 'aKf.class',
}


def prepare(java_dir, destination, *, patchbay=False):
    original = java_dir / 'bitwig.jar'
    libraries = java_dir / 'libs.jar'
    digest = hashlib.sha256()
    with original.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    if digest.hexdigest() != BITWIG_JAR:
        raise ValueError('Expected the original Bitwig Studio 6.1.7 Java archive')
    if destination.exists() or destination.is_relative_to(java_dir.parent):
        raise ValueError('Choose a new staging path outside the Bitwig installation')
    if patchbay and any(character in str(destination) for character in '\t\r\n'):
        raise ValueError('Patchbay staging paths cannot contain tabs or newlines')
    destination.parent.mkdir(parents=True, exist_ok=True)
    classpath = f'{original}:{libraries}'
    jdk = os.environ.get('BITWIG_JDK_HOME') or os.environ.get('JAVA_HOME')
    java = str(Path(jdk).expanduser() / 'bin' / 'java') if jdk else 'java'
    javac = str(Path(jdk).expanduser() / 'bin' / 'javac') if jdk else 'javac'
    with tempfile.TemporaryDirectory(dir=destination.parent, prefix='.grid-rate-') as scratch:
        work = Path(scratch)
        tools = work / 'tools'
        tools.mkdir()
        subprocess.run([javac, '--release', '25', '-cp', classpath, '-d', str(tools),
                        *map(str, sorted(SOURCE.glob('*.java')))], check=True)
        with zipfile.ZipFile(original) as jar:
            for name, entry in PATCHED.items():
                (work / f'{name}.stock').write_bytes(jar.read(entry))
        for patch in ('PatchGridSourceSelection', 'PatchGridPolicy', 'PatchGridInspector'):
            subprocess.run([java, '-cp', f'{tools}:{classpath}', patch, str(work)], check=True)

        if patchbay:
            bundle = work / 'patchbay'
            bundle.mkdir()
            (work / 'classes').rename(bundle / 'classes')
            helper_archive(bundle / 'grid-helper.jar', tools)
            mappings = ''.join(f'{entry.removesuffix(".class")}\t{destination / "classes" / entry}\n'
                               for entry in PATCHED.values())
            (bundle / 'replacement-map.tsv').write_text(mappings, encoding='utf-8')
            bundle.rename(destination)
        else:
            output = work / 'overlay.jar'
            helper_archive(output, tools, replacements=work / 'classes')
            destination.hardlink_to(output)


def helper_archive(path, tools, *, replacements=None):
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        if replacements is not None:
            for entry in PATCHED.values():
                archive.write(replacements / entry, entry)
        for helper in sorted(tools.glob('Grid*.class')):
            archive.write(helper, helper.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bitwig_app', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--patchbay', action='store_true',
                        help='prepare a desktop replacement-map directory and helper JAR')
    args = parser.parse_args()
    try:
        prepare(args.bitwig_app.resolve() / 'Contents' / 'Java', args.output.resolve(), patchbay=args.patchbay)
    except (OSError, ValueError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
