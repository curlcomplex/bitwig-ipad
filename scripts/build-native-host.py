#!/usr/bin/env python3
"""Adapt copied Bitwig native images and build the UIKit compatibility library."""
import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import shutil
import tempfile
import zipfile
from pathlib import Path
from bitwig_source import BitwigSource, ENGINE, JNI, ROOT, java_probe_info, sha256
from surge_clap import BUNDLE_NAME, CHOW_BUNDLE, HELPER_PATH, stage_bundle_loader, stage_desktop_frameworks, stage_surge, stage_metadata_helper, stage_surge_runtime
from ott_vst3 import OTT_BUNDLE, stage_ott, stage_ott_bridges
from nam_vst3 import NAM_BUNDLE, stage_nam, stage_nam_shader, stage_nam_runtime
from fabfilter_clap import RELEASES, stage_fabfilter, stage_fabfilter_runtime, validate_fabfilter_sources
from local_config import build_identity, jni_include_paths, selected_simulator, simulator_argument
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--run',action='store_true',help='Install and launch the built Simulator host')
simulator_argument(parser)
parser.add_argument('--device',action='store_true',help='Build/sign the native iPad host with its embedded JIT helper')
parser.add_argument('--embedded-tunnel',action='store_true',help='Include the local developer tunnel in the iPad app; configuration requires its setup button')
parser.add_argument('--embedded-engine',action='store_true',help='Include the adapted audio engine in its own native extension process')
parser.add_argument('--grid-rate-overlay', action='store_true',
                    help='Stage the local Bitwig 6.1.7 Grid rate development classes')
parser.add_argument('--independent-plugins', action='store_true', help='Include plug-in runtime support and import prepared folders on iPad')
parser.add_argument('--surge-clap', type=Path, help='Include the supported local Surge XT 1.3.4 desktop CLAP')
parser.add_argument('--surge-editor-clap-include', type=Path, help='Enable the experimental Surge editor using the official CLAP SDK include directory')
parser.add_argument('--chow-clap', type=Path, help='Also include the supported CHOW Tape Model 2.11.0 desktop CLAP')
parser.add_argument('--ott-vst3', type=Path, help='Include the supported local Xfer OTT 1.3.1 desktop VST3')
parser.add_argument('--nam-vst3', type=Path, help='Include the supported local Neural Amp Modeler 0.7.13 desktop VST3')
parser.add_argument('--fabfilter-clap', type=Path, action='append', default=[],
                    help='Include a supported FabFilter desktop CLAP bundle (repeatable)')
bitwig=BitwigSource(parser);args=bitwig.args
if args.grid_rate_overlay and not (args.device and args.embedded_engine and bitwig.version == '6.1.7'):
    parser.error('--grid-rate-overlay requires Bitwig 6.1.7 with --device and --embedded-engine')
if args.fabfilter_clap and not (args.device and args.embedded_engine):
    parser.error('--fabfilter-clap requires --device and --embedded-engine')
try:
    fabfilter = validate_fabfilter_sources(args.fabfilter_clap)
except (OSError, ValueError) as error:
    parser.error(str(error))
if args.independent_plugins:
    if not (args.device and args.embedded_engine and args.surge_editor_clap_include):
        parser.error('--independent-plugins requires --device, --embedded-engine, and --surge-editor-clap-include')
    if any((args.surge_clap, args.chow_clap, args.ott_vst3, args.nam_vst3, fabfilter)):
        parser.error('--independent-plugins uses prepared folders instead of bundling plug-ins')
plugin_metadata = args.independent_plugins or args.surge_clap or args.ott_vst3 or args.nam_vst3 or fabfilter
if args.nam_vst3 and not (args.device and args.embedded_engine):
    parser.error('--nam-vst3 requires --device and --embedded-engine')
if args.ott_vst3 and not (args.device and args.embedded_engine):
    parser.error('--ott-vst3 requires --device and --embedded-engine')
if args.surge_clap and not args.embedded_engine: parser.error('--surge-clap requires --embedded-engine')
if args.chow_clap and not args.surge_editor_clap_include: parser.error('--chow-clap requires --surge-editor-clap-include')
if args.surge_editor_clap_include and (not (args.surge_clap or args.independent_plugins) or not (args.surge_editor_clap_include/'clap/clap.h').is_file()):
    parser.error('--surge-editor-clap-include needs plug-in support (--surge-clap or --independent-plugins) and the official CLAP SDK include directory')
