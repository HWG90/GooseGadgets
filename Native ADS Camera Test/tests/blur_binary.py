"""Cold ABI/idle validation in a separate process; never open the game."""
import argparse
import ctypes as C
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class Config(C.Structure):
    _fields_ = [(n,C.c_uint32) for n in ('size','abi')] + [
        (n,C.c_uint64) for n in ('game','exe','context','camera','avatar_owner','request')
    ] + [(n,C.c_uint32) for n in ('avatar_index','avatar','body','weapon')] + [('reserved',C.c_uint64)]

class Stats(C.Structure):
    _fields_ = [(n,C.c_uint32) for n in ('size','abi','installed','armed','error','reserved')] + [
        (n,C.c_uint64) for n in ('seen','forwarded','replaced','immediate_applies')
    ] + [(n,C.c_uint32) for n in ('last_hash','last_instance')] + [
        (n,C.c_float) for n in ('last_native','last_applied')
    ] + [('reserved_tail',C.c_uint64)]

if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll',type=Path,default=ROOT/'dist/native/native_ads_blur_0_1_16.dll')
    a=p.parse_args();lib=C.WinDLL(str(a.dll.resolve()))
    assert C.sizeof(Config)==80 and C.sizeof(Stats)==80
    for name in ('Validate','Begin','End','ReadStats','Error'):getattr(lib,'NADSB_'+name)
    lib.NADSB_Validate.argtypes=[C.POINTER(Config)];lib.NADSB_Validate.restype=C.c_uint32
    lib.NADSB_Begin.argtypes=[C.POINTER(Config),C.POINTER(C.c_uint64)];lib.NADSB_Begin.restype=C.c_uint32
    lib.NADSB_End.argtypes=[C.c_uint64];lib.NADSB_End.restype=C.c_uint32
    lib.NADSB_ReadStats.argtypes=[C.c_uint64,C.POINTER(Stats)];lib.NADSB_ReadStats.restype=C.c_uint32
    config=Config();config.size=80;config.abi=1;token=C.c_uint64(99)
    assert lib.NADSB_Validate(C.byref(config))==0
    assert lib.NADSB_Begin(C.byref(config),C.byref(token))==0 and token.value==0
    assert lib.NADSB_End(0)==0
    stats=Stats();stats.size=80;stats.abi=1
    assert lib.NADSB_ReadStats(0,C.byref(stats))==1 and not stats.installed and not stats.armed
    print('Native blur cold ABI: 80/80 bytes, 5 exports, invalid-config refusal and idle cleanup PASS')
