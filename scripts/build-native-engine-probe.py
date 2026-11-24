#!/usr/bin/env python3
"""Adapt a COPY of the real ARM64 audio engine for an isolated iOS loader check."""
import argparse, json, plistlib, re, shutil, struct, subprocess
from pathlib import Path

root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--device',action='store_true');args=parser.parse_args()
build=root/('build/native-engine-probe-device' if args.device else 'build/native-engine-probe')
app=build/'BitwigEngineProbe.app'
frameworks=app/'Frameworks';frameworks.mkdir(parents=True,exist_ok=True)
source=Path('/Applications/Bitwig Studio 6.1.4.app/Contents/MacOS/Bitwig Audio Engine ARM64-NEON.app/Contents/MacOS/BitwigAudioEngine-ARM64-NEON')
def run(*args):subprocess.run(list(map(str,args)),check=True)
sdk_name='iphoneos' if args.device else 'iphonesimulator'
target='arm64-apple-ios17.0'+('' if args.device else '-simulator')
sdk=Path(subprocess.check_output(['xcrun','--sdk',sdk_name,'--show-sdk-path'],text=True).strip())
audio_bridge=frameworks/'libAudioUnitBridge.dylib'
run('xcrun','--sdk',sdk_name,'clang','-target',target,'-isysroot',sdk,'-fobjc-arc','-dynamiclib',root/'native/compat/AudioHAL.m',root/'native/compat/AudioOutputProxy.m','-framework','Foundation','-framework','AVFAudio','-Wl,-reexport_framework,CoreAudio','-Wl,-reexport_framework,AudioToolbox','-install_name','@rpath/libAudioHALBridge.dylib','-o',frameworks/'libAudioHALBridge.dylib')
run('xcrun','--sdk',sdk_name,'clang','-target',target,'-isysroot',sdk,'-fobjc-arc','-dynamiclib',root/'native/compat/Posix.m',root/'native/compat/EngineJIT.m','-framework','Foundation','-Wl,-reexport-lSystem','-install_name','@rpath/libPosixBridge.dylib','-o',frameworks/'libPosixBridge.dylib')
for bridge_name in ['libAudioUnitBridge.dylib','libAudioToolboxBridge.dylib']:
    run('xcrun','--sdk',sdk_name,'clang','-target',target,'-isysroot',sdk,'-dynamiclib',root/'native/compat/Forward.c',f'-Wl,-reexport_library,{frameworks / "libAudioHALBridge.dylib"}','-Wl,-rpath,@loader_path','-install_name','@rpath/'+bridge_name,'-o',frameworks/bridge_name)
raw=bytearray(source.read_bytes())
assert struct.unpack_from('<I',raw)[0]==0xfeedfacf,'Expected thin ARM64 Mach-O'
ncmds=struct.unpack_from('<I',raw,16)[0];offset=32;commands=[];entry=None
for _ in range(ncmds):
    cmd,size=struct.unpack_from('<II',raw,offset);item=bytearray(raw[offset:offset+size]);offset+=size
    if cmd==0x80000028:entry=struct.unpack_from('<Q',item,8)[0];continue # LC_MAIN, called explicitly later.
    if cmd==0xe:continue # LC_LOAD_DYLINKER is specific to process executables.
    if cmd==0x19 and item[8:24].rstrip(b'\0')==b'__PAGEZERO':
        # Keep the segment index for chained fixups, without reserving 4 GiB.
        struct.pack_into('<Q',item,32,0)
    commands.append(item)
assert entry is not None
(app/'engine-entry.json').write_text(json.dumps({'entry_offset':entry})+'\n')
packed=b''.join(commands)
struct.pack_into('<I',raw,12,8) # MH_BUNDLE: loadable image without an automatic main.
struct.pack_into('<II',raw,16,len(commands),len(packed))
flags=struct.unpack_from('<I',raw,24)[0];struct.pack_into('<I',raw,24,flags&~0x200000)
raw[32:offset]=packed+b'\0'*(offset-32-len(packed))
intermediate=build/'engine-bundle.macho';intermediate.write_bytes(raw)
engine=frameworks/'BitwigAudioEngine.bundle'
run('xcrun','vtool','-set-build-version','ios' if args.device else 'iossim','17.0','27.2','-replace','-output',engine,intermediate)
mapping={}
for line in subprocess.check_output(['xcrun','otool','-L',str(engine)],text=True).splitlines()[1:]:
    old=line.strip().split(' (compatibility')[0];match=re.search(r'/([^/]+)\.framework/',old)
    if old=='/usr/lib/libSystem.B.dylib':
        run('xcrun','install_name_tool','-change',old,'@rpath/libPosixBridge.dylib',engine);mapping[old]='@rpath/libPosixBridge.dylib'
    if not match:continue
    fw=match[1];new=old
    if fw in ['AppKit','Cocoa','Carbon','CoreServices','CoreGraphics','CoreVideo']:
        new=f'@rpath/lib{fw}Bridge.dylib'
    elif fw=='AudioUnit':new='@rpath/libAudioUnitBridge.dylib' # Preserve dependency ordinal.
    elif fw=='CoreAudio':new='@rpath/libAudioHALBridge.dylib'
    elif fw=='AudioToolbox':new='@rpath/libAudioToolboxBridge.dylib'
    else:
        tbd=sdk/'System/Library/Frameworks'/f'{fw}.framework'/f'{fw}.tbd'
        if tbd.exists():
            name=re.search(r"^install-name:\s*['\"]?([^'\"\n]+)",tbd.read_text(),re.M)
            if name:new=name[1].strip()
    if new!=old:run('xcrun','install_name_tool','-change',old,new,engine);mapping[old]=new