if args.embedded_tunnel and not args.device: parser.error('--embedded-tunnel requires --device')
if args.embedded_engine and not args.device: parser.error('--embedded-engine requires --device')
if args.run and args.device: parser.error('--run only applies to the Simulator host')
simulator = selected_simulator(parser, args.simulator) if args.run else None
identity = build_identity(parser, args.device, args.embedded_engine)
jni_headers = jni_include_paths(parser)
SOURCE = bitwig.contents
managed_plugin_refresh = args.independent_plugins and bitwig.version == '6.1.7' and (
    sha256(SOURCE/'Java'/'bitwig.jar') == '6024752847797eb41e6fbc91e081211937931cc452a695ab78226321cefdac8d')
build_name = 'native-host-tunnel' if args.embedded_tunnel else 'native-host-device' if args.device else 'native-host'
if args.embedded_tunnel and not args.embedded_engine: build_name += '-no-engine'
if args.embedded_engine and not args.embedded_tunnel: build_name += '-engine'
if args.independent_plugins: build_name += '-independent-plugins'
if args.grid_rate_overlay: build_name += '-grid-rate-overlay'
if args.surge_clap: build_name += '-surge'
if args.surge_editor_clap_include: build_name += '-editor'
if args.chow_clap: build_name += '-chow'
if args.ott_vst3: build_name += '-ott'
if args.nam_vst3: build_name += '-nam'
if fabfilter:
    build_name += '-fabfilter-' + hashlib.sha256('\0'.join(fabfilter).encode()).hexdigest()[:12]
BUILD = bitwig.build / build_name
audit_path = bitwig.evidence / 'native-port-audit.json'
try:
    audit = json.loads(audit_path.read_text())['binaries']['jni']
    if any(audit[key] != value for key, value in bitwig.identity(JNI).items()):
        raise ValueError('audit is from a different JNI image')
except (OSError, ValueError, KeyError) as error:
    parser.error(f'Run audit-native-port.py with the same Bitwig source: {error}')
if args.embedded_engine:
    try:
        adaptation = json.loads((bitwig.evidence / 'native-engine-device-adaptation.json').read_text())
        engine_app = bitwig.build / 'native-engine-probe-device/BitwigEngineProbe.app'
        engine_bundle = engine_app / 'Frameworks/BitwigAudioEngine.bundle'
        entry_path = engine_app / 'engine-entry.json'
        entry = json.loads(entry_path.read_text())['entry_offset']
        if (adaptation['source'] != bitwig.identity(ENGINE) or
                adaptation['adapted_sha256'] != sha256(engine_bundle) or
                adaptation['entry_offset'] != entry):
            raise ValueError('adaptation is from a different engine image or is incomplete')
    except (OSError, ValueError, KeyError) as error:
        parser.error(f'Run build-native-engine-probe.py --device with the same Bitwig source: {error}')
LIB=BUILD/'Frameworks'
LIB.mkdir(parents=True,exist_ok=True)
sdk_name='iphoneos' if args.device else 'iphonesimulator'
SDK=Path(subprocess.check_output(['xcrun','--sdk',sdk_name,'--show-sdk-path'],text=True).strip())
CC=['xcrun','--sdk',sdk_name,'clang','-target','arm64-apple-ios17.0'+('' if args.device else '-simulator'),'-isysroot',str(SDK),'-g']
def run(*args): subprocess.run(list(map(str,args)),check=True)
run(*CC,'-fobjc-arc','-dynamiclib',ROOT/'native/compat/Posix.m',ROOT/'native/compat/EngineJIT.m','-framework','Foundation','-Wl,-reexport-lSystem','-install_name','@rpath/libPosixBridge.dylib','-o',LIB/'libPosixBridge.dylib')
compat=LIB/'libBitwigUIKit.dylib'
frameworks=['UIKit','Foundation','CoreFoundation','CoreGraphics','QuartzCore','CoreServices','CoreVideo','GameController','Metal','UniformTypeIdentifiers']
run(*CC,'-fno-objc-arc','-c',ROOT/'native/compat/Metal.m','-o',BUILD/'Metal.o')
compat_sources = [ROOT/'native/compat/AppKit.m', ROOT/'native/compat/DesktopServices.m']
if args.independent_plugins or args.surge_editor_clap_include or args.ott_vst3 or args.nam_vst3 or fabfilter: compat_sources.append(ROOT/'native/compat/surge/EditorSurface.m')
compat_defines = ['-DBW_VSTGUI_EDITOR=1'] if args.ott_vst3 or args.independent_plugins else []
if args.surge_editor_clap_include: compat_defines.append('-DBW_JUCE_EDITOR=1')
if fabfilter or args.independent_plugins:
    compat_sources.extend(ROOT/'native/compat/fabfilter'/name for name in ('View.m', 'Menu.m'))
    compat_defines.append('-DBW_FABFILTER_EDITOR=1')
