"""Build the independent normal-camera head anchor and its synthetic native fixture."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parent
MOD=ROOT.parent
LIBRARY='native_ads_camera_0_1_48.dll'

def build(output=None,fixtures=True):
    output=Path(output or MOD/'dist'/'native').resolve();output.mkdir(parents=True,exist_ok=True)
    vcvars=Path(r'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat')
    if not vcvars.is_file():raise RuntimeError('MSVC x64 build environment unavailable')
    obj=output/'native_ads_camera_0_1_48.obj'
    commands=[f'cl /nologo /c /MT /EHsc /std:c++17 /O2 /W4 /WX "{ROOT / "native_ads_camera.cpp"}" /Fo"{obj}"',
        f'link /nologo /DLL /DYNAMICBASE /NXCOMPAT /OUT:"{output / LIBRARY}" /IMPLIB:"{output / "native_ads_camera_0_1_48.lib"}" "{obj}" kernel32.lib']
    if fixtures:
        fixture_obj=output/'camera-fixture.obj'
        commands.extend([f'cl /nologo /c /MT /EHsc /std:c++17 /O2 /W4 /WX "{ROOT / "camera_fixture.cpp"}" /Fo"{fixture_obj}"',
            f'link /nologo /DYNAMICBASE /NXCOMPAT /OUT:"{output / "camera-fixture.exe"}" "{fixture_obj}" kernel32.lib'])
    script=output/'compile-camera.cmd'
    script.write_text('@echo off\ncall "'+str(vcvars)+'" >nul\nif errorlevel 1 exit /b %errorlevel%\n'+''.join(command+'\nif errorlevel 1 exit /b %errorlevel%\n' for command in commands),encoding='utf-8')
    subprocess.run(['cmd','/d','/c',str(script)],cwd=output,check=True)
    if fixtures:subprocess.run([str(output/'camera-fixture.exe')],cwd=output,check=True,timeout=30)
    digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    metadata={'library':LIBRARY,'sha256':digest(output/LIBRARY),'source_sha256':digest(ROOT/'native_ads_camera.cpp'),
        'header_sha256':digest(ROOT/'native_ads_camera.h'),'free_aim_math_sha256':digest(ROOT/'free_aim_math.h'),'camera_transition_sha256':digest(ROOT/'camera_transition.h'),'fixture_sha256':digest(ROOT/'camera_fixture.cpp'),
        'builder_sha256':digest(Path(__file__)),'fixture_passed':fixtures,'abi':1,'config_bytes':88,'stats_bytes':80,
        'begin_results':{'0':'rejected/output generation zero/no owned lease','1':'armed/nonzero generation','2':'nonzero generation/owned cleanup required'},
        'mechanism':'Generation-owned CameraAPI+20 lease. Normal4 damps head in body-root-local coordinates with fresh root motion, horizontal clearance and world-up. Captured on-foot mask0x20 permits fallback only; arming retains mask0/2. Native6 position forwards exactly. Opt-in 30-second free aim changes only validated current-thread camera quaternion scratch, with exact full ADS pass-through.',
        'manual_lifetime':True,'weapon_dependency':False,'executable_writes':False,'protection_changes':False,'minhook_linked':False,
        'statistics':'Fresh atomic health/counters; one bounded atomic blend/head-distance/dt snapshot with last-complete fallback, never acquires policy_lock.',
        'on_foot':'Known body4D1C334D294DFA97/31layers: mission L14=36 unchanged; bridge L14=3 additionally requires actual avatar control-word &6==2 and scene3, with role/scene/owner/generation revalidation. Ordinary ship role4 excluded.',
        'lifetime':'Pinned callback code; End drains adjusted setter and restores owned slot only; no cached position replay.',
        'state':'Built locally; not installed or live-validated.'}
    (output/'native-camera-build.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print(json.dumps({'library':str(output/LIBRARY),'sha256':metadata['sha256'],'fixture':fixtures}));return metadata

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path);parser.add_argument('--no-fixture',action='store_true')
    args=parser.parse_args();build(args.output,not args.no_fixture)
