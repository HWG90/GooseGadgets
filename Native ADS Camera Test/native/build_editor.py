"""Build the generation-owned XYZ editor helper and offline native fixture."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parent
MOD=ROOT.parent
LIBRARY='native_ads_editor_0_1_43.dll'
def compile_at(output,commands):
    vcvars=Path(r'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat')
    if not vcvars.is_file():raise RuntimeError('MSVC x64 build environment unavailable')
    script=output/'compile-editor.cmd'
    script.write_text('@echo off\ncall "'+str(vcvars)+'" >nul\nif errorlevel 1 exit /b %errorlevel%\n'+''.join(command+'\nif errorlevel 1 exit /b %errorlevel%\n' for command in commands),encoding='utf-8')
    subprocess.run(['cmd','/d','/c',str(script)],cwd=output,check=True)
def build(output=None,fixtures=True):
    output=Path(output or MOD/'dist'/'native').resolve();output.mkdir(parents=True,exist_ok=True)
    obj=output/'native_ads_editor_0_1_43.obj'
    commands=[f'cl /nologo /c /MT /EHsc /std:c++17 /O2 /W4 /WX "{ROOT / "native_ads_editor.cpp"}" /Fo"{obj}"',f'link /nologo /DLL /DYNAMICBASE /NXCOMPAT /OUT:"{output / LIBRARY}" /IMPLIB:"{output / "native_ads_editor_0_1_43.lib"}" "{obj}" kernel32.lib']
    if fixtures:
        fixture_obj=output/'editor-fixture.obj'
        commands.extend([f'cl /nologo /c /MT /EHsc /std:c++17 /O2 /W4 /WX "{ROOT / "editor_fixture.cpp"}" /Fo"{fixture_obj}"',f'link /nologo /DYNAMICBASE /NXCOMPAT /OUT:"{output / "editor-fixture.exe"}" "{fixture_obj}" kernel32.lib'])
    compile_at(output,commands)
    if fixtures:subprocess.run([str(output/'editor-fixture.exe')],check=True,cwd=output,timeout=30)
    metadata={'library':LIBRARY,'sha256':hashlib.sha256((output/LIBRARY).read_bytes()).hexdigest(),'source_sha256':hashlib.sha256((ROOT/'native_ads_editor.cpp').read_bytes()).hexdigest(),'header_sha256':hashlib.sha256((ROOT/'native_ads_editor.h').read_bytes()).hexdigest(),'fixture_sha256':hashlib.sha256((ROOT/'editor_fixture.cpp').read_bytes()).hexdigest(),'builder_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'fixture_passed':fixtures,'abi':2,'config_bytes':104,'stats_bytes':80,'max_duration_ms':30500,'zero_duration':'Manual lifetime until End or guard failure; no TTL expiry.','begin_results':{'0':'rejected/output generation zero/no owned lease','1':'armed/nonzero generation','2':'nonzero generation/owned cleanup required'},'mechanism':'Generation-owned pointer callback adds runtime XYZ with smoothstep ADS blend to fresh native shared arms/weapon node5 position only. All carrier roots remain exact.','placement_bounds_meters':[-0.5,0.5],'placement_update_extends_deadline':False,'read_stats_zero_generation':'Only when no reservation exists. Matching generation can observe disarmed cleanup pending.','executable_writes':False,'protection_changes':False,'minhook_linked':False,'lifetime':'Process-pinned callbacks; generation-matched End restores only verified native baseline and owned dispatch pointers. Cached callbacks forward after disarm.','state':'Built locally; not installed or live-validated.'}
    metadata.update({'motion_bounds_meters':[-0.15,0.15],
        'statistics':'Fresh atomic health/counters; one bounded atomic blend/target snapshot. Manual and timed-unexpired stats never wait for a setter. Timed expiry retains locked drain/restoration using its immutable lifecycle deadline.',
        'aim_weights':{'hip':1,'shoulder_aim':1,'native_full_ads':0},
        'aim_signals':{'shoulder':'Accepted character bits82 and125 both set; disagreement remains hip.','native_full_ads':'Native controller byte4; takes priority.','entry_veto':'Unchanged bit48 or native controller byte4; accepted shoulder aim alone permits entry.'},
        'depth_normalization':{'reference':'First authored zoom selection, not an arbitrary entry selection.','application':'Copied node5 Y only; no request or lens writes. UnitAPI+0 observer at game1287A41 captures the native lens locals before stack reuse.','gates':'Exact original getter return; one request/frame/thread/generation-matched capture; stable early/late request bytes except native-updated88; zero sight coupling; normal optic mode; proven previous/current reference. Full ADS bypasses immediately.','cache':'Native distance-event refresh; unchanged frames use three small observation/state reads plus one additional dispatch-ownership read; metadata revalidation at most2 Hz.','performance_fixture':'45 getter+position RPM calls versus41 in22; identity rotation remains0. Unrelated global getter callers do no helper RPM, locks or counters.','diagnostics':'Optional generation-owned NADSE_ReadDepthStats,104-byte ABI1; no automatic Lua polling.','visual_limit':'ADS entry immediately removes the new depth correction; visible muzzle handoff and gameplay behavior require live acceptance.'},
        'motion_update_extends_deadline':False,'motion_saved_separately':True,
        'rotation_bounds_degrees':35,'rotation_callsite':'game+0x12890DB / UnitAPI+0x40 immediate local rotation',
        'rotation_apply_gates':'Sole owned kind6 ring request; sight coupling request+0x98 exactly zero; real full ADS forwards original.',
        'rotation_baseline':'Fresh native stack quaternion, never the previously written graph pose.',
        'atomic_transform_export':'NADSE_SetTransform(generation,dx,dy,dz,qx,qy,qz,qw)',
        'counter_semantics':'weapon_updates counts changed node5 position and rotation calls; zero_restores counts native-baseline restoration operations.',
        'performance':'Exact-identity/no-pending-rotation callback forwards without a memory walk; graph metadata is copied in two252-byte arrays while preserving all selected-node guards.',
        'mechanism':'Generation-owned callbacks add hip-weighted saved XYZ plus separate bounded motion XYZ and a parent-local quaternion delta to fresh native shared arms/weapon node5 inputs. Supported zoom-depth correction is paired with same-invocation carrier0 translation using its fresh native quaternion; native rotations and full ADS remain original.',
        'carrier_depth':{'application':'Copied root0 position at12887C9 minus paired node5 depth delta times fresh native quaternion forward. No request, lens, executable or root rotation writes.',
            'pairing':'Same native RSP, thread, request, generation and stable request signature; exact root source RSP+240; final quaternion at source-10. Each capture consumed once.',
            'restore':'Exact original native root replay only when current owned root matrix XYZ still equals last written XYZ and pose-array identity is unchanged; foreign/native writes invalidate eligibility.',
            'visual_limit':'Direct depth coupling is removed. Native four-pass quaternion solve can retain zoom-dependent orientation; visual acceptance and crash investigation remain pending.'}})
    (output/'native-editor-build.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print(json.dumps({'library':str(output/LIBRARY),'sha256':metadata['sha256'],'fixture':fixtures}));return metadata
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path);parser.add_argument('--no-fixture',action='store_true');args=parser.parse_args();build(args.output,not args.no_fixture)