run('xcrun','install_name_tool','-add_rpath','@loader_path',engine)
cc=['xcrun','--sdk',sdk_name,'clang','-target',target,'-isysroot',sdk]
compat=frameworks/'libBitwigUIKit.dylib'
system_frameworks=['UIKit','Foundation','CoreFoundation','CoreGraphics','QuartzCore','CoreServices','CoreVideo','GameController','Metal','UniformTypeIdentifiers']
run(*cc,'-fno-objc-arc','-c',root/'native/compat/Metal.m','-o',build/'Metal.o')
run(*cc,'-fobjc-arc','-dynamiclib',root/'native/compat/AppKit.m',root/'native/compat/DesktopServices.m',build/'Metal.o',*[v for fw in system_frameworks for v in ['-framework',fw]],*[f'-Wl,-reexport_framework,{fw}' for fw in system_frameworks],'-install_name','@rpath/libBitwigUIKit.dylib','-o',compat)
for fw in ['AppKit','Cocoa','Carbon','CoreServices','CoreGraphics','CoreVideo']:
    bridge=frameworks/f'lib{fw}Bridge.dylib'
    run(*cc,'-dynamiclib',root/'native/compat/Forward.c',f'-Wl,-reexport_library,{compat}','-Wl,-rpath,@loader_path','-install_name',f'@rpath/{bridge.name}','-o',bridge)
info={'CFBundleIdentifier':'com.felixgodden.bitwigipad.engineprobe','CFBundleExecutable':'BitwigEngineProbe','CFBundleName':'Bitwig Engine Probe','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'0.1','MinimumOSVersion':'17.0','UIDeviceFamily':[2],'UILaunchScreen':{},'UIApplicationSceneManifest':{'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'Probe','UISceneDelegateClassName':'EngineProbeScene'}]}}}
(app/'Info.plist').write_bytes(plistlib.dumps(info))
evidence='native-engine-device-adaptation.json' if args.device else 'native-engine-adaptation.json'
(root/'evidence'/evidence).write_text(json.dumps({'original':str(source),'entry_offset':entry,'bundle':str(engine),'dependency_mappings':mapping,'scope':'Loader check; original code unchanged, original file untouched'},indent=2)+'\n')
if args.device:
    project={'name':'BitwigEngineProbe','targets':{'BitwigEngineProbe':{
        'type':'application','platform':'iOS','deploymentTarget':'17.0',
        'sources':[{'path':str(root/'probe/native-engine.m')},{'path':str(frameworks),'type':'folder','buildPhase':'resources'},{'path':str(app/'engine-entry.json'),'buildPhase':'resources'}],
        'settings':{'base':{'PRODUCT_BUNDLE_IDENTIFIER':info['CFBundleIdentifier'],'DEVELOPMENT_TEAM':'7L4A5VNHW2','CODE_SIGN_STYLE':'Automatic','INFOPLIST_FILE':str(app/'Info.plist'),'CLANG_ENABLE_OBJC_ARC':'YES','TARGETED_DEVICE_FAMILY':'2','ENABLE_DEBUG_DYLIB':'NO','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks'}},
        'postBuildScripts':[{'name':'Sign adapted engine libraries','script':'for lib in "$TARGET_BUILD_DIR/$WRAPPER_NAME/Frameworks/"*; do\n  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$lib" || exit $?\ndone','basedOnDependencyAnalysis':False}]
    }}}
    spec=build/'project.json';spec.write_text(json.dumps(project,indent=2))
    run('xcodegen','generate','--spec',spec)
    run('xcodebuild','-project',build/'BitwigEngineProbe.xcodeproj','-scheme','BitwigEngineProbe','-configuration','Debug','-sdk','iphoneos','-destination','generic/platform=iOS','-derivedDataPath',build/'DerivedData','-jobs','4','-allowProvisioningUpdates','build')
    print(build/'DerivedData/Build/Products/Debug-iphoneos/BitwigEngineProbe.app')
    raise SystemExit(0)
run('xcrun','--sdk','iphonesimulator','clang','-target','arm64-apple-ios17.0-simulator','-isysroot',sdk,'-fobjc-arc','-framework','UIKit','-framework','Foundation','-Wl,-rpath,@executable_path/Frameworks',root/'probe/native-engine.m','-o',app/'BitwigEngineProbe')
for path in frameworks.iterdir():run('codesign','--force','--sign','-',path)
run('codesign','--force','--sign','-',app)
print(app)