if args.nam_vst3 or args.independent_plugins:
    compat_sources += [ROOT/'native/compat/nam'/name for name in ('Layer.m', 'Capture.m')]
    compat_defines.append('-DBW_IPLUG_EDITOR=1')

run(*CC,'-fobjc-arc','-dynamiclib',*compat_defines,*compat_sources,BUILD/'Metal.o',*[arg for fw in frameworks for arg in ['-framework',fw]],*[f'-Wl,-reexport_framework,{fw}' for fw in frameworks],'-install_name','@rpath/libBitwigUIKit.dylib','-o',compat)
bridge_frameworks=['AppKit','Cocoa','Carbon','CoreServices','CoreGraphics','CoreVideo']
for fw in bridge_frameworks:
    bridge=LIB/f'lib{fw}Bridge.dylib'
    run(*CC,'-dynamiclib',ROOT/'native/compat/Forward.c',f'-Wl,-reexport_library,{compat}','-Wl,-rpath,@loader_path','-install_name',f'@rpath/{bridge.name}','-o',bridge)
    run('codesign','--force','--sign','-',bridge)
mapping={}
if args.embedded_engine:
    # Compile current audio sources; do not silently reuse a stale probe dylib.
    run(*CC,'-fobjc-arc','-dynamiclib',ROOT/'native/compat/AudioHAL.m',ROOT/'native/compat/AudioOutputProxy.m','-framework','Foundation','-framework','AVFAudio','-Wl,-reexport_framework,CoreAudio','-Wl,-reexport_framework,AudioToolbox','-install_name','@rpath/libAudioHALBridge.dylib','-o',LIB/'libAudioHALBridge.dylib')
    for name in ['libAudioUnitBridge.dylib','libAudioToolboxBridge.dylib']:
        run(*CC,'-dynamiclib',ROOT/'native/compat/Forward.c',f'-Wl,-reexport_library,{LIB / "libAudioHALBridge.dylib"}','-Wl,-rpath,@loader_path','-install_name','@rpath/'+name,'-o',LIB/name)
with zipfile.ZipFile(SOURCE / 'Java/libs.jar') as jar:
    (BUILD/'libjnidispatch.jnilib').write_bytes(jar.read('com/sun/jna/darwin-aarch64/libjnidispatch.jnilib'))
for name in ['libbitwig-jni.jnilib','JavaNativeFoundation','libsqlitejdbc.jnilib','libjnidispatch.jnilib']:
    source=(SOURCE / 'Frameworks')/name
    if name=='libjnidispatch.jnilib': source=BUILD/name
    thin=BUILD/(name+'.arm64')
    dest=LIB/name
    archs=subprocess.check_output(['xcrun','lipo','-archs',str(source)],text=True).split()
    if len(archs)==1: shutil.copy2(source,thin)
    else: run('xcrun','lipo',source,'-thin','arm64','-output',thin)
    run('xcrun','vtool','-set-build-version','ios' if args.device else 'iossim','17.0','27.2','-replace','-output',dest,thin)
    run('xcrun','install_name_tool','-id','@rpath/'+name,dest)
    deps=subprocess.check_output(['xcrun','otool','-L',str(dest)],text=True).splitlines()[2:]
    changes={}
    for line in deps:
        old=line.strip().split(' (compatibility')[0]
        new=old
        framework=re.search(r'/([^/]+)\.framework/',old)
        if framework:
            fw=framework[1]
            if fw in bridge_frameworks:
                new=f'@rpath/lib{fw}Bridge.dylib'
            else:
                tbd=SDK/'System/Library/Frameworks'/f'{fw}.framework'/f'{fw}.tbd'
                if tbd.exists():
                    m=re.search(r"^install-name:\s*['\"]?([^'\"\n]+)",tbd.read_text(),re.MULTILINE)
                    if m: new=m[1].strip()
        if old=='@rpath/JavaNativeFoundation': new='@loader_path/JavaNativeFoundation'
        if name=='libbitwig-jni.jnilib' and old=='/usr/lib/libSystem.B.dylib':new='@rpath/libPosixBridge.dylib'
        if new!=old:
            run('xcrun','install_name_tool','-change',old,new,dest);changes[old]=new
    run('xcrun','install_name_tool','-add_rpath','@loader_path',dest)
    run('codesign','--force','--sign','-',dest)
    mapping[name]=changes
