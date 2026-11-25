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
from surge_clap import stage_surge


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('simulator', help='Booted iOS Simulator ID')
    parser.add_argument('surge', type=Path, help='Official local Surge XT 1.3.4 CLAP bundle')
    parser.add_argument('bridge', type=Path, help='Built Simulator libBitwigUIKit.dylib')
    parser.add_argument('clap_include', type=Path, help='Official CLAP SDK include directory')
    args = parser.parse_args()
    sdk = Path(run('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path', capture_output=True, text=True).stdout.strip())
    cc = ['xcrun', '--sdk', 'iphonesimulator', 'clang', '-target', 'arm64-apple-ios17.0-simulator', '-isysroot', sdk]
    bundle_id = 'org.bitwigbridge.surgeloader'
    with tempfile.TemporaryDirectory() as temporary:
        app = Path(temporary) / 'SurgeLoader.app'
        frameworks = app / 'Frameworks'
        frameworks.mkdir(parents=True)
        shutil.copy2(args.bridge, frameworks / 'libBitwigUIKit.dylib')
        stage_surge(args.surge, frameworks, sdk, cc, ROOT / 'native/compat', False)
        (app / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': bundle_id, 'CFBundleExecutable': 'SurgeLoader',
            'CFBundleName': 'SurgeLoader', 'CFBundlePackageType': 'APPL',
            'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
            'MinimumOSVersion': '17.0', 'UIDeviceFamily': [2],
        }))
        run(*cc, '-fobjc-arc', '-DSURGE_HEADLESS', '-I', args.clap_include,
            ROOT / 'tests/surge-clap-probe.m', ROOT / 'tests/surge-clap-probe.c',
            '-framework', 'UIKit', '-Wl,-rpath,@executable_path/Frameworks', '-o', app / 'SurgeLoader')
        run('codesign', '--force', '--deep', '--sign', '-', app)
        run('codesign', '--verify', '--deep', '--strict', app)
        run('xcrun', 'simctl', 'install', args.simulator, app)
        try:
            captured = run('xcrun', 'simctl', 'launch', '--console', args.simulator, bundle_id,
                           capture_output=True, text=True, timeout=30)
            output = captured.stdout + captured.stderr
            print(output, end='')
            required = ('SURGE_DESCRIPTOR', 'SURGE_HEADLESS gui unavailable', 'SURGE_PARAMS ',
                        'SURGE_STATE ', 'SURGE_RENDER ', 'SURGE_PASS')
            if any(marker not in output for marker in required):
                raise ValueError('Incomplete Surge CLAP verification')
        finally:
            run('xcrun', 'simctl', 'uninstall', args.simulator, bundle_id)


if __name__ == '__main__':
    main()
