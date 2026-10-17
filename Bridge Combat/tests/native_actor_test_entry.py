"""Test the review-only entry's refusal in an isolated non-game process."""
import argparse
import ctypes as C
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dll", type=Path)
    parser.add_argument("--production", action="store_true")
    args = parser.parse_args()
    kernel = C.WinDLL("kernel32", use_last_error=True)
    kernel.GetModuleHandleW.argtypes = [C.c_wchar_p]
    kernel.GetModuleHandleW.restype = C.c_void_p
    assert not kernel.GetModuleHandleW("game.dll"), "Run only in an isolated non-game process"
    dll = C.CDLL(str(args.dll.resolve()))
    start = dll.BC_start_actor if args.production else dll.BC_start_actor_test
    start.argtypes = [C.c_uint32]
    start.restype = C.c_int
    if args.production:
        try:
            dll.BC_start_actor_test
        except AttributeError:
            pass
        else:
            raise AssertionError("Production helper exposes a review-only test entry")
    dll.BC_stop.restype = C.c_int
    dll.BC_status.restype = C.c_uint32
    dll.BC_ready.restype = C.c_uint32
    dll.BC_error.restype = C.c_char_p
    dll.BC_tick.argtypes = [C.c_float]
    dll.BC_tick.restype = C.c_int
    assert start(1060) == 0
    assert b"Current local bridge actor/build is not valid" in dll.BC_error()
    assert dll.BC_status() == 0
    assert dll.BC_ready() == 0
    assert dll.BC_tick(1 / 60) == 1
    assert dll.BC_stop() == 1
    assert dll.BC_stop() == 1
    assert dll.BC_status() == 0
    assert dll.BC_ready() == 0
    print("9 actor test-entry refusal/readiness/cleanup contracts passed; no game module loaded")


if __name__ == "__main__":
    main()
