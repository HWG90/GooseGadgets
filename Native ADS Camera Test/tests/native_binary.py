"""Cold-load the built DLL in this separate process; never locate/open the game."""
import ctypes
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DLL = ROOT / "dist/native/native_ads_alignment_0_1_5.dll"


class Config(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in ("size", "abi")] + [
        (name, ctypes.c_uint64) for name in ("game", "exe", "context", "request", "avatar_owner")
    ] + [(name, ctypes.c_uint32) for name in (
        "avatar_index", "avatar", "weapon", "body", "viewmodel", "duration_ms")]


class Stats(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in (
        "size", "abi", "installed", "armed", "expired", "error")
    ] + [(name, ctypes.c_uint64) for name in (
        "seen_position", "seen_rotation", "skipped_position", "skipped_rotation",
        "forwarded_position", "forwarded_rotation")]


def main():
    assert ctypes.sizeof(Config) == ctypes.sizeof(Stats) == 72
    assert Config.game.offset == 8 and Config.duration_ms.offset == 68
    assert Stats.seen_position.offset == 24 and Stats.forwarded_rotation.offset == 64
    native = ctypes.WinDLL(str(DLL))
    for name in ("NADS_Validate", "NADS_Begin"):
        fn = getattr(native, name)
        fn.argtypes = [ctypes.POINTER(Config)]
        fn.restype = ctypes.c_uint32
    native.NADS_End.argtypes = []
    native.NADS_End.restype = ctypes.c_uint32
    native.NADS_Error.argtypes = []
    native.NADS_Error.restype = ctypes.c_uint32
    native.NADS_ReadStats.argtypes = [ctypes.POINTER(Stats)]
    native.NADS_ReadStats.restype = ctypes.c_uint32
    stats = Stats(size=72, abi=1)
    assert native.NADS_ReadStats(ctypes.byref(stats)) == 1
    assert stats.installed == stats.armed == stats.skipped_position == stats.skipped_rotation == 0
    invalid = Config(size=72, abi=1)
    assert native.NADS_Validate(ctypes.byref(invalid)) == 0
    assert native.NADS_Begin(ctypes.byref(invalid)) == 0
    assert native.NADS_End() == 1
    assert native.NADS_ReadStats(ctypes.byref(stats)) == 1
    assert stats.installed == stats.armed == 0
    report = {"dll_sha256": hashlib.sha256(DLL.read_bytes()).hexdigest(),
              "abi_bytes": 72, "five_exports_usable": True, "cold_stats_unarmed": True,
              "invalid_validate_begin_rejected_without_hooks": True, "separate_process": True}
    (ROOT / "dist/native/cold-dll-abi.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Cold DLL ABI passed: 5 exports, 72-byte layouts, no hooks installed or armed")


if __name__ == "__main__":
    main()