run('codesign','--force','--sign','-',compat)
if args.surge_clap:
    try:
        stage_surge(args.surge_clap, LIB, SDK, CC, ROOT/'native/compat', args.device,
                    editor_headers=args.surge_editor_clap_include, chow=args.chow_clap)
    except (OSError, ValueError) as error:
        parser.error(f'Could not stage Surge XT CLAP: {error}')
if args.ott_vst3:
    try:
        native = ROOT/'native/compat'
        stage_desktop_frameworks(LIB, CC, native, {'AppKit', 'CoreGraphics', 'Foundation'}, editor=True)
        if not args.surge_clap:
            stage_bundle_loader(LIB, CC, native)
        stage_ott_bridges(LIB, CC, native)
        stage_ott(args.ott_vst3, LIB, SDK)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.error(f'Could not stage Xfer OTT VST3: {error}')
if args.nam_vst3:
    try:
        native = ROOT/'native/compat'
        stage_desktop_frameworks(LIB, CC, native, {'AppKit', 'CoreGraphics', 'CoreServices', 'Foundation'}, editor=True)
        if not (args.surge_clap or args.ott_vst3):
            stage_bundle_loader(LIB, CC, native)
        stage_nam(args.nam_vst3, LIB, SDK)
        stage_nam_shader(LIB, CC, native, sdk_name)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.error(f'Could not stage Neural Amp Modeler VST3: {error}')
if fabfilter:
    try:
        native = ROOT/'native/compat'
        if not (args.surge_clap or args.ott_vst3 or args.nam_vst3):
            stage_bundle_loader(LIB, CC, native)
        stage_fabfilter(fabfilter, LIB, SDK, CC, native)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.error(f'Could not stage FabFilter CLAP: {error}')
if args.independent_plugins:
    native = ROOT/'native/compat'
    stage_surge_runtime(LIB, CC, native, True, editor_headers=args.surge_editor_clap_include, chow=True)
    stage_desktop_frameworks(LIB, CC, native, {'AppKit', 'CoreGraphics', 'CoreServices', 'Foundation'}, editor=True)
    stage_ott_bridges(LIB, CC, native)
    stage_nam_runtime(LIB, CC, native)
    stage_fabfilter_runtime(LIB, CC, native)
if plugin_metadata:
    try:
        stage_metadata_helper(SOURCE, LIB, BUILD)
    except (OSError, ValueError) as error:
        parser.error(f'Could not stage Bitwig Plug-in Host: {error}')
(bitwig.evidence/('native-host-device-library-mappings.json' if args.device else 'native-host-library-mappings.json')).write_text(json.dumps(mapping,indent=2)+'\n')
print(LIB)
APP=BUILD/'BitwigNativeHost.app'
APP.mkdir(exist_ok=True)
if args.device:
    for folder in ['lib','conf']:shutil.copytree(ROOT/'vendor/java25-ios'/folder,APP/'jre'/folder,dirs_exist_ok=True)
    shutil.copy2(ROOT/'vendor/java25-ios/release',APP/'jre/release')
else:shutil.copytree(bitwig.build/'native-java/BitwigJavaProbe.app/jre',APP/'jre',dirs_exist_ok=True)
if args.surge_clap:
    for name in (BUNDLE_NAME, CHOW_BUNDLE) if args.chow_clap else (BUNDLE_NAME,):
        previous_bundle=APP/'Frameworks'/name
        if previous_bundle.exists(): shutil.rmtree(previous_bundle)
if args.ott_vst3 and (APP/'Frameworks'/OTT_BUNDLE).exists():
    shutil.rmtree(APP/'Frameworks'/OTT_BUNDLE)
if args.nam_vst3 and (APP/'Frameworks'/NAM_BUNDLE).exists():
    shutil.rmtree(APP/'Frameworks'/NAM_BUNDLE)
shutil.copytree(LIB,APP/'Frameworks',dirs_exist_ok=True)
if args.embedded_engine:
    shutil.copy2(engine_bundle,APP/'Frameworks'/engine_bundle.name)
    if plugin_metadata:
        local_engine=APP/'Frameworks'/engine_bundle.name
        run('xcrun','install_name_tool','-change','/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
            '@rpath/libSurgeCoreFoundationBridge.dylib',local_engine)
    shutil.copy2(entry_path,APP/'engine-entry.json')
    engine_path=APP/'installation/Contents/MacOS/Bitwig Audio Engine ARM64-NEON.app/Contents/MacOS/BitwigAudioEngine-ARM64-NEON'
    engine_path.parent.mkdir(parents=True,exist_ok=True)
    if not engine_path.is_symlink():engine_path.symlink_to('../../../../../../Frameworks/BitwigAudioEngine.bundle')
    if plugin_metadata:
        helper_path=APP/'installation/Contents'/HELPER_PATH
        helper_path.parent.mkdir(parents=True,exist_ok=True)
        if not helper_path.is_symlink(): helper_path.symlink_to('../../../../../../Frameworks/BitwigPluginHost.bundle')
