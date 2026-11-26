#!/usr/bin/env python3
"""Prepare locally installed supported plug-ins for a signed iPad host."""
import argparse
import hashlib
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

from fabfilter_clap import RELEASES, stage_fabfilter, validate_fabfilter_sources
from nam_vst3 import NAM_BUNDLE, stage_nam, stage_nam_shader
from ott_vst3 import OTT_BUNDLE, stage_ott
from surge_clap import BUNDLE_NAME, DEVICE_IMAGE, CHOW_BUNDLE, CHOW_DEVICE_IMAGE, stage_chow, stage_surge


def prepare(source, output, sdk, identity):
    name = source.name
    scripts = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix='.prepare-', dir=output) as temporary:
        folder = Path(temporary) / 'package'
        folder.mkdir()
        if name == OTT_BUNDLE:
            image = stage_ott(source, folder, sdk)
        elif name == NAM_BUNDLE:
            image = stage_nam(source, folder, sdk)
            stage_nam_shader(folder, None, scripts.parent / 'native/compat', 'iphoneos', runtime=False)
        elif name == BUNDLE_NAME:
            stage_surge(source, folder, sdk, None, None, True, editor_headers=True, runtime=False)
            image = folder / DEVICE_IMAGE
            (folder / 'surge-clap.json').unlink()
        elif name == CHOW_BUNDLE:
            stage_chow(source, folder, None, device=True)
            image = folder / CHOW_DEVICE_IMAGE
        else:
            stage_fabfilter(validate_fabfilter_sources([source]), folder, sdk, None, None, runtime=False)
            image = folder / (source.stem.replace(' ', '').replace('-', '') + '.bundle')
            (folder / 'fabfilter-clap.json').unlink()
        subprocess.run(['xcrun', 'install_name_tool', '-add_rpath', '@executable_path/../../Frameworks', image], check=True)
        subprocess.run(['codesign', '--force', '--sign', identity, image], check=True)
        subprocess.run(['codesign', '--verify', '--strict', image], check=True)

        files = {}
        for path in sorted(folder.rglob('*')):
            if path.name in {'Icon\r', '.DS_Store'} or path.name.startswith('._'):
                if path.is_file() or path.is_symlink():
                    path.unlink()
                    continue
            if path.is_symlink() or not (path.is_file() or path.is_dir()):
                raise ValueError(f'Unsupported file in the prepared bundle: {path.relative_to(folder)}')
            if path.is_file():
                files[str(path.relative_to(folder))] = hashlib.sha256(path.read_bytes()).hexdigest()
        with (folder / 'Package.plist').open('wb') as manifest:
            plistlib.dump({'bridgeABI': 1, 'bundle': name, 'image': image.name, 'files': files}, manifest, fmt=plistlib.FMT_BINARY)
        destination = output / (source.stem + ' for iPad')
        if destination.exists():
            raise FileExistsError(f'Prepared folder already exists: {destination}')
        folder.rename(destination)
        print(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('sources', nargs='*', type=Path)
    parser.add_argument('--library', type=Path, help='Prepare supported plug-ins found in this Audio/Plug-Ins directory')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--sign', required=True, help='Existing Apple Development identity used to sign the iPad host')
    args = parser.parse_args()
    sources = list(args.sources)
    if args.library:
        for name in [BUNDLE_NAME, CHOW_BUNDLE, OTT_BUNDLE, NAM_BUNDLE, *RELEASES]:
            candidate = args.library / Path(name).suffix[1:].upper() / name
            if candidate.is_dir():
                sources.append(candidate)
    if not sources:
        parser.error('Provide plug-in paths or --library')
    args.output.mkdir(parents=True, exist_ok=True)
    sdk = Path(subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip())
    for source in sources:
        prepare(source, args.output, sdk, args.sign)


if __name__ == '__main__':
    main()
