"""Cold-load the staged helper in this process; never Validate/Begin game state."""
from __future__ import annotations
import argparse
import ctypes
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
class Config(ctypes.Structure):
    _fields_=[('size',ctypes.c_uint32),('abi',ctypes.c_uint32)]+[(n,ctypes.c_uint64) for n in ('game','exe','context','camera','avatar_owner')]+[(n,ctypes.c_uint32) for n in ('avatar_index','avatar','body','camera_unit')]+[(n,ctypes.c_float) for n in ('forward','up','smoothing_ms','blend_ms')]+[('max_gap_ms',ctypes.c_uint32),('reserved',ctypes.c_uint32)]
class Stats(ctypes.Structure):
    _fields_=[(n,ctypes.c_uint32) for n in ('size','abi','installed','armed','error','reserved')]+[(n,ctypes.c_uint64) for n in ('seen','forwarded','replaced','native6_forwarded','resets')]+[(n,ctypes.c_float) for n in ('blend','head_distance','last_dt','padding')]
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--dll',type=Path,default=ROOT/'dist/native/native_ads_camera_0_1_27.dll')
    args=parser.parse_args();path=args.dll.resolve()
    assert ctypes.sizeof(Config)==88 and ctypes.sizeof(Stats)==80
    assert Config.avatar_index.offset==48 and Config.forward.offset==64 and Stats.seen.offset==24 and Stats.blend.offset==64
    library=ctypes.CDLL(str(path))
    for name in ('Validate','Begin','End','ReadStats','Error'):assert getattr(library,'NADSC_'+name)
    library.NADSC_ReadStats.argtypes=[ctypes.c_uint64,ctypes.POINTER(Stats)];library.NADSC_ReadStats.restype=ctypes.c_uint32
    library.NADSC_Error.argtypes=[];library.NADSC_Error.restype=ctypes.c_uint32
    stats=Stats();stats.size=80;stats.abi=1
    assert library.NADSC_ReadStats(0,ctypes.byref(stats))==1
    assert stats.installed==stats.armed==stats.error==stats.seen==stats.forwarded==stats.replaced==0
    digest=hashlib.sha256(path.read_bytes()).hexdigest()
    receipt_path=path.parent/'native-camera-build.json'
    if receipt_path.is_file():assert json.loads(receipt_path.read_text())['sha256']==digest
    print(json.dumps({'cold_abi':'PASS','config_bytes':88,'stats_bytes':80,'sha256':digest,'hooks_installed':False,'game_access':False}))
if __name__=='__main__':main()
