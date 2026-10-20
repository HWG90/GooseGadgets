"""Verify native write-branch callbacks and Windows unwind metadata offline."""
from pathlib import Path
import json
import subprocess
ROOT=Path(__file__).resolve().parent
OUT=ROOT.parent/'dist'/'releases'/'hob-native-transition-commit-fixture'
OUT.mkdir(parents=True,exist_ok=True)
vcvars=Path(r'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat')
script=OUT/'compile.cmd'
commands=[f'call "{vcvars}" >nul']
objects=[]
for name in ['buffer.c','hook.c','trampoline.c','hde/hde64.c']:
    obj=OUT/(Path(name).stem+'.obj');objects.append(obj)
    commands.append(f'cl /nologo /c /MT /O2 /W3 /TC "{ROOT/"vendor"/"minhook"/"src"/name}" /Fo"{obj}"')
inputs=' '.join(f'"{p}"' for p in objects)
commands.append(f'cl /nologo /MT /EHsc /std:c++17 /O2 /W4 /WX "{ROOT/"commit_stub.cpp"}" "{ROOT/"commit_fixture.cpp"}" {inputs} /Fe"{OUT/"commit_fixture.exe"}"')
script.write_text('@echo off\n'+'\n'.join(c+'\nif errorlevel 1 exit /b %errorlevel%' for c in commands)+'\n')
subprocess.run(['cmd','/d','/c',str(script)],cwd=OUT,check=True)
result=subprocess.run([str(OUT/'commit_fixture.exe')],cwd=OUT,capture_output=True,text=True,timeout=30)
if result.returncode:
    raise RuntimeError(result.stdout+result.stderr)
receipt={'fixture':result.stdout.strip(),'game_modified':False,'live_verified':False}
(OUT/'verification.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt,indent=2))