for name in ['bitwig.jar','libs.jar']: shutil.copy2(SOURCE/'Java'/name,APP/name)
if managed_plugin_refresh:
    jdk_bin = Path(jni_headers[0]).parent/'bin'
    with tempfile.TemporaryDirectory(dir=BUILD) as scratch:
        classes = Path(scratch)
        classpath = ':'.join(str(APP/name) for name in ('bitwig.jar', 'libs.jar'))
        run(jdk_bin/'javac', '--release', '25', '-cp', classpath, '-d', classes,
            ROOT/'probe/plugin-files/ManagedPluginRefresh.java')
        run(jdk_bin/'jar', '--create', '--file', APP/'ManagedPluginRefresh.jar', '-C', classes, '.')
if args.grid_rate_overlay:
    with tempfile.TemporaryDirectory(dir=BUILD) as scratch:
        grid_overlay = Path(scratch) / 'GridRate.jar'
        run('python3', ROOT/'probe/grid-rate/prepare.py', SOURCE.parent, grid_overlay)
        shutil.copy2(grid_overlay, APP/'GridRate.jar')
resources = APP / 'installation/Contents/Resources'
if resources.exists(): shutil.rmtree(resources)
shutil.copytree(SOURCE / 'Resources', resources)
if (APP/'Contents').exists(): shutil.rmtree(APP/'Contents')  # Superseded generated bundle layout.
manifest=[]
for dep in audit['dependencies']:
    if 'libbitwig-jni' in dep: continue
    name=dep.split('/')[-1]
    syms=audit['imports_by_library'].get(name,audit['imports_by_library'].get(name.split('.')[0],[]))
    if name=='JavaNativeFoundation': syms=audit['imports_by_library']['@rpath/JavaNativeFoundation']
    manifest.append({'library':mapping['libbitwig-jni.jnilib'].get(dep,dep),'symbols':[s[1:] for s in syms]})
(APP/'native-imports.json').write_text(json.dumps(manifest))
info = java_probe_info(identity)
info.update(identity.group_info())
if args.embedded_engine: info['UIBackgroundModes']=['audio']
info.update(UIStatusBarHidden=True,UIViewControllerBasedStatusBarAppearance=False,UIRequiresFullScreen=True,CFBundleDisplayName='Bitwig',CFBundleIdentifier=identity.bundle('nativehost'),CFBundleExecutable='BitwigNativeHost',CFBundleName='Bitwig Native Host')
info.update(UIFileSharingEnabled=True,LSSupportsOpeningDocumentsInPlace=True)
if args.independent_plugins:
    info['BWIndependentPlugins'] = True
    info['BWPreparedPluginRecipes'] = {
        BUNDLE_NAME: ['org.surge-synth-team.surge-xt', '1.3.4'],
        CHOW_BUNDLE: ['org.chowdsp.CHOWTapeModel', '2.11.0'],
        OTT_BUNDLE: ['com.xfer.OTT.VST3', '1.3.1'],
        NAM_BUNDLE: ['com.StevenAtkinson.vst3.NeuralAmpModeler', '0.7.13'],
        **{name: [identifier, version] for name, (version, identifier, _) in RELEASES.items()},
    }
