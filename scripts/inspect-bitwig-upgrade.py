#!/usr/bin/env python3
"""Compare local Bitwig ARM64 input interfaces without modifying either app."""
import argparse
import hashlib
import json
import plistlib
import re
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('baseline', type=Path)
parser.add_argument('candidate', type=Path)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()


def inspect(app):
    contents = app / 'Contents'
    info = plistlib.loads((contents / 'Info.plist').read_bytes())
    jni = contents / 'Frameworks/libbitwig-jni.jnilib'
    imports = subprocess.check_output(['xcrun', 'nm', '-arch', 'arm64', '-um', str(jni)], text=True)
    strings = subprocess.check_output(['strings', str(jni)], text=True).splitlines()
    touch = sorted({s for s in strings if len(s) < 160 and
                    ('touch' in s.lower() or 'gesture' in s.lower())})
    engine = contents / 'MacOS/Bitwig Audio Engine ARM64-NEON.app/Contents/MacOS/BitwigAudioEngine-ARM64-NEON'
    return {
        'version': info['CFBundleShortVersionString'],
        'jni_sha256': hashlib.sha256(jni.read_bytes()).hexdigest(),
        'engine_sha256': hashlib.sha256(engine.read_bytes()).hexdigest(),
        'imports': sorted(set(re.findall(r'external (\S+)', imports))),
        'touch_symbols': touch,
    }


baseline, candidate = inspect(args.baseline), inspect(args.candidate)
report = {
    'baseline': baseline,
    'candidate': candidate,
    'added_imports': sorted(set(candidate['imports']) - set(baseline['imports'])),
    'added_touch_symbols': sorted(set(candidate['touch_symbols']) - set(baseline['touch_symbols'])),
    'engine_changed': baseline['engine_sha256'] != candidate['engine_sha256'],
    'scope': 'Static interface comparison only; not a runtime or multitouch qualification.',
}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(report, indent=2) + '\n')
print(f"{baseline['version']} -> {candidate['version']}: "
      f"{len(report['added_imports'])} added imports, "
      f"{len(report['added_touch_symbols'])} added touch symbols; "
      f"engine changed: {report['engine_changed']}")
