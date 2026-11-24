"""Bounded fixture for JVM classfiles and JNI name matching."""
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from compat_discovery import jni_escape, match_bindings, native_declarations


def utf(raw):
    return struct.pack('>BH', 1, len(raw)) + raw


owner = b'demo/C\xed\xa0\xbd\xed\xb8\x80'
pool = utf(owner) + b'\x07\x00\x01' + utf(b'native_call') + utf(b'([Ljava/lang/String;)V')
data = (b'\xca\xfe\xba\xbe\x00\x00\x00\x41\x00\x05' + pool
        + struct.pack('>11H', 1, 2, 0, 0, 0, 1, 0x0108, 3, 4, 0, 0))
[(class_name, method, descriptor, is_static)] = native_declarations(data)
assert is_static and descriptor == '([Ljava/lang/String;)V'
assert jni_escape(class_name) == 'demo_C_0d83d_0de00'
assert jni_escape(method) == 'native_1call'
row = {'class': class_name, 'method': method, 'descriptor': descriptor}
export = 'Java_demo_C_0d83d_0de00_native_1call___3Ljava_lang_String_2'
match_bindings([row], {export: {'fixture.jnilib'}})
assert row['status'] == 'export_name_match_runtime_unverified'
assert row['candidate_exports'] == [{'name': export, 'images': ['fixture.jnilib']}]
print('Java native declaration and JNI escaping fixture passed')
