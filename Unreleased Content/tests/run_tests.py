"""Run each Lua fixture in a fresh LuaJIT VM without starting the game."""

from __future__ import annotations

import argparse
import ctypes
import os
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DLL = Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2\bin\lua51.dll"
)


def load_lua(path: Path) -> ctypes.CDLL:
    if not path.is_file():
        raise FileNotFoundError(f"LuaJIT DLL not found: {path}")
    lua = ctypes.CDLL(str(path.resolve()))
    lua.luaL_newstate.argtypes = []
    lua.luaL_newstate.restype = ctypes.c_void_p
    lua.luaL_openlibs.argtypes = [ctypes.c_void_p]
    lua.luaL_openlibs.restype = None
    lua.luaL_loadfile.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lua.luaL_loadfile.restype = ctypes.c_int
    lua.lua_pcall.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int
    ]
    lua.lua_pcall.restype = ctypes.c_int
    lua.lua_tolstring.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)
    ]
    lua.lua_tolstring.restype = ctypes.c_void_p
    lua.lua_close.argtypes = [ctypes.c_void_p]
    lua.lua_close.restype = None
    return lua


def run_fixture(lua: ctypes.CDLL, path: Path) -> tuple[bool, str]:
    state = lua.luaL_newstate()
    if not state:
        return False, "Could not allocate Lua VM"
    try:
        lua.luaL_openlibs(state)
        result = lua.luaL_loadfile(state, os.fsencode(path))
        if result == 0:
            result = lua.lua_pcall(state, 0, 1, 0)
        length = ctypes.c_size_t()
        value = lua.lua_tolstring(state, -1, ctypes.byref(length))
        message = (
            ctypes.string_at(value, length.value).decode("utf-8", errors="replace")
            if value else "(no fixture result)"
        )
        return result == 0, message
    finally:
        lua.lua_close(state)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dll", type=Path, default=DEFAULT_DLL)
    args = parser.parse_args()
    fixtures = sorted((ROOT / "tests").glob("*.lua"))
    if not fixtures:
        print("No Lua fixtures found.", file=sys.stderr)
        return 1
    try:
        lua = load_lua(args.dll)
    except (OSError, AttributeError) as error:
        print(f"Could not load LuaJIT: {error}", file=sys.stderr)
        return 1
    previous = Path.cwd()
    failures = 0
    try:
        os.chdir(ROOT)
        for fixture in fixtures:
            passed, message = run_fixture(lua, fixture)
            print(f"{'PASS' if passed else 'FAIL'} {fixture.name}: {message}")
            failures += not passed
    finally:
        os.chdir(previous)
    print(f"{len(fixtures) - failures}/{len(fixtures)} fixtures passed.")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
