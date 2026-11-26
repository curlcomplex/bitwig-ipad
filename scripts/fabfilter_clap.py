"""Stage pinned local FabFilter CLAP bundles without altering their resources."""
import json
import plistlib
from pathlib import Path

from ott_vst3 import stage_desktop_plugin_image
from surge_clap import digest, invoke, stage_desktop_frameworks

RELEASES = {
    'FabFilter Micro.clap': ('1.29', 'com.fabfilter.Micro.Clap.1',
        '9418826d88e446de5b91e0cc8a7bf922d4da1f5c3ccc9a734d0e628c9ad40334'),
    'FabFilter One.clap': ('3.40', 'com.fabfilter.One.Clap.3',
        'e3d7be57c474663efc7b50f4d1ceed2bb518614c8f28be82eb680fe5a473a673'),
    'FabFilter Pro-C 2.clap': ('2.20', 'com.fabfilter.Pro-C.Clap.2',
        '9561b54329d4a4aebe37e8d6a3ae2175d2cea2a5def68d1fb6ee07ed1e0bc2be'),
    'FabFilter Pro-DS.clap': ('1.24', 'com.fabfilter.Pro-DS.Clap.1',
        'cdeddbd698096ed3acc664f35d464de3b5e7371a8bcce1f0b1cc7fef55c2f9b8'),
    'FabFilter Pro-G.clap': ('1.34', 'com.fabfilter.Pro-G.Clap.1',
        '08d66e3bb353afbb9e883ffe5f9f2b475a7a277deade890de9d8364e7c39c067'),
    'FabFilter Pro-L 2.clap': ('2.24', 'com.fabfilter.Pro-L.Clap.2',
        '86eceddfd7709822b0284e054c5bb2cba7ed4ac37471b9d00f6501c4a2ef77dd'),
    'FabFilter Pro-L.clap': ('1.35', 'com.fabfilter.Pro-L.Clap.1',
        '04700d62dc8e1c17e2437e830f98045ab8a6d4ebee92fc53e5c44bdaac784449'),
    'FabFilter Pro-MB.clap': ('1.31', 'com.fabfilter.Pro-MB.Clap.1',
        'c013ad946160364310ca6a7cb0897c8c99c944ea8726b48931763276d26a8619'),
    'FabFilter Pro-Q 2.clap': ('2.28', 'com.fabfilter.Pro-Q.Clap.2',
        '07c31b0fcd75b06f8b50f77cc01cde862050950b2919ab2f5e588c332bbf2847'),
    'FabFilter Pro-Q 3.clap': ('3.26', 'com.fabfilter.Pro-Q.Clap.3',
        'd451133835edf9f39dc06cdfed90e7249b599c942dbd8171d7279f6dfddcf92a'),
    'FabFilter Pro-Q 4.clap': ('4.00', 'com.fabfilter.Pro-Q.Clap.4',
        'a43996596ed85147b6eacf50cc725dba8b053fb5372b54b129f3d2f520a868f7'),
    'FabFilter Pro-R 2.clap': ('2.04', 'com.fabfilter.Pro-R.Clap.2',
        '76fa1438da9d3b206b1b0dff5ba71062f812f54bc493cb722847cd9a78ddc51e'),
    'FabFilter Pro-R.clap': ('1.18', 'com.fabfilter.Pro-R.Clap.1',
        '4a3cf0a0358749145c843d02afdf2ee450ba76ee5459550de9883fd64d5a38b4'),
    'FabFilter Saturn 2.clap': ('2.11', 'com.fabfilter.Saturn.Clap.2',
        'de324bc4e37d900e7a9cd30401fa1fae8da3afc621db1caff18dcf7bc8f071ae'),
    'FabFilter Saturn.clap': ('1.29', 'com.fabfilter.Saturn.Clap.1',
        'd5b512bcd0b9ae557b89a1660c2ce3c3bb8f177bb6589e9ef6f1e73fc3daea24'),
    'FabFilter Simplon.clap': ('1.39', 'com.fabfilter.Simplon.Clap.1',
        '18b0bd87e6ef221bcfdc8eae79f777401bd524effd402c77f65c3a23476f3f43'),
    'FabFilter Timeless 2.clap': ('2.39', 'com.fabfilter.Timeless.Clap.2',
        '052ecb8dc8d74afc6a1f1052ae8edaedc67d564abfbe793b0312ebc7efae5c15'),
    'FabFilter Timeless 3.clap': ('3.08', 'com.fabfilter.Timeless.Clap.3',
        'afe2a7fc47c2806951bd183008578fd49fd5d15e6711cf3b73bf5fde66f9ff05'),
    'FabFilter Twin 2.clap': ('2.39', 'com.fabfilter.Twin.Clap.2',
        'fcff886189961f37b56ca94e59131af94affae2c397d9cc7cce89df75891cba3'),
    'FabFilter Twin 3.clap': ('3.05', 'com.fabfilter.Twin.Clap.3',
        'd9e2ce4c7c28092b84da9cf9204d96323dc7cbc37c7baf699326ff980af716e9'),
    'FabFilter Volcano 2.clap': ('2.39', 'com.fabfilter.Volcano.Clap.2',
        'c45bfc4434feeb7e8ebf869c1ab3db8c5800fe6c914beb37380a98f2cc40c6d1'),
    'FabFilter Volcano 3.clap': ('3.07', 'com.fabfilter.Volcano.Clap.3',
        'f4b381488effbe4864b09bccd7733cd1b8d61b6358a3d2664f708c250a6a9e77'),
}
MANIFEST = 'fabfilter-clap.json'
BRIDGES = {
    'AppKit': '@rpath/libFabFilterAppKitBridge.dylib',
    'ApplicationServices': '@rpath/libSurgeApplicationServicesBridge.dylib',
    'Carbon': '@rpath/libFabFilterCarbonBridge.dylib',
    'Cocoa': '@rpath/libCocoaBridge.dylib',
    'CoreFoundation': '@rpath/libFabFilterPreferencesBridge.dylib',
    'CoreServices': '@rpath/libFabFilterCoreServicesBridge.dylib',
    'CoreVideo': '@rpath/libFabFilterCoreVideoBridge.dylib',
}


