"""Cold-load the placement DLL outside the game and verify its public ABI."""
import ctypes
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
DLL=ROOT/'dist/native/native_ads_editor_0_1_43.dll'


class Config(ctypes.Structure):
    _fields_=[(n,ctypes.c_uint32) for n in ('size','abi')]+[
        (n,ctypes.c_uint64) for n in ('game','exe','context','request','avatar_owner')]+[
        (n,ctypes.c_uint32) for n in ('avatar_index','avatar','weapon','body','viewmodel','duration_ms')]+[
        ('weapon_descriptor',ctypes.c_uint64),('weapon_unit',ctypes.c_uint32),('blend_ms',ctypes.c_uint32)]+[
        (n,ctypes.c_float) for n in ('offset_x','offset_y','offset_z')]+[('reserved',ctypes.c_uint32)]


class Stats(ctypes.Structure):
    _fields_=[(n,ctypes.c_uint32) for n in ('size','abi','installed','armed','expired','error')]+[
        (n,ctypes.c_uint64) for n in ('seen_position','seen_rotation','forwarded_position',
        'forwarded_rotation','weapon_updates','zero_restores')]+[
        ('blend',ctypes.c_float),('target_weight',ctypes.c_float)]


class DepthStats(ctypes.Structure):
    _fields_=[(n,ctypes.c_uint32) for n in ('size','abi','installed','armed','supported','reason','zoom_index','reserved')]+[
        (n,ctypes.c_uint64) for n in ('applied','unsupported','cache_refreshes','cache_checks','ads_bypassed')]+[
        (n,ctypes.c_float) for n in ('native_distance','reference_distance','correction','zoom','target_fov','current_fov','gain','padding')]


def main():
    assert ctypes.sizeof(Config)==104 and ctypes.sizeof(Stats)==80 and ctypes.sizeof(DepthStats)==104
    assert Config.offset_x.offset==88 and Config.offset_y.offset==92 and Config.reserved.offset==100
    native=ctypes.WinDLL(str(DLL))
    signatures={
        'NADSE_Validate':[ctypes.POINTER(Config)],
        'NADSE_Begin':[ctypes.POINTER(Config),ctypes.POINTER(ctypes.c_uint64)],
        'NADSE_SetPlacement':[ctypes.c_uint64,ctypes.c_float,ctypes.c_float,ctypes.c_float],
        'NADSE_SetADSPlacement':[ctypes.c_uint64,ctypes.c_float,ctypes.c_float,ctypes.c_float],
        'NADSE_SetMotion':[ctypes.c_uint64,ctypes.c_float,ctypes.c_float,ctypes.c_float],
        'NADSE_SetAuthoredTransform':[ctypes.c_uint64]+[ctypes.c_float]*7,
        'NADSE_SetTransform':[ctypes.c_uint64]+[ctypes.c_float]*7,
        'NADSE_End':[ctypes.c_uint64],
        'NADSE_ReadStats':[ctypes.c_uint64,ctypes.POINTER(Stats)],
        'NADSE_ReadDepthStats':[ctypes.c_uint64,ctypes.POINTER(DepthStats)],
        'NADSE_Error':[],
    }
    for name,args in signatures.items():
        fn=getattr(native,name);fn.argtypes=args;fn.restype=ctypes.c_uint32
    assert native.NADSE_SetADSPlacement(0,0,0,0)==0
    stats=Stats(size=80,abi=2)
    assert native.NADSE_ReadStats(0,ctypes.byref(stats))==1
    assert stats.installed==stats.armed==stats.weapon_updates==stats.zero_restores==0
    depth=DepthStats(size=104,abi=1)
    assert native.NADSE_ReadDepthStats(0,ctypes.byref(depth))==1 and depth.installed==depth.armed==depth.applied==0
    assert native.NADSE_ReadDepthStats(1,ctypes.byref(depth))==0
    depth.size=80
    assert native.NADSE_ReadDepthStats(0,ctypes.byref(depth))==0
    depth.size=104;depth.abi=2
    assert native.NADSE_ReadDepthStats(0,ctypes.byref(depth))==0
    depth.abi=1;depth.reserved=1
    assert native.NADSE_ReadDepthStats(0,ctypes.byref(depth))==0
    invalid=Config(size=104,abi=2)
    assert native.NADSE_Validate(ctypes.byref(invalid))==0
    token=ctypes.c_uint64(123456)
    assert native.NADSE_Begin(ctypes.byref(invalid),ctypes.byref(token))==0 and token.value==0
    assert native.NADSE_SetPlacement(0,.15,.02,-.12)==0
    assert native.NADSE_SetMotion(0,.01,.02,-.01)==0
    assert native.NADSE_SetTransform(0,.01,.02,-.01,0,0,0,1)==0
    assert native.NADSE_End(0)==0
    assert native.NADSE_ReadStats(0,ctypes.byref(stats))==1
    assert stats.installed==stats.armed==0
    report={'dll_sha256':hashlib.sha256(DLL.read_bytes()).hexdigest(),'abi':2,
            'config_bytes':104,'stats_bytes':80,'nine_exports_usable':True,'depth_stats_bytes':104,
            'invalid_begin_zeroes_token':True,'zero_token_cannot_edit_or_end':True,
            'cold_unarmed':True,'separate_process':True}
    (ROOT/'dist/native/cold-editor-dll-abi.json').write_text(json.dumps(report,indent=2)+'\n')
    print('Cold editor DLL ABI passed: 11 exports, Config104/Stats80/Depth104, generation/size/ABI rejection, no hooks armed')


if __name__=='__main__':
    main()
