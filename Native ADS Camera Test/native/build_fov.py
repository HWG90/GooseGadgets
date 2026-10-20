"""Build the independent hip FOV policy and its synthetic native fixture."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parent
MOD=ROOT.parent
LIBRARY='native_ads_fov_0_1_23.dll'

def build(output=None,fixtures=True):
    output=Path(output or MOD/'dist'/'native').resolve();output.mkdir(parents=True,exist_ok=True)
    vcvars=Path(r'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat')
    if not vcvars.is_file():raise RuntimeError('MSVC x64 build environment unavailable')
    obj=output/'native_ads_fov_0_1_23.obj'
    commands=[f'cl /nologo /c /MT /EHsc /std:c++17 /O2 /W4 /WX "{ROOT / "native_ads_fov.cpp"}" /Fo"{obj}"',
        f'link /nologo /DLL /DYNAMICBASE /NXCOMPAT /OUT:"{output / LIBRARY}" /IMPLIB:"{output / "native_ads_fov_0_1_23.lib"}" "{obj}" kernel32.lib']
    if fixtures:
        fixture_obj=output/'fov-fixture.obj'
        commands.extend([f'cl /nologo /c /MT /EHsc /std:c++17 /O2 /W4 /WX "{ROOT / "fov_fixture.cpp"}" /Fo"{fixture_obj}"',
            f'link /nologo /DYNAMICBASE /NXCOMPAT /OUT:"{output / "fov-fixture.exe"}" "{fixture_obj}" kernel32.lib'])
    script=output/'compile-fov.cmd'
    script.write_text('@echo off\ncall "'+str(vcvars)+'" >nul\nif errorlevel 1 exit /b %errorlevel%\n'+''.join(command+'\nif errorlevel 1 exit /b %errorlevel%\n' for command in commands),encoding='utf-8')
    subprocess.run(['cmd','/d','/c',str(script)],cwd=output,check=True)
    if fixtures:subprocess.run([str(output/'fov-fixture.exe')],cwd=output,check=True,timeout=30)
    digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    metadata={'library':LIBRARY,'sha256':digest(output/LIBRARY),'source_sha256':digest(ROOT/'native_ads_fov.cpp'),
        'header_sha256':digest(ROOT/'native_ads_fov.h'),'fixture_sha256':digest(ROOT/'fov_fixture.cpp'),
        'builder_sha256':digest(Path(__file__)),'fixture_passed':fixtures,'abi':1,'config_bytes':80,'stats_bytes':88,
        'begin_results':{'0':'rejected/output generation zero/no owned lease','1':'armed/nonzero generation','2':'nonzero generation/owned cleanup required'},
        'mechanism':'Separate generation-owned CameraAPI writable slot; hip uses exact live TPV degrees; agreeing avatar flags82/125 (not legacy48) shoulder aim smoothly adds5percent focal magnification over120ms; controller byte4 full ADS immediately forwards original zoom and resets shoulder tween.',
        'shoulder_magnification':1.05,'shoulder_blend_ms':120,'shoulder_clock':'QPC only during transitions; bounded delta, pause/backwards rebase',
        'source_degrees':[1,179],'manual_lifetime':True,'pose_helper_dependency':False,
        'statistics':'Generation/lifecycle serialized by control_lock; fresh atomic health/counters; one bounded atomic display snapshot with last-complete fallback, never acquires policy_lock.',
        'executable_writes':False,'protection_changes':False,'minhook_linked':False,
        'lifetime':'Pinned original/callback code; End restores only its owned slot after draining callbacks; no cached FOV restore.',
        'state':'Built locally; not installed or live-validated.'}
    (output/'native-fov-build.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print(json.dumps({'library':str(output/LIBRARY),'sha256':metadata['sha256'],'fixture':fixtures}));return metadata

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path);parser.add_argument('--no-fixture',action='store_true')
    args=parser.parse_args();build(args.output,not args.no_fixture)
