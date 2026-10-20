"""Build and run the offline native transition core. No game installation."""
from pathlib import Path
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parent
OUT = ROOT.parent / 'dist' / 'releases' / 'hob-native-transition-core'
OUT.mkdir(parents=True, exist_ok=True)
vcvars = Path(r'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat')
commands = [f'call "{vcvars}" >nul',
    f'cl /nologo /MT /EHsc /std:c++17 /O2 /W4 /WX /c "{ROOT / "transition_core.cpp"}" /Fo"{OUT / "transition_core.obj"}"',
    f'lib /nologo /OUT:"{OUT / "hob_transition_core.lib"}" "{OUT / "transition_core.obj"}"',
    f'cl /nologo /MT /EHsc /std:c++17 /O2 /W4 /WX "{ROOT / "fixture.cpp"}" "{OUT / "hob_transition_core.lib"}" /Fo"{OUT / "fixture.obj"}" /Fe"{OUT / "transition_fixture.exe"}"']
script = OUT / 'compile.cmd'
script.write_text('@echo off\n' + '\n'.join(c + '\nif errorlevel 1 exit /b %errorlevel%' for c in commands) + '\n')
subprocess.run(['cmd', '/d', '/c', str(script)], cwd=OUT, check=True)
result = subprocess.run([str(OUT / 'transition_fixture.exe')], cwd=OUT, check=True, capture_output=True, text=True, timeout=30)
receipt = {'artifact': 'offline static core only', 'runtime_adapter': 'unimplemented; not installable',
    'polling': False, 'threads_created_by_core': False, 'game_modified': False,
    'fixture': result.stdout.strip(), 'sha256': hashlib.sha256((OUT / 'hob_transition_core.lib').read_bytes()).hexdigest()}
(OUT / 'verification.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt, indent=2))
