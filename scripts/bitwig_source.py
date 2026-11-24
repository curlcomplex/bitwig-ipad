"""Resolve one local Bitwig installation and its associated build outputs."""
import hashlib
import os
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_APP = Path('/Applications/Bitwig Studio 6.1.4.app')
ENGINE = Path('MacOS/Bitwig Audio Engine ARM64-NEON.app/Contents/MacOS/BitwigAudioEngine-ARM64-NEON')
JNI = Path('Frameworks/libbitwig-jni.jnilib')


def sha256(path):
    with path.open('rb') as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
        return digest.hexdigest()


class BitwigSource:
    def __init__(self, parser):
        parser.add_argument('--bitwig-app', type=Path, default=Path(os.getenv('BITWIG_APP', str(DEFAULT_APP))),
                            help='Local Bitwig Studio .app (defaults to BITWIG_APP or installed 6.1.4)')
        self.args = parser.parse_args()
        self.contents = self.args.bitwig_app.expanduser().resolve() / 'Contents'
        try:
            version = plistlib.loads((self.contents / 'Info.plist').read_bytes())['CFBundleShortVersionString']
        except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
            parser.error(f'Cannot read Bitwig installation at {self.contents.parent}: {error}')
        if version not in ('6.1.4', '6.1.7'):
            parser.error(f'Expected Bitwig 6.1.4 or 6.1.7, found {version}')
        path_key = hashlib.sha256(os.fsencode(self.contents)).hexdigest()[:16]
        self.build = ROOT / 'build' / version / path_key
        self.evidence = ROOT / 'evidence' / version / path_key
        self.evidence.mkdir(parents=True, exist_ok=True)
        self.version = version

    def identity(self, relative):
        path = self.contents / relative
        return {'path': str(path), 'sha256': sha256(path)}


def java_probe_info():
    return dict(
        CFBundleIdentifier='com.felixgodden.bitwigipad.javaprobe',
        CFBundleExecutable='BitwigJavaProbe', CFBundleName='Bitwig Java Probe',
        CFBundlePackageType='APPL', CFBundleVersion='1', CFBundleShortVersionString='0.1',
        MinimumOSVersion='17.0', UIDeviceFamily=[2], UILaunchScreen={},
        UIApplicationSceneManifest={
            'UIApplicationSupportsMultipleScenes': False,
            'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [
                {'UISceneConfigurationName': 'Probe', 'UISceneDelegateClassName': 'JavaProbeScene'}
            ]},
        },
    )
