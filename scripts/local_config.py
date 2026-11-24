"""Resolve build identities and tools from the invoking developer's environment."""
from dataclasses import dataclass
import os
from pathlib import Path
import re
import subprocess

SIMULATOR_PREFIX = 'org.bitwigipad.prototype'
SIMULATOR_IPC_GROUP = 'group.bw.test'


@dataclass(frozen=True)
class BuildIdentity:
    prefix: str
    team: str | None
    app_group: str | None
    ipc_group: str | None

    def bundle(self, target):
        return f'{self.prefix}.{target}'

    def group_info(self):
        return {key: value for key, value in
                [('BWAppGroupIdentifier', self.app_group), ('BWIPCGroupIdentifier', self.ipc_group)]
                if value}

    def group_entitlements(self):
        groups = list(dict.fromkeys(group for group in (self.app_group, self.ipc_group) if group))
        return {'com.apple.security.application-groups': groups} if groups else {}


def bundle_prefix(parser, explicit=False):
    prefix = os.getenv('BITWIG_BUNDLE_PREFIX')
    if explicit and not prefix:
        parser.error('Device operations require BITWIG_BUNDLE_PREFIX')
    prefix = prefix or SIMULATOR_PREFIX
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', prefix):
        parser.error('BITWIG_BUNDLE_PREFIX must be a reverse-DNS bundle identifier prefix')
    return prefix


def build_identity(parser, device=False, shared_engine=False):
    prefix = bundle_prefix(parser, explicit=device)
    team = os.getenv('BITWIG_DEVELOPMENT_TEAM')
    app_group = os.getenv('BITWIG_APP_GROUP')
    ipc_group = os.getenv('BITWIG_IPC_GROUP')
    if device and not (team and re.fullmatch(r'[A-Z0-9]{10}', team)):
        parser.error('Device builds require a valid BITWIG_DEVELOPMENT_TEAM')
    if shared_engine and not (app_group and ipc_group):
        parser.error('The embedded engine requires BITWIG_APP_GROUP and BITWIG_IPC_GROUP')
    if bool(app_group) != bool(ipc_group):
        parser.error('Set both BITWIG_APP_GROUP and BITWIG_IPC_GROUP for shared engine builds')
    for name, group in [('BITWIG_APP_GROUP', app_group), ('BITWIG_IPC_GROUP', ipc_group)]:
        if group and not re.fullmatch(r'group\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*', group):
            parser.error(f'{name} must be a registered group identifier beginning with group.')
    # Darwin reserves 31 characters for the name. The slash and 16-character
    # digest leave 14 for the complete App Group identifier.
    if ipc_group and len(ipc_group) > 14:
        parser.error('BITWIG_IPC_GROUP must be at most 14 ASCII characters including group.')
    if not device and not app_group:
        app_group, ipc_group = f'group.{prefix}', SIMULATOR_IPC_GROUP
    return BuildIdentity(prefix, team, app_group, ipc_group)


def jni_include_paths(parser):
    location = os.getenv('BITWIG_JDK_HOME') or os.getenv('JAVA_HOME')
    if not location:
        java_home = subprocess.run(['/usr/libexec/java_home'], capture_output=True, text=True)
        if java_home.returncode == 0:
            location = java_home.stdout.strip()
    if not location:
        parser.error('Set BITWIG_JDK_HOME or JAVA_HOME to a local JDK')
    include = Path(location).expanduser() / 'include'
    if not (include / 'jni.h').is_file():
        parser.error('The selected JDK has no include/jni.h')
    return [str(path) for path in (include, include / 'darwin') if path.is_dir()]


def simulator_argument(parser):
    parser.add_argument('--simulator', default=os.getenv('BITWIG_SIMULATOR_ID'),
                        help='Local iPad Simulator identifier, or BITWIG_SIMULATOR_ID')


def selected_simulator(parser, value):
    if value:
        return value
    parser.error('Select a Simulator with --simulator or BITWIG_SIMULATOR_ID')
