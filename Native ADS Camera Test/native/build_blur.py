"""Build the independent weapon DoF maximum filter and its synthetic native fixture."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parent
MOD=ROOT.parent
LIBRARY='native_ads_blur_0_1_16.dll'

def build(output=None,fixtures=True):
    output=Path(output or MOD/'dist'/'native').resolve();output.mkdir(parents=True,exist_ok=True)
    vcvars=Path(r'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat')
    if not vcvars.is_file():raise RuntimeError('MSVC x64 build environment unavailable')
    obj=output/'native_ads_blur_0_1_16.obj'
    commands=[f'cl /nologo /c /MT /EHsc /std:c++17 /O2 /W4 /WX "{ROOT / "native_ads_blur.cpp"}" /Fo"{obj}"',
        f'link /nologo /DLL /DYNAMICBASE /NXCOMPAT /OUT:"{output / LIBRARY}" /IMPLIB:"{output / "native_ads_blur_0_1_16.lib"}" "{obj}" kernel32.lib']
    if fixtures:
        fixture_obj=output/'blur-fixture.obj'
        commands.extend([f'cl /nologo /c /MT /EHsc /std:c++17 /O2 /W4 /WX "{ROOT / "blur_fixture.cpp"}" /Fo"{fixture_obj}"',
            f'link /nologo /DYNAMICBASE /NXCOMPAT /OUT:"{output / "blur-fixture.exe"}" "{fixture_obj}" kernel32.lib'])
    script=output/'compile-blur.cmd'
    script.write_text('@echo off\ncall "'+str(vcvars)+'" >nul\nif errorlevel 1 exit /b %errorlevel%\n'+''.join(command+'\nif errorlevel 1 exit /b %errorlevel%\n' for command in commands),encoding='utf-8')
    subprocess.run(['cmd','/d','/c',str(script)],cwd=output,check=True)
    if fixtures:subprocess.run([str(output/'blur-fixture.exe')],cwd=output,check=True,timeout=30)
    digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    metadata={'library':LIBRARY,'sha256':digest(output/LIBRARY),'source_sha256':digest(ROOT/'native_ads_blur.cpp'),
        'header_sha256':digest(ROOT/'native_ads_blur.h'),'fixture_sha256':digest(ROOT/'blur_fixture.cpp'),
        'builder_sha256':digest(Path(__file__)),'fixture_passed':fixtures,'abi':1,'config_bytes':80,'stats_bytes':80,
        'begin_results':{'0':'rejected/output generation zero/no owned lease','1':'armed/nonzero generation','2':'nonzero generation/owned cleanup required'},
        'mechanism':'Generation-owned writable native parameter setter slot. Exact native caller/provider/packed weapon component/hash/float Variant; only near/far/far-close DoF maxima become zero. Native FOV, zoom and other effects remain unchanged.',
        'parameter_hashes':['A7990477','F07FC12E','209F72CF'],'component_class':'F7A3101F',
        'manual_lifetime':True,'executable_writes':False,'protection_changes':False,'minhook_linked':False,
        'lifetime':'Pinned callbacks; End drains adjusted setter then restores only own slot; no old effect value replay.',
        'state':'Built locally; not installed or live-validated.'}
    (output/'native-blur-build.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print(json.dumps({'library':str(output/LIBRARY),'sha256':metadata['sha256'],'fixture':fixtures}));return metadata

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path);parser.add_argument('--no-fixture',action='store_true')
    args=parser.parse_args();build(args.output,not args.no_fixture)
