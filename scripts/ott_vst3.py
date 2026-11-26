"""Stage the local Xfer OTT desktop VST3 for the iPad audio engine."""
import plistlib
import re
import shutil
import subprocess
from pathlib import Path

from surge_clap import digest, invoke, weaken_imports

OTT_BUNDLE = 'OTT.vst3'
OTT_BINARY = Path('Contents/MacOS/OTT')
OTT_SHA256 = 'e79f57de181c0984df50df0bc759855c6d0d2813efff2ef07cfacfe0ffeefa42'
BRIDGES = {
    'AppKit': '@rpath/libSurgeAppKitBridge.dylib',
    'AudioUnit': '@rpath/libAudioUnitBridge.dylib',
    'Carbon': '@rpath/libCarbonBridge.dylib',
    'Cocoa': '@rpath/libCocoaBridge.dylib',
    'ColorSync': '@rpath/libOTTColorSyncBridge.dylib',
    'CoreFoundation': '@rpath/libOTTCoreFoundationBridge.dylib',
    'CoreGraphics': '@rpath/libSurgeCoreGraphicsBridge.dylib',
    'CoreServices': '@rpath/libOTTCoreServicesBridge.dylib',
    'Foundation': '@rpath/libSurgeFoundationBridge.dylib',
    # This exact arm64 image has no OpenGL imports.
    'OpenGL': '/System/Library/Frameworks/OpenGLES.framework/OpenGLES',
}
# Desktop editor imports referenced by the original image. Only the audio path
# is exercised before an editor is attached.
DESKTOP_IMPORTS = frozenset(name.encode() for name in '''
_CGEventCreateMouseEvent
_CGWindowListCreateImage
_NSBeep
_OBJC_CLASS_$_NSAlert
_OBJC_CLASS_$_NSAppearance
_OBJC_CLASS_$_NSBitmapImageRep
_OBJC_CLASS_$_NSColorSpace
_OBJC_CLASS_$_NSNib
_OBJC_CLASS_$_NSPopUpButtonCell
_OBJC_CLASS_$_NSTextField
_RunCurrentEventLoop
_UTCreateStringForOSType
_kUTTagClassOSType
'''.split())


def stage_ott_bridges(frameworks, cc, native):
    color = frameworks / 'libOTTColorSyncBridge.dylib'
    invoke(*cc, '-dynamiclib', native / 'ott/ColorSync.c', '-Wl,-reexport_framework,ColorSync',
           '-install_name', f'@rpath/{color.name}', '-o', color)
    invoke('codesign', '--force', '--sign', '-', color)
    bridge = frameworks / 'libOTTDyldBridge.dylib'
    invoke(*cc, '-dynamiclib', native / 'ott/Dyld.c', '-Wl,-reexport-lSystem',
           '-install_name', f'@rpath/{bridge.name}', '-o', bridge)
    invoke('codesign', '--force', '--sign', '-', bridge)
    for name, runtime in [('CoreServices', '-Wl,-reexport-lSystem'),
                          ('CoreFoundation', '-Wl,-reexport_framework,CoreFoundation')]:
        bridge = frameworks / f'libOTT{name}Bridge.dylib'
        invoke(*cc, '-dynamiclib', native / f'ott/{name}.c',
               f'-Wl,-reexport_library,{frameworks / "libBitwigUIKit.dylib"}',
               '-Wl,-rpath,@loader_path', runtime,
               *(['-Wl,-reexport_framework,CoreServices'] if name == 'CoreServices' else []),
               '-install_name', f'@rpath/{bridge.name}', '-o', bridge)
        invoke('codesign', '--force', '--sign', '-', bridge)


def stage_ott(source, frameworks, sdk):
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    if (info.get('CFBundleShortVersionString') != '1.3.1' or
            info.get('CFBundleIdentifier') != 'com.xfer.OTT.VST3' or
            digest(source / OTT_BINARY) != OTT_SHA256):
        raise ValueError('Expected the official universal Xfer OTT 1.3.1 VST3 release')

    return stage_desktop_plugin_image(source, frameworks, sdk, OTT_BUNDLE, OTT_BINARY,
                            'OTT.bundle', BRIDGES, DESKTOP_IMPORTS,
                            {'/usr/lib/libSystem.B.dylib': '@rpath/libOTTDyldBridge.dylib'})


def stage_desktop_plugin_image(source, frameworks, sdk, bundle_name, binary, image_name,
                     bridges, optional_imports, libraries):
    destination = frameworks / bundle_name
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination, symlinks=True,
                    ignore=shutil.ignore_patterns('_CodeSignature'))
    source_copy = destination / binary
    thin = frameworks.parent / f'{image_name}-arm64'
    image = frameworks / image_name
    invoke('xcrun', 'lipo', source_copy, '-thin', 'arm64', '-output', thin)
    if optional_imports:
        thin.write_bytes(weaken_imports(bytearray(thin.read_bytes()), optional_imports))
    invoke('xcrun', 'vtool', '-set-build-version', 'ios', '17.0', '27.2',
           '-replace', '-output', image, thin)
    thin.unlink()
    source_copy.unlink()

    changes = [arg for old, new in libraries.items() for arg in ('-change', old, new)]
    for line in subprocess.check_output(['otool', '-L', image], text=True).splitlines()[1:]:
        old = line.strip().split(' (compatibility')[0]
        match = re.match(r'/System/Library/Frameworks/([^/]+)\.framework/', old)
        if not match:
            continue
        framework = match[1]
        new = bridges.get(framework, f'/System/Library/Frameworks/{framework}.framework/{framework}')
        if new.startswith('/System/') and not (sdk / (new.lstrip('/') + '.tbd')).is_file():
            raise ValueError(f'Missing iOS dependency for {bundle_name}: {new}')
        changes += ['-change', old, new]
    invoke('xcrun', 'install_name_tool', *changes, '-add_rpath', '@loader_path', image)
    invoke('codesign', '--force', '--sign', '-', image)
    return image