if args.device:info.update(NSLocalNetworkUsageDescription='The embedded Java JIT helper connects to this iPad through its local developer tunnel.')
# Extract the icon from the user's licensed local installation, never distribute it.
icons=BUILD/'Assets.xcassets/AppIcon.appiconset';icons.mkdir(parents=True,exist_ok=True)
run('sips','-s','format','png',SOURCE/'Resources/Bitwig Studio.icns','--out',icons/'AppIcon.png')
run('sips','-z','1024','1024',icons/'AppIcon.png')
(icons/'Contents.json').write_text(json.dumps({'images':[{'filename':'AppIcon.png','idiom':'universal','platform':'ios','size':'1024x1024'}],'info':{'author':'xcode','version':1}}))
(APP/'Info.plist').write_bytes(plistlib.dumps(info))
if args.device:
    generated=BUILD/'JITSource';generated.mkdir(exist_ok=True)
    upstream=ROOT/'vendor/Henge/ios'
    for relative in ['Henge/JIT/JITBuiltIn.swift','HengeJITHelper/HengeJITMessages.swift','HengeJITHelper/HengeJITHelper.swift','HengeJITHelper/RSDPortScanner.swift','HengeJITHelper/RSDPortResolver.swift']:
        source=upstream/relative
        contents=source.read_text().replace('Henge','Bitwig').replace('henge','bitwig')
        if source.name=='HengeJITHelper.swift':
            start=contents.index('            // Bitwig found no advertised port.')
            end=contents.index('\n        }',start)
            contents=contents[:start]+'''            // Bonjour can resolve another Mac on the LAN. Only probe the
            // local developer-tunnel endpoint, never reuse a stranger's port.
            needsScan = true
            portNote = " [discovering this device through its local developer tunnel]"'''+contents[end:]
            contents=contents.replace('let last = UInt16(exactly:', 'if works(base.rsdPort) { return base.rsdPort }\n        let last = UInt16(exactly:')
        (generated/source.name.replace('Henge','Bitwig')).write_text(contents)
    helper_info=plistlib.loads((upstream/'HengeJITHelper/Info.plist').read_bytes())
    helper_info['NSExtension']['NSExtensionPrincipalClass']='BitwigJITHelperHandler'
    helper_info['CFBundleDisplayName']='Bitwig Java Helper'
    helper_info['CFBundleVersion']=info['CFBundleVersion']
    helper_info['CFBundleShortVersionString']=info['CFBundleShortVersionString']
    (BUILD/'Helper-Info.plist').write_bytes(plistlib.dumps(helper_info))
    entitlements={'get-task-allow':True,'com.apple.developer.kernel.increased-memory-limit':True,'com.apple.developer.kernel.extended-virtual-addressing':True}
    if args.embedded_tunnel: entitlements['com.apple.developer.networking.networkextension']=['packet-tunnel-provider']
    if identity.app_group:entitlements.update(identity.group_entitlements())
    (BUILD/'Host.entitlements').write_bytes(plistlib.dumps(entitlements))
    framework=ROOT/'vendor/Husk/src/app/Frameworks/StikJIT.xcframework'
    common={'DEVELOPMENT_TEAM':identity.team,'CODE_SIGN_STYLE':'Automatic','SWIFT_VERSION':'5.0','TARGETED_DEVICE_FAMILY':'2'}
    resources=[{'path':str(APP/name),'type':'folder','buildPhase':'resources'} for name in ['jre','installation','Frameworks']]
    resources += [{'path':str(BUILD/'Assets.xcassets'),'buildPhase':'resources'}]
    resources += [{'path':str(APP/name),'buildPhase':'resources'} for name in ['bitwig.jar','libs.jar','native-imports.json']]
    java_defines = ['$(inherited)', 'FULL_BITWIG_HOST=1']
    if managed_plugin_refresh:
        resources.append({'path':str(APP/'ManagedPluginRefresh.jar'),'buildPhase':'resources'})
        java_defines.append('BW_MANAGED_PLUGIN_REFRESH=1')
    if args.grid_rate_overlay:
        resources.append({'path':str(APP/'GridRate.jar'),'buildPhase':'resources'})
        java_defines.append('GRID_RATE_OVERLAY=1')
    sign_script='''python3 - <<'PYSIGN'
import os,pathlib,subprocess
root=pathlib.Path(os.environ['TARGET_BUILD_DIR'])/os.environ['WRAPPER_NAME']
for folder in ['jre','Frameworks']:
 for file in (root/folder).rglob('*'):
  if file.is_file():
   with file.open('rb') as stream:magic=stream.read(4)
   if magic in [b'\\xcf\\xfa\\xed\\xfe',b'\\xca\\xfe\\xba\\xbe']:
    subprocess.run(['codesign','--force','--sign',os.environ['EXPANDED_CODE_SIGN_IDENTITY'],str(file)],check=True)
PYSIGN'''
    project={'name':'BitwigNativeHost','targets':{
      'BitwigNativeHost':{'type':'application','platform':'iOS','deploymentTarget':'26.0',
        'sources':[{'path':str(ROOT/'probe/native-java.m')},{'path':str(ROOT/'native/NativeJITCoordinator.swift')},{'path':str(generated/'JITBuiltIn.swift')},{'path':str(generated/'BitwigJITMessages.swift')},*resources,{'path':str(ROOT/'native/native-java-jit.js'),'buildPhase':'resources'}],
        'dependencies':[{'target':'BitwigJITHelper','embed':True},{'sdk':'QuartzCore.framework'}],
        'settings':{'base':{**common,'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','PRODUCT_BUNDLE_IDENTIFIER':info['CFBundleIdentifier'],'INFOPLIST_FILE':str(APP/'Info.plist'),'CODE_SIGN_ENTITLEMENTS':str(BUILD/'Host.entitlements'),'GCC_PREPROCESSOR_DEFINITIONS':java_defines,'HEADER_SEARCH_PATHS':jni_headers,'OTHER_LDFLAGS':['$(inherited)','-Wl,-export_dynamic'],'CLANG_ENABLE_OBJC_ARC':'YES'}},
        'postBuildScripts':[{'name':'Sign native Java and adapted Bitwig libraries','script':sign_script,'basedOnDependencyAnalysis':False}]},
      'BitwigJITHelper':{'type':'app-extension','platform':'iOS','deploymentTarget':'26.0',
        'sources':[{'path':str(generated/name)} for name in ['BitwigJITHelper.swift','BitwigJITMessages.swift','RSDPortScanner.swift','RSDPortResolver.swift']],
        'dependencies':[{'framework':str(framework),'embed':True}],
        'settings':{'base':{**common,'PRODUCT_BUNDLE_IDENTIFIER':info['CFBundleIdentifier']+'.jithelper','INFOPLIST_FILE':str(BUILD/'Helper-Info.plist'),'APPLICATION_EXTENSION_API_ONLY':'YES'}}}
    }}
    if args.embedded_engine:
        info['NSMicrophoneUsageDescription'] = 'Use the iPad microphone or connected audio inputs in Bitwig Studio.'
        (APP/'Info.plist').write_bytes(plistlib.dumps(info))
        host=project['targets']['BitwigNativeHost']
        host['sources'].append({'path':str(ROOT/'native/native-engine-jit.js'),'buildPhase':'resources'})
        host['sources'] += [{'path':str(ROOT/'native/NativeEngineCoordinator.swift')},{'path':str(ROOT/'native/NativeEngineProcess.m')},{'path':str(ROOT/'native/NativeAudioOutput.m')},{'path':str(APP/'engine-entry.json'),'buildPhase':'resources'}]
        host['settings']['base']['OTHER_LDFLAGS'] += ['-framework','AVFAudio','-framework','AudioToolbox']
        host['settings']['base']['GCC_PREPROCESSOR_DEFINITIONS'].append('EMBEDDED_ENGINE=1')
        host['dependencies'].append({'target':'BitwigEngine','embed':True})
        engine_info=dict(helper_info)
        engine_info['NSExtension']=dict(helper_info['NSExtension'],NSExtensionPrincipalClass='NativeEngineHandler')
        engine_info['CFBundleDisplayName']='Bitwig Audio Engine'
        engine_info.pop('NSBonjourServices',None)
        engine_info['NSLocalNetworkUsageDescription']='The audio engine communicates with the Bitwig interface on this iPad.'
        engine_info.update(identity.group_info())
        (BUILD/'Engine-Info.plist').write_bytes(plistlib.dumps(engine_info))
        (BUILD/'Engine.entitlements').write_bytes(plistlib.dumps(identity.group_entitlements()))
        project['targets']['BitwigEngine']={'type':'app-extension','platform':'iOS','deploymentTarget':'26.0',
            'sources':[{'path':str(ROOT/'native/NativeEngineExtension.m')},{'path':str(ROOT/'native/DSPProfile.m')}],
            'settings':{'base':{**common,'PRODUCT_BUNDLE_IDENTIFIER':info['CFBundleIdentifier']+'.engine',
                'INFOPLIST_FILE':str(BUILD/'Engine-Info.plist'),'CODE_SIGN_ENTITLEMENTS':str(BUILD/'Engine.entitlements'),'CLANG_ENABLE_OBJC_ARC':'YES',
                'APPLICATION_EXTENSION_API_ONLY':'YES','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/../../Frameworks'}}}
    if args.independent_plugins:
        host['sources'].append({'path':str(ROOT/'native/compat/PluginPackage.m')})
        host['settings']['base']['GCC_PREPROCESSOR_DEFINITIONS'].append('BW_INDEPENDENT_PLUGIN_FILES=1')
    if plugin_metadata:
        host['sources'].append({'path':str(ROOT/'native/NativePluginMetadataCoordinator.swift')})
        host['dependencies'].append({'target':'BitwigPluginMetadata','embed':True})
        metadata_info=dict(engine_info)
        metadata_info['NSExtension']=dict(engine_info['NSExtension'],NSExtensionPrincipalClass='NativePluginMetadataHandler')
        metadata_info['CFBundleDisplayName']='Bitwig Plug-in Metadata'
        (BUILD/'Plug-in-Metadata-Info.plist').write_bytes(plistlib.dumps(metadata_info))
        project['targets']['BitwigPluginMetadata']={'type':'app-extension','platform':'iOS','deploymentTarget':'26.0',
            'sources':[{'path':str(ROOT/'native/NativePluginMetadataExtension.m')}],
            'settings':{'base':{**common,'PRODUCT_BUNDLE_IDENTIFIER':info['CFBundleIdentifier']+'.pluginmetadata',
                'INFOPLIST_FILE':str(BUILD/'Plug-in-Metadata-Info.plist'),'CODE_SIGN_ENTITLEMENTS':str(BUILD/'Engine.entitlements'),
                'CLANG_ENABLE_OBJC_ARC':'YES','APPLICATION_EXTENSION_API_ONLY':'YES',
                'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/../../Frameworks'}}}
    if args.independent_plugins or args.surge_editor_clap_include or args.ott_vst3 or args.nam_vst3 or fabfilter:
        host['settings']['base']['GCC_PREPROCESSOR_DEFINITIONS'].append('BW_SURGE_REMOTE=1')
    if args.embedded_tunnel:
        host=project['targets']['BitwigNativeHost']
        host['sources'] += [
            {'path':str(ROOT/'native/NativeTunnelCoordinator.swift')},
            {'path':str(ROOT/'native/LocalDevVPN-LICENSE.txt'),'buildPhase':'resources'}]
        host['dependencies'].append({'target':'BitwigTunnel','embed':True})
        host['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS']=['$(inherited)','EMBEDDED_TUNNEL']
        tunnel_info={
            'CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleExecutable':'$(EXECUTABLE_NAME)',
            'CFBundleName':'$(PRODUCT_NAME)','CFBundlePackageType':'XPC!',
            'CFBundleDisplayName':'Bitwig Local Developer Tunnel',
            'CFBundleVersion':info['CFBundleVersion'],'CFBundleShortVersionString':info['CFBundleShortVersionString'],
            'NSExtension':{'NSExtensionPointIdentifier':'com.apple.networkextension.packet-tunnel',
                           'NSExtensionPrincipalClass':'$(PRODUCT_MODULE_NAME).BitwigTunnelProvider'}}
        (BUILD/'Tunnel-Info.plist').write_bytes(plistlib.dumps(tunnel_info))
        (BUILD/'Tunnel.entitlements').write_bytes(plistlib.dumps({'com.apple.developer.networking.networkextension':['packet-tunnel-provider']}))
        project['targets']['BitwigTunnel']={
            'type':'app-extension','platform':'iOS','deploymentTarget':'26.0',
            'sources':[{'path':str(ROOT/'native/BitwigTunnelProvider.swift')}],
            'dependencies':[{'sdk':'NetworkExtension.framework'}],
            'settings':{'base':{**common,'PRODUCT_BUNDLE_IDENTIFIER':info['CFBundleIdentifier']+'.tunnel',
                'INFOPLIST_FILE':str(BUILD/'Tunnel-Info.plist'),'CODE_SIGN_ENTITLEMENTS':str(BUILD/'Tunnel.entitlements'),
                'APPLICATION_EXTENSION_API_ONLY':'YES'}}}
    spec=BUILD/'project.json';spec.write_text(json.dumps(project,indent=2))
    run('xcodegen','generate','--spec',spec)
    run('xcodebuild','-project',BUILD/'BitwigNativeHost.xcodeproj','-scheme','BitwigNativeHost','-configuration','Debug','-sdk','iphoneos','-destination','generic/platform=iOS','-derivedDataPath',BUILD/'DerivedData','-jobs','4','-allowProvisioningUpdates','build')
    print(BUILD/'DerivedData/Build/Products/Debug-iphoneos/BitwigNativeHost.app')
    raise SystemExit(0)
run(*CC,'-fobjc-arc','-DFULL_BITWIG_HOST',*[f'-I{path}' for path in jni_headers],'-framework','UIKit','-framework','Foundation','-framework','QuartzCore','-Wl,-rpath,@executable_path/Frameworks',ROOT/'probe/native-java.m','-o',APP/'BitwigNativeHost')
run('codesign','--force','--sign','-',APP)
if args.run:
    subprocess.run(['xcrun','simctl','terminate',simulator,info['CFBundleIdentifier']],capture_output=True)
    run('xcrun','simctl','install',simulator,APP)
    run('xcrun','simctl','launch',simulator,info['CFBundleIdentifier'])
