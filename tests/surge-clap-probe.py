#!/usr/bin/env python3
"""Verify the adapted Surge CLAP ABI inside an iOS Simulator process."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from surge_clap import stage_chow, stage_surge


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('simulator', help='Booted iOS Simulator ID')
    parser.add_argument('plugin', type=Path, help='Official local Surge XT 1.3.4 or CHOW Tape Model 2.11.0 CLAP bundle')
    parser.add_argument('bridge', type=Path, help='Built Simulator libBitwigUIKit.dylib')
    parser.add_argument('clap_include', type=Path, help='Official CLAP SDK include directory')
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--editor', action='store_true', help='Verify the detached original Surge editor as well')
    modes.add_argument('--chow-editor', action='store_true', help='Verify the detached CHOW Tape Model editor')
    args = parser.parse_args()
    sdk = Path(run('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path', capture_output=True, text=True).stdout.strip())
    cc = ['xcrun', '--sdk', 'iphonesimulator', 'clang', '-target', 'arm64-apple-ios17.0-simulator', '-isysroot', sdk]
    bundle_id = 'org.bitwigbridge.surgeloader'
    with tempfile.TemporaryDirectory() as temporary:
        app = Path(temporary) / 'SurgeLoader.app'
        frameworks = app / 'Frameworks'
        frameworks.mkdir(parents=True)
        shutil.copy2(args.bridge, frameworks / 'libBitwigUIKit.dylib')
        if args.chow_editor:
            plugin = stage_chow(args.plugin, frameworks, cc)
        else:
            stage_surge(args.plugin, frameworks, sdk, cc, ROOT / 'native/compat', False,
                        editor_headers=args.clap_include if args.editor else None)
            plugin = frameworks / 'Surge XT.clap'
        (app / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': bundle_id, 'CFBundleExecutable': 'SurgeLoader',
            'CFBundleName': 'SurgeLoader', 'CFBundlePackageType': 'APPL',
            'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
            'MinimumOSVersion': '17.0', 'UIDeviceFamily': [2],
        }))
        editor = args.editor or args.chow_editor
        editor_sources = [ROOT / 'native/compat/surge/EditorEntry.m'] if editor else []
        defines = ['-DSURGE_EDITOR'] if editor else ['-DSURGE_HEADLESS']
        if args.chow_editor:
            defines += ['-DCHOW_EDITOR', '-DBW_EDITOR_NAME="CHOW"']
        run(*cc, '-fobjc-arc', *defines, '-I', args.clap_include,
            ROOT / 'tests/surge-clap-probe.m', ROOT / 'tests/surge-clap-probe.c',
            *editor_sources,
            '-framework', 'UIKit', '-framework', 'CoreGraphics',
            '-Wl,-rpath,@executable_path/Frameworks', '-o', app / 'SurgeLoader')
        if editor:
            run('codesign', '--force', '--sign', '-', plugin)
        run('codesign', '--force', '--deep', '--sign', '-', app)
        run('codesign', '--verify', '--deep', '--strict', app)
        run('xcrun', 'simctl', 'install', args.simulator, app)
        try:
            captured = run('xcrun', 'simctl', 'launch', '--console', args.simulator, bundle_id,
                           capture_output=True, text=True, timeout=30)
            output = captured.stdout + captured.stderr
            print(output, end='')
            if args.chow_editor:
                required = ('CHOW editor create cocoa floating=0', 'CHOW_EDITOR_PASS')
            else:
                mode = 'SURGE_EDITOR_PASS' if args.editor else 'SURGE_HEADLESS gui unavailable'
                required = ('SURGE_DESCRIPTOR', mode, 'SURGE_PARAMS ',
                            'SURGE_STATE ', 'SURGE_RENDER ', 'SURGE_PASS')
            if any(marker not in output for marker in required):
                raise ValueError('Incomplete Surge CLAP verification')
        finally:
            run('xcrun', 'simctl', 'uninstall', args.simulator, bundle_id)


if __name__ == '__main__':
    main()
