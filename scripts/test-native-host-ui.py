#!/usr/bin/env python3
"""Exercise the observed Demo Mode button in the dedicated native simulator."""
import json
import os
import argparse
import subprocess
from datetime import datetime
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--continue-demo', action='store_true')
parser.add_argument('--fullscreen', action='store_true')
parser.add_argument('--capture', action='store_true')
parser.add_argument('--device', action='store_true')
parser.add_argument('--polysynth', action='store_true')
parser.add_argument('--resume-polysynth', action='store_true')
parser.add_argument('--tablet-profile', action='store_true')
parser.add_argument('--text-input', action='store_true')
parser.add_argument('--file-import', action='store_true')
parser.add_argument('--clear-text', action='store_true')
parser.add_argument('--window-drag', action='store_true')
parser.add_argument('--device-drag', action='store_true')
parser.add_argument('--cancel-drag', action='store_true')
args = parser.parse_args()
build = root / 'build/native-ui-test'
build.mkdir(parents=True, exist_ok=True)
spec = {
    'name': 'NativeHostUI',
    'targets': {'NativeHostUITests': {
        'type': 'bundle.ui-testing', 'platform': 'iOS', 'deploymentTarget': '26.0',
        'sources': [{'path': str(root / 'native/NativeHostUITests.swift')}],
        'settings': {'base': {
            'PRODUCT_BUNDLE_IDENTIFIER': 'org.example.bitwigipad.uitests',
            'GENERATE_INFOPLIST_FILE': 'YES', 'SWIFT_VERSION': '5.0',
            'TARGETED_DEVICE_FAMILY': '2',
            'CODE_SIGNING_ALLOWED': 'YES' if args.device else 'NO',
            'DEVELOPMENT_TEAM': 'YOUR_TEAM_ID', 'CODE_SIGN_STYLE': 'Automatic'
        }}
    }},
    'schemes': {'NativeHostUI': {
        'build': {'targets': {'NativeHostUITests': 'all'}},
        'test': {'targets': ['NativeHostUITests']}
    }}
}
(build / 'project.json').write_text(json.dumps(spec, indent=2))
subprocess.run(['xcodegen', 'generate', '--spec', str(build / 'project.json')], check=True)
subprocess.run(['xcodebuild', '-project', str(build / 'NativeHostUI.xcodeproj'),
                '-scheme', 'NativeHostUI', '-destination',
                (f"platform=iOS,id={os.environ['BITWIG_DEVICE_ID']}" if args.device else
                 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID'),
                '-derivedDataPath', str(build / 'DerivedData'), '-jobs', '4',
                '-allowProvisioningUpdates',
                '-only-testing:NativeHostUITests/NativeHostUITests/' +
                ('testFullScreenRotation' if args.fullscreen else
                 'testCancelNativeDeviceDrag' if args.cancel_drag else
                 'testDragNativeDevice' if args.device_drag else
                 'testDragWelcomeWindow' if args.window_drag else
                 'testClearNativeText' if args.clear_text else
                 'testNativeFileImport' if args.file_import else
                 'testNativeTextInput' if args.text_input else
                 'testChooseTabletProfile' if args.tablet_profile else
                 'testResumeNativePolySynth' if args.resume_polysynth else
                 'testPlayNativePolySynth' if args.polysynth else
                 'testCaptureNativeHost' if args.capture else
                 'testContinueDemoMode' if args.continue_demo else 'testEnterDemoMode'),
                '-resultBundlePath', str(root / 'evidence' / (
                    ('device-ui-test-' if args.device else 'native-ui-test-') +
                    datetime.now().strftime('%Y%m%d-%H%M%S') + '.xcresult')),
                'test'], check=True)
