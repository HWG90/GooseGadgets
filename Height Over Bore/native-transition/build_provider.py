"""Build native bindings and run separate-process interception tests. Never installs."""
from pathlib import Path
import ctypes
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parent
OUT = ROOT.parent / 'dist' / 'releases' / 'hob-native-transition-offline'
OUT.mkdir(parents=True, exist_ok=True)
def source_hashes():
    sources=sorted(p for p in ROOT.rglob('*') if p.is_file() and p.suffix in {'.cpp','.h','.c'})
    sources.append(ROOT/'build_provider.py')
    return {p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
source_before=source_hashes()
(OUT/'verification.json').write_text(json.dumps({'state':'unverified until build and fixtures finish','installed':False})+'\n')
vcvars = Path(r'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat')
vendor = ROOT / 'vendor' / 'minhook'
commands = [f'call "{vcvars}" >nul']
objects = []
for source in ['buffer.c', 'hook.c', 'trampoline.c', 'hde/hde64.c']:
    obj = OUT / (Path(source).stem + '.obj')
    objects.append(obj)
    commands.append(f'cl /nologo /c /MT /O2 /W3 /TC "{vendor / "src" / source}" /Fo"{obj}"')
for source in ['transition_core.cpp', 'game_binding.cpp', 'commit_stub.cpp', 'hob_consumer.cpp']:
    obj = OUT / (Path(source).stem + '.obj')
    objects.append(obj)
    commands.append(f'cl /nologo /c /MT /EHsc /std:c++17 /O2 /W4 /WX "{ROOT / source}" /Fo"{obj}"')
production = OUT / 'hob_transition_provider_0_1.dll'
test_library = OUT / 'hob_transition_fixture_only.dll'
review_library = OUT / 'hob_transition_live_review.dll'
for fixture, library, define in [(False, production, ''), (True, test_library, '/DHBTP_FIXTURE'), (False, review_library, '/DHBTP_LIVE_REVIEW')]:
    obj = OUT / ('provider_fixture_binding.obj' if fixture else 'provider_review.obj' if library==review_library else 'provider.obj')
    commands.append(f'cl /nologo /c /MT /EHsc /std:c++17 /O2 /W4 /WX {define} "{ROOT / "provider.cpp"}" /Fo"{obj}"')
    inputs = ' '.join(f'"{p}"' for p in objects + [obj])
    commands.append(f'link /nologo /DLL /DYNAMICBASE /NXCOMPAT /Brepro /OUT:"{library}" {inputs} kernel32.lib bcrypt.lib')
fixture_exe = OUT / 'provider_fixture.exe'
commands.append(f'cl /nologo /MT /EHsc /std:c++17 /O2 /W4 /WX "{ROOT / "provider_fixture.cpp"}" /Fo"{OUT / "provider_fixture.obj"}" /Fe"{fixture_exe}"')
integration_exe = OUT / 'integration_fixture.exe'
commands.append(f'cl /nologo /MT /EHsc /std:c++17 /O2 /W4 /WX "{ROOT / "integration_fixture.cpp"}" /Fo"{OUT / "integration_fixture.obj"}" /Fe"{integration_exe}"')
script = OUT / 'compile-provider.cmd'
script.write_text('@echo off\n' + '\n'.join(c + '\nif errorlevel 1 exit /b %errorlevel%' for c in commands) + '\n')
subprocess.run(['cmd','/d','/c',str(script)],cwd=OUT,check=True)
results = []
for case in ['baseline','bootstrap','idle','thread','partial','nested','foreign','restorefail','worldchange','reject','commits','commit_fault','commit_body','commit_restorefail','lifecycle_entries']:
    run = subprocess.run([str(fixture_exe), str(test_library), case],cwd=OUT,
                         capture_output=True,text=True,timeout=30)
    if run.returncode:raise RuntimeError(f'{case}: '+run.stdout+run.stderr)
    results.append(run.stdout.strip())
run=subprocess.run([str(integration_exe),str(test_library)],cwd=OUT,capture_output=True,text=True,timeout=30)
if run.returncode:raise RuntimeError('integrated consumer: '+run.stdout+run.stderr)
results.append(run.stdout.strip())
# The real library must reject non-game environments and omit fixture injection.
dll = ctypes.WinDLL(str(production))
assert not hasattr(dll,'HBTP_TestOpen'), 'fixture API leaked into production DLL'
dll.HBTP_Open.argtypes=[ctypes.c_void_p,ctypes.c_void_p]
dll.HBTP_Open.restype=ctypes.c_uint32
assert dll.HBTP_Open(None,None)==0
assert dll.HBTP_OpenHoB(1)==0
assert dll.HBTP_SetEnabled(1)==0
assert dll.HBTP_BuildMode()==0
review=ctypes.WinDLL(str(review_library))
assert not hasattr(review,'HBTP_TestOpen')
assert review.HBTP_BuildMode()==1
assert review.HBTP_OpenHoB(0)==0
assert review.HBTP_SetEnabled(1)==0

assert source_hashes()==source_before, 'Sources changed during compilation or verification; rebuild required'
receipt = {'artifact':str(production),'sha256':hashlib.sha256(production.read_bytes()).hexdigest(),
    'mechanism':'native queue STORE callbacks and transition/lifecycle entry interception; legacy slot mode retained only for fixtures',
    'idle_polling':False,'threads_created_by_provider':False,'fixture_results':results,
    'non_game_admission':'rejected','fixture_exports_in_production':False,
    'installed':False,'live_game_coverage':'not verified',
    'production_activation':'closed: native consumer and full integration remain unverified',
    'publication':'not authorized; experimental offline artifact only',
    'review_artifact':str(review_library),'review_sha256':hashlib.sha256(review_library.read_bytes()).hexdigest(),
    'review_admission':'guarded; non-game rejection verified; never installed by builder',
    'source_sha256':source_before}
(OUT / 'verification.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({key:receipt[key] for key in ['artifact','sha256','fixture_results','installed','production_activation']},indent=2))
