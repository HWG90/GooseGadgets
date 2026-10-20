"""Cold-load the pose DLL in a separate process, without locating the game."""
import ctypes
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DLL = ROOT / "dist/native/native_ads_pose_0_1_7.dll"


class Config(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in ("size", "abi")] + [
        (name, ctypes.c_uint64) for name in ("game", "exe", "context", "request", "avatar_owner")
    ] + [(name, ctypes.c_uint32) for name in (
        "avatar_index", "avatar", "weapon", "body", "viewmodel", "duration_ms")
    ] + [("weapon_descriptor", ctypes.c_uint64), ("weapon_unit", ctypes.c_uint32),
         ("blend_ms", ctypes.c_uint32), ("offset_x", ctypes.c_float), ("offset_z", ctypes.c_float)]


class Stats(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in (
        "size", "abi", "installed", "armed", "expired", "error")
    ] + [(name, ctypes.c_uint64) for name in (
        "seen_position", "seen_rotation", "forwarded_position", "forwarded_rotation",
        "weapon_updates", "zero_restores")
    ] + [("blend", ctypes.c_float), ("target_weight", ctypes.c_float)]


def main():
    assert ctypes.sizeof(Config) == 96 and ctypes.sizeof(Stats) == 80
    assert Config.weapon_descriptor.offset == 72 and Config.offset_z.offset == 92
    assert Stats.weapon_updates.offset == 56 and Stats.blend.offset == 72
    native = ctypes.WinDLL(str(DLL))
    for name in ("NADSP_Validate", "NADSP_Begin"):
        fn = getattr(native, name)
        fn.argtypes = [ctypes.POINTER(Config)]
        fn.restype = ctypes.c_uint32
    native.NADSP_End.argtypes = []
    native.NADSP_End.restype = ctypes.c_uint32
    native.NADSP_Error.argtypes = []
    native.NADSP_Error.restype = ctypes.c_uint32
    native.NADSP_ReadStats.argtypes = [ctypes.POINTER(Stats)]
    native.NADSP_ReadStats.restype = ctypes.c_uint32
    stats = Stats(size=80, abi=1)
    assert native.NADSP_ReadStats(ctypes.byref(stats)) == 1
    assert stats.installed == stats.armed == stats.weapon_updates == stats.zero_restores == 0
    invalid = Config(size=96, abi=1)
    assert native.NADSP_Validate(ctypes.byref(invalid)) == 0
    assert native.NADSP_Begin(ctypes.byref(invalid)) == 0
    assert native.NADSP_End() == 1
    assert native.NADSP_ReadStats(ctypes.byref(stats)) == 1
    assert stats.installed == stats.armed == 0
    report = {"dll_sha256": hashlib.sha256(DLL.read_bytes()).hexdigest(),
              "config_bytes": 96, "stats_bytes": 80, "five_exports_usable": True,
              "cold_stats_unarmed": True, "invalid_config_rejected_without_hooks": True,
              "separate_process": True}
    (ROOT / "dist/native/cold-pose-dll-abi.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Cold pose DLL ABI passed: 5 exports, 96/80-byte layouts, no hooks installed or armed")


if __name__ == "__main__":
    main()
