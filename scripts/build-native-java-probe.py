#!/usr/bin/env python3
"""Build/run Amethyst's iOS Java 25 runtime in the isolated iPad simulator."""
import json
import plistlib
import shutil
import subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
APP=ROOT/'build/native-java/BitwigJavaProbe.app'
APP.mkdir(parents=True,exist_ok=True)
source=ROOT/'vendor/java25-ios'
runtime=APP/'jre'
runtime.mkdir(exist_ok=True)
for name in ['lib','conf']:
    shutil.copytree(source/name,runtime/name,dirs_exist_ok=True)
shutil.copy2(source/'release',runtime/'release')
def run(*args): subprocess.run(list(map(str,args)),check=True)
for path in runtime.rglob('*'):
    if not path.is_file(): continue
    with path.open('rb') as f: magic=f.read(4)
    if magic == b'\xcf\xfa\xed\xfe':
        run('xcrun','vtool','-set-build-version','iossim','17.0','27.2','-replace','-output',path,path)
        run('codesign','--force','--sign','-',path)
for name in ['bitwig.jar','libs.jar']:
    shutil.copy2(Path('/Applications/Bitwig Studio 6.1.4.app/Contents/Java')/name,APP/name)
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
run('xcrun','--sdk','iphonesimulator','clang','-target','arm64-apple-ios17.0-simulator','-isysroot',sdk,'-fobjc-arc','-g','-I/opt/homebrew/opt/openjdk/include','-framework','UIKit','-framework','Foundation',ROOT/'probe/native-java.m','-o',APP/'BitwigJavaProbe')
info={'CFBundleIdentifier':'com.felixgodden.bitwigipad.javaprobe','CFBundleExecutable':'BitwigJavaProbe','CFBundleName':'Bitwig Java Probe','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'0.1','MinimumOSVersion':'17.0','UIDeviceFamily':[2],'UILaunchScreen':{},'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'Probe','UISceneDelegateClassName':'JavaProbeScene'}]}}}
(APP/'Info.plist').write_bytes(plistlib.dumps(info))
run('codesign','--force','--sign','-',APP)
udid=json.loads((ROOT/'evidence/simulator.json').read_text())['udid']
run('xcrun','simctl','install',udid,APP)
subprocess.run(['xcrun','simctl','terminate',udid,info['CFBundleIdentifier']],capture_output=True)
run('xcrun','simctl','launch',udid,info['CFBundleIdentifier'])
