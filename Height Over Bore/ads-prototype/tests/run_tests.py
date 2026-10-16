"""Isolated LuaJIT fixture helper and entry point for the ADS prototype suite."""
from __future__ import annotations

import argparse
import ctypes
import importlib.util
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DLL = Path(r"C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2\bin\lua51.dll")


def run_lua(dll_path: Path, files=("parameters.lua", "ads_gate_test.lua", "prototype.lua", "backend_prototype.lua", "bsl.lua", "loader_prototype.lua")) -> int:
    if not dll_path.is_file():
        raise ValueError("LuaJIT DLL unavailable: " + str(dll_path))
    directory = os.add_dll_directory(str(dll_path.parent))
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
    lua.lua_pushlstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
    lua.lua_setfield.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p]
    lua.lua_close.argtypes = [ctypes.c_void_p]
    state = lua.luaL_newstate()
    if not state:
        raise ValueError("Could not create isolated LuaJIT state")
    try:
        lua.luaL_openlibs(state)
        value = ROOT.as_posix().encode("utf-8")
        lua.lua_pushlstring(state, value, len(value))
        lua.lua_setfield(state, -10002, b"HOB_TEST_ROOT")
        status = lua.luaL_loadstring(state, b"assert(jit and jit.version);require('ffi');require('bit')") or lua.lua_pcall(state, 0, 0, 0)
        for name in files:
            if status:
                break
            source = ROOT / "tests" / name
            status = lua.luaL_loadfile(state, str(source).encode("utf-8")) or lua.lua_pcall(state, 0, 0, 0)
        if status:
            error = lua.lua_tolstring(state, -1, None)
            print(error.decode("utf-8", "replace") if error else "Unknown Lua test failure")
            return 1
        return 0
    finally:
        lua.lua_close(state)
        directory.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dll", type=Path, default=Path(os.environ.get("DBF_LUA_DLL", DEFAULT_DLL)))
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location("hob_ads_suite", ROOT / "tools" / "test_prototype.py")
    suite = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(suite)
    return suite.main(args.dll)


if __name__ == "__main__":
    raise SystemExit(main())
