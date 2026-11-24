#!/usr/bin/env python3
"""Send one development input command to an explicitly enabled native host."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('action',choices=['inspect','click','engine'])
parser.add_argument('--device-id',default=os.environ.get('BITWIG_DEVICE_ID'),help='Trusted iPad identifier, or BITWIG_DEVICE_ID')
parser.add_argument('--port',type=int,default=0)
parser.add_argument('--title',default='')
parser.add_argument('--x',type=float,default=0)
parser.add_argument('--y',type=float,default=0)
parser.add_argument('--count',type=int,choices=[1,2],default=1)
parser.add_argument('--hold',type=float,default=0.1)
args=parser.parse_args()
if not args.device_id: parser.error("Set --device-id or BITWIG_DEVICE_ID")
command=dict(vars(args),id=str(uuid.uuid4()))
source=root/'evidence/native-ui-command.json'
result_path=root/'evidence/device-native-ui-result.json'
source.write_text(json.dumps(command)+'\n')
base=['xcrun','devicectl','device','copy']
options=['--device',args.device_id,'--timeout','10',
         '--domain-type','appDataContainer','--domain-identifier','com.felixgodden.bitwigipad.nativehost']
# The host consumes the command immediately; devicectl can report a missing
# final file node after a successful upload. The matching acknowledgement is
# authoritative, and prevents resending an already executed click.
upload=subprocess.run(base+['to']+options+['--source',str(source),'--destination','Documents/native-ui-command.json'],capture_output=True)
deadline=time.monotonic()+15
while time.monotonic()<deadline:
    time.sleep(0.5)
    copied=subprocess.run(base+['from']+options+['--source','Documents/native-ui-result.json','--destination',str(result_path)],capture_output=True)
    if copied.returncode:continue
    result=json.loads(result_path.read_text())
    if result.get('id')!=command['id']:continue
    print(json.dumps(result,indent=2))
    raise SystemExit(0 if result.get('ok') else 1)
if upload.returncode:print(upload.stderr.decode(errors='replace'))
raise SystemExit('No matching response; host must be launched with --native-ui-automation')