def validate_fabfilter_sources(sources):
    selected = {}
    for source in sources:
        name = source.name
        if name not in RELEASES or name in selected:
            raise ValueError(f'Unknown or duplicate FabFilter CLAP bundle: {name}')
        version, identifier, sha256 = RELEASES[name]
        info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
        binary = source / 'Contents/MacOS' / source.stem
        if (info.get('CFBundleShortVersionString'), info.get('CFBundleIdentifier'),
                info.get('CFBundleExecutable')) != (version, identifier, source.stem) or digest(binary) != sha256:
            raise ValueError(f'Expected the supported original {source.stem} {version} release')
        selected[name] = source
    return dict(sorted(selected.items()))


def stage_fabfilter_runtime(frameworks, cc, native):
    stage_desktop_frameworks(frameworks, cc, native, {'AppKit', 'ApplicationServices', 'CoreServices'}, editor=True)
    source = native / 'fabfilter'
    for framework, base, suffix in [('AppKit', 'SurgeAppKit', 'm'), ('Carbon', 'Carbon', 'm'),
                                    ('CoreServices', 'SurgeCoreServices', 'm'), ('CoreVideo', 'CoreVideo', 'c')]:
        bridge = frameworks / f'libFabFilter{framework}Bridge.dylib'
        objc = ['-fobjc-arc', '-framework', 'Foundation', '-framework', 'UIKit'] if suffix == 'm' else []
        invoke(*cc, '-dynamiclib', *objc, source / f'{framework}.{suffix}',
               f'-Wl,-reexport_library,{frameworks / f"lib{base}Bridge.dylib"}',
               frameworks / 'libBitwigUIKit.dylib', '-Wl,-rpath,@loader_path',
               '-install_name', f'@rpath/{bridge.name}', '-o', bridge)
        invoke('codesign', '--force', '--sign', '-', bridge)

    preferences = frameworks / 'libFabFilterPreferencesBridge.dylib'
    invoke(*cc, '-dynamiclib', source / 'Preferences.c', '-Wl,-reexport_framework,CoreFoundation',
           '-install_name', f'@rpath/{preferences.name}', '-o', preferences)
    invoke('codesign', '--force', '--sign', '-', preferences)


def stage_fabfilter(selected, frameworks, sdk, cc, native, *, runtime=True):
    if runtime:
        stage_fabfilter_runtime(frameworks, cc, native)
    products = {}
    for slot, (name, original) in enumerate(selected.items()):
        binary = Path('Contents/MacOS') / original.stem
        image = original.stem.replace(' ', '').replace('-', '') + '.bundle'
        stage_desktop_plugin_image(original, frameworks, sdk, name, binary, image, BRIDGES, (), {})
        products[name] = {'image': image, 'slot': slot}
    (frameworks / MANIFEST).write_text(json.dumps(products, indent=2) + '\n')
