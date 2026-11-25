#!/usr/bin/env python3
"""Verify the adapted Surge CLAP ABI inside an iOS Simulator process."""
import argparse
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from surge_clap import adapt_image, digest, stage_desktop_frameworks, stage_surge

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


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def stage_chow(source, frameworks, cc):
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    if (info.get('CFBundleIdentifier') != 'org.chowdsp.CHOWTapeModel' or
            info.get('CFBundleShortVersionString') != '2.11.0' or digest(source / CHOW_BINARY) != CHOW_SHA256):
        raise ValueError('Expected the official CHOW Tape Model 2.11.0 universal desktop CLAP')
    destination = frameworks / 'CHOWTapeModel.clap'
    shutil.copytree(source, destination, symlinks=True)
    shutil.rmtree(destination / 'Contents/_CodeSignature', ignore_errors=True)
    binary = destination / CHOW_BINARY
    thin = destination / 'thin-arm64'
    run('xcrun', 'lipo', binary, '-thin', 'arm64', '-output', thin)
    if digest(thin) != CHOW_ARM64_SHA256:
        raise ValueError('Unexpected CHOW Tape Model ARM64 binary')
    thin.write_bytes(adapt_image(bytearray(thin.read_bytes()), editor=True, imports=CHOW_EDITOR_IMPORTS))
    run('xcrun', 'vtool', '-set-build-version', 'iossim', '17.0', '27.2', '-replace', '-output', binary, thin)
    thin.unlink()
    stage_desktop_frameworks(frameworks, cc, ROOT / 'native/compat', CHOW_FRAMEWORKS, editor=True)
    changes = []
    for line in run('otool', '-L', binary, capture_output=True, text=True).stdout.splitlines()[1:]:
        old = line.strip().split(' (compatibility')[0]
        match = re.match(r'/System/Library/Frameworks/([^/]+)\.framework/', old)
        if not match:
            continue
        name = match[1]
        mapped = (f'@rpath/libSurge{name}Bridge.dylib' if name in CHOW_FRAMEWORKS else
                  f'/System/Library/Frameworks/{name}.framework/{name}')
        changes += ['-change', old, mapped]
    run('xcrun', 'install_name_tool', *changes, binary)
    return destination


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
            defines.append('-DCHOW_EDITOR')
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
                required = ('CHOW_EDITOR_PASS',)
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
