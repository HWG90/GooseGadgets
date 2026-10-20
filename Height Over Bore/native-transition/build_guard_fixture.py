"""Verify production source admission on a non-executable saved image, offline."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
ROOT=Path(__file__).resolve().parent
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('image',type=Path)
args=parser.parse_args()
digest=hashlib.sha256(args.image.read_bytes()).hexdigest()
assert digest=='642b0aac0b4f577054993a965054827455ef143ced9895b2dfd09d1ecd433a37'
OUT=ROOT.parent/'dist'/'releases'/'hob-native-transition-guard-fixture'
OUT.mkdir(parents=True,exist_ok=True)
vcvars=Path(r'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat')
commands=[f'call "{vcvars}" >nul',
    f'cl /nologo /MT /EHsc /std:c++17 /O2 /W4 /WX "{ROOT/"game_binding.cpp"}" "{ROOT/"guard_fixture.cpp"}" bcrypt.lib /Fe"{OUT/"guard_fixture.exe"}"']
script=OUT/'compile.cmd'
script.write_text('@echo off\n'+'\n'.join(c+'\nif errorlevel 1 exit /b %errorlevel%' for c in commands)+'\n')
subprocess.run(['cmd','/d','/c',str(script)],cwd=OUT,check=True)
result=subprocess.run([str(OUT/'guard_fixture.exe'),str(args.image)],cwd=OUT,capture_output=True,text=True,timeout=30)
if result.returncode:raise RuntimeError(result.stdout+result.stderr)
receipt={'fixture':result.stdout.strip(),'image_sha256':digest,
    'game_image_executed':False,'installed':False,
    'source_sha256':{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest()
        for name in ['game_binding.cpp','game_binding.h','queue_profile.h']}}
(OUT/'verification.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt,indent=2))
