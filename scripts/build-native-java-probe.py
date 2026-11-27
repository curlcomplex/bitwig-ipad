#!/usr/bin/env python3
"""Build/run Amethyst's iOS Java 25 runtime in the isolated iPad simulator."""
import argparse
import plistlib
import shutil
import subprocess
from pathlib import Path
from bitwig_source import BitwigSource, ROOT, java_probe_info

from local_config import build_identity, jni_include_paths, selected_simulator, simulator_argument

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--run', action='store_true', help='Install and launch the built Simulator probe')
simulator_argument(parser)
bitwig = BitwigSource(parser)
simulator = selected_simulator(parser, bitwig.args.simulator) if bitwig.args.run else None
identity = build_identity(parser)
jni_headers = jni_include_paths(parser)
APP = bitwig.build / 'native-java/BitwigJavaProbe.app'
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
    shutil.copy2((bitwig.contents / 'Java')/name,APP/name)
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
run('xcrun','--sdk','iphonesimulator','clang','-target','arm64-apple-ios17.0-simulator','-isysroot',sdk,'-fobjc-arc','-g',*[f'-I{path}' for path in jni_headers],'-framework','UIKit','-framework','Foundation',ROOT/'probe/native-java.m','-o',APP/'BitwigJavaProbe')
info = java_probe_info(identity)
(APP/'Info.plist').write_bytes(plistlib.dumps(info))
run('codesign','--force','--sign','-',APP)
print(APP)
if simulator:
    subprocess.run(['xcrun','simctl','terminate',simulator,info['CFBundleIdentifier']],capture_output=True)
    run('xcrun','simctl','install',simulator,APP)
    run('xcrun','simctl','launch',simulator,info['CFBundleIdentifier'])
