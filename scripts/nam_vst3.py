"""Stage the original local Neural Amp Modeler VST3."""
import plistlib
from pathlib import Path

from ott_vst3 import stage_desktop_plugin_image
from surge_clap import digest, invoke

NAM_BUNDLE = 'NeuralAmpModeler.vst3'
NAM_BINARY = Path('Contents/MacOS/NeuralAmpModeler')
NAM_SHA256 = '36ebe506e4922e705d7d2e59647254497c102888eb7cafb05df56facc3dc28ef'
BRIDGES = {
    'AppKit': '@rpath/libSurgeAppKitBridge.dylib',
    'Carbon': '@rpath/libCarbonBridge.dylib',
    'Cocoa': '@rpath/libCocoaBridge.dylib',
    'CoreGraphics': '@rpath/libSurgeCoreGraphicsBridge.dylib',
    'CoreServices': '@rpath/libSurgeCoreServicesBridge.dylib',
    'Foundation': '@rpath/libSurgeFoundationBridge.dylib',
}
OPTIONAL_EDITOR_IMPORTS = frozenset(name.encode() for name in '''
_NSAppearanceNameDarkAqua
_NSRunAlertPanel
_OBJC_CLASS_$_NSAnimationContext
_OBJC_CLASS_$_NSBitmapImageRep
_OBJC_CLASS_$_NSColorPanel
_OBJC_CLASS_$_NSTextField
_OBJC_CLASS_$_NSTextFieldCell
_OBJC_METACLASS_$_NSTextField
_OBJC_METACLASS_$_NSTextFieldCell
'''.split())


def stage_nam(source, frameworks, sdk):
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    if (info.get('CFBundleShortVersionString') != '0.7.13' or
            info.get('CFBundleIdentifier') != 'com.StevenAtkinson.vst3.NeuralAmpModeler' or
            digest(source / NAM_BINARY) != NAM_SHA256):
        raise ValueError('Expected the official universal Neural Amp Modeler 0.7.13 VST3 release')
    return stage_desktop_plugin_image(source, frameworks, sdk, NAM_BUNDLE, NAM_BINARY,
                            'NeuralAmpModeler.bundle', BRIDGES, OPTIONAL_EDITOR_IMPORTS,
                            {'/usr/lib/libSystem.B.dylib': '@rpath/libNAMSystemBridge.dylib'})


def stage_nam_shader(frameworks, cc, native, sdk_name, *, runtime=True):
    shader = native / 'nam/nanovg_mtl_shaders.metal'
    object_file = frameworks.parent / 'nam-nanovg.air'
    library = frameworks / NAM_BUNDLE / 'Contents/Resources/NeuralAmpModeler-iOS.metallib'
    target = 'air64-apple-ios17.0' + ('-simulator' if sdk_name == 'iphonesimulator' else '')
    invoke('xcrun', '--sdk', sdk_name, 'metal', '-target', target, '-c', shader, '-o', object_file)
    invoke('xcrun', '--sdk', sdk_name, 'metallib', object_file, '-o', library)
    if runtime:
        stage_nam_runtime(frameworks, cc, native)


def stage_nam_runtime(frameworks, cc, native):
    bridge = frameworks / 'libNAMSystemBridge.dylib'
    invoke(*cc, '-fobjc-arc', '-dynamiclib', native / 'nam/ShaderData.m',
           '-framework', 'Foundation', '-Wl,-reexport-lSystem',
           '-install_name', f'@rpath/{bridge.name}', '-o', bridge)
    invoke('codesign', '--force', '--sign', '-', bridge)
