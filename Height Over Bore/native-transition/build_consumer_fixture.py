"""Compile and verify the real native HoB consumer against private memory layouts."""
from pathlib import Path
import hashlib
import json
import subprocess
ROOT=Path(__file__).resolve().parent
OUT=ROOT.parent/'dist'/'releases'/'hob-native-consumer-fixture'
OUT.mkdir(parents=True,exist_ok=True)
names=['hob_consumer.cpp','hob_consumer.h','game_binding.cpp','game_binding.h','queue_profile.h','consumer_fixture.cpp','consumer_model.h']
before={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in names}
vcvars=Path(r'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat')
commands=[f'call "{vcvars}" >nul',f'cl /nologo /MT /EHsc /std:c++17 /O2 /W4 /WX "{ROOT/"hob_consumer.cpp"}" "{ROOT/"game_binding.cpp"}" "{ROOT/"consumer_fixture.cpp"}" bcrypt.lib /Fe"{OUT/"consumer_fixture.exe"}"']
script=OUT/'compile.cmd'
script.write_text('@echo off\n'+'\n'.join(c+'\nif errorlevel 1 exit /b %errorlevel%' for c in commands)+'\n')
subprocess.run(['cmd','/d','/c',str(script)],cwd=OUT,check=True)
run=subprocess.run([str(OUT/'consumer_fixture.exe')],cwd=OUT,capture_output=True,text=True,timeout=30)
if run.returncode:raise RuntimeError(run.stdout+run.stderr)
assert before=={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in names}
receipt={'fixture':run.stdout.strip(),'source_sha256':before,'game_modified':False,'installed':False}
(OUT/'verification.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({k:receipt[k] for k in ['fixture','game_modified','installed']},indent=2))
