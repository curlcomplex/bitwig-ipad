"""Check the neutral and explicit device build profiles without signing."""
import argparse
import contextlib
import io
import os
from pathlib import Path
import sys
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from local_config import build_identity, bundle_prefix


def rejects(environment, function):
    with patch.dict(os.environ, environment, clear=True), contextlib.redirect_stderr(io.StringIO()):
        try:
            function()
        except SystemExit as error:
            assert error.code == 2
        else:
            raise AssertionError('Invalid configuration was accepted')


parser = argparse.ArgumentParser()
with patch.dict(os.environ, {}, clear=True):
    simulator = build_identity(parser)
    assert simulator.bundle('nativehost') == 'org.bitwigipad.prototype.nativehost'
    assert simulator.team is None
rejects({}, lambda: bundle_prefix(parser, explicit=True))
rejects({}, lambda: build_identity(parser, device=True))
device_environment = {
    'BITWIG_BUNDLE_PREFIX': 'org.example.prototype',
    'BITWIG_DEVELOPMENT_TEAM': 'ABCD123456',
    'BITWIG_APP_GROUP': 'group.org.example.prototype',
    'BITWIG_IPC_GROUP': 'group.ex.bw',
}
with patch.dict(os.environ, device_environment, clear=True):
    device = build_identity(parser, device=True, shared_engine=True)
    host = device.bundle('nativehost')
    assert [host + suffix for suffix in ('.engine', '.tunnel', '.jithelper')] == [
        'org.example.prototype.nativehost.engine', 'org.example.prototype.nativehost.tunnel',
        'org.example.prototype.nativehost.jithelper',
    ]
    assert device.group_info() == {
        'BWAppGroupIdentifier': device.app_group, 'BWIPCGroupIdentifier': device.ipc_group,
    }
    assert device.group_entitlements()['com.apple.security.application-groups'] == [
        device.app_group, device.ipc_group,
    ]
rejects({**device_environment, 'BITWIG_IPC_GROUP': 'group.identifier.too.long'},
        lambda: build_identity(parser, device=True, shared_engine=True))
rejects({**device_environment, 'BITWIG_APP_GROUP': ''},
        lambda: build_identity(parser, device=True, shared_engine=True))
print('Local build identity validation passed')
