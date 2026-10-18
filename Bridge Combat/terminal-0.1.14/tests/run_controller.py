"""Run isolated controller contracts in LuaJIT inside this Python process."""

from __future__ import annotations

import argparse
import ctypes
import os
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DLL = Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2\bin\lua51.dll"
)


def run(lua_path: Path, dll_path: Path) -> int:
    if not dll_path.is_file():
        raise SystemExit(f"LuaJIT DLL unavailable: {dll_path}")
    if not lua_path.is_file():
        raise SystemExit(f"Contract file unavailable: {lua_path}")

    # Loading the DLL here creates a separate interpreter in this test process.
    # It does not attach to the game or load its native game module.
    dll_directory = os.add_dll_directory(str(dll_path.parent))
    lua = ctypes.CDLL(str(dll_path))
    lua.luaL_newstate.restype = ctypes.c_void_p
    lua.luaL_openlibs.argtypes = [ctypes.c_void_p]
    lua.luaL_loadstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lua.luaL_loadstring.restype = ctypes.c_int
    lua.luaL_loadfile.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lua.luaL_loadfile.restype = ctypes.c_int
    lua.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
    lua.lua_pcall.restype = ctypes.c_int
    lua.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
    lua.lua_tolstring.restype = ctypes.c_char_p
    lua.lua_close.argtypes = [ctypes.c_void_p]
    lua.lua_pushlstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
    lua.lua_setfield.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p]

    state = lua.luaL_newstate()
    if not state:
        raise SystemExit("Could not create isolated LuaJIT state")
    lua.luaL_openlibs(state)
    os.environ["DBF_BRIDGE_COMBAT_TEST_ROOT"] = str(ROOT).replace("\\", "/")
    root_bytes = str(ROOT).replace("\\", "/").encode("utf-8")
    lua.lua_pushlstring(state, root_bytes, len(root_bytes))
    lua.lua_setfield(state, -10002, b"BRIDGE_COMBAT_TEST_ROOT")
    try:
        source = b"assert(jit and jit.version, 'LuaJIT required');require('ffi');require('bit')"
        status = lua.luaL_loadstring(state, source) or lua.lua_pcall(state, 0, 0, 0)
        if not status:
            status = lua.luaL_loadfile(state, str(lua_path).encode("utf-8"))
        if not status:
            status = lua.lua_pcall(state, 0, 0, 0)
        if status:
            error = lua.lua_tolstring(state, -1, None)
            print(error.decode("utf-8", "replace") if error else "Unknown Lua test failure")
            return 1
        return 0
    finally:
        lua.lua_close(state)
        dll_directory.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dll", type=Path, default=Path(os.environ.get("DBF_LUA_DLL", DEFAULT_DLL)))
    parser.add_argument("--lua", type=Path, default=ROOT / "tests" / "controller.lua")
    args = parser.parse_args()
    return run(args.lua, args.dll)


if __name__ == "__main__":
    raise SystemExit(main())
