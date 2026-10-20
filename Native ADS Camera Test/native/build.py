"""Build the owned dispatch-pointer helper and separate-process fixture."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parent
MOD=ROOT.parent
LIBRARY='native_ads_alignment_0_1_5.dll'
def compile_at(output,commands):
    vcvars=Path(r'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat')
    if not vcvars.is_file():raise RuntimeError('MSVC x64 build environment unavailable')
    script=output/'compile-dispatch.cmd'
    script.write_text('@echo off\ncall "'+str(vcvars)+'" >nul\nif errorlevel 1 exit /b %errorlevel%\n'+''.join(command+'\nif errorlevel 1 exit /b %errorlevel%\n' for command in commands),encoding='utf-8')
    subprocess.run(['cmd','/d','/c',str(script)],cwd=output,check=True)
def build(output=None,fixtures=True):
    output=Path(output or MOD/'dist'/'native').resolve();output.mkdir(parents=True,exist_ok=True)
    obj=output/'native_ads_dispatch.obj'
    commands=[f'cl /nologo /c /MT /EHsc /std:c++17 /O2 /W4 /WX "{ROOT / "native_ads_alignment.cpp"}" /Fo"{obj}"',f'link /nologo /DLL /DYNAMICBASE /NXCOMPAT /OUT:"{output / LIBRARY}" /IMPLIB:"{output / "native_ads_dispatch.lib"}" "{obj}" kernel32.lib']
    if fixtures:
        fixture_obj=output/'dispatch-fixture.obj'
        commands.extend([f'cl /nologo /c /MT /EHsc /std:c++17 /O2 /W4 /WX "{ROOT / "fixture.cpp"}" /Fo"{fixture_obj}"',f'link /nologo /DYNAMICBASE /NXCOMPAT /OUT:"{output / "dispatch-fixture.exe"}" "{fixture_obj}" kernel32.lib'])
    compile_at(output,commands)
    metadata={'library':LIBRARY,'sha256':hashlib.sha256((output/LIBRARY).read_bytes()).hexdigest(),'source_sha256':hashlib.sha256((ROOT/'native_ads_alignment.cpp').read_bytes()).hexdigest(),'header_sha256':hashlib.sha256((ROOT/'native_ads_alignment.h').read_bytes()).hexdigest(),'abi':1,'config_bytes':72,'stats_bytes':72,'begin_results':{'0':'rejected/no owned lease','1':'armed','2':'owned cleanup required'},'mechanism':'Aligned PAGE_READWRITE image dispatch-pointer compare/exchange with ownership checks.','executable_writes':False,'protection_changes':False,'minhook_linked':False,'lifetime':'Process-pinned callbacks; End restores owned dispatch pointers. Cached callbacks forward after disarm.','state':'Built locally; not installed or live-validated.'}
    (output/'native-dispatch-build.json').write_text(json.dumps(metadata,indent=2)+'\n')
    if fixtures:subprocess.run([str(output/'dispatch-fixture.exe')],check=True,cwd=output,timeout=30)
    print(json.dumps({'library':str(output/LIBRARY),'sha256':metadata['sha256'],'fixture':fixtures}));return metadata
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path);parser.add_argument('--no-fixture',action='store_true');args=parser.parse_args();build(args.output,not args.no_fixture)
