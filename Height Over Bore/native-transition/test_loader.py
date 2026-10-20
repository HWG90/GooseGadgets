"""Run offline Lua lifecycle tests using an explicitly supplied LuaJIT DLL."""
from pathlib import Path
import ctypes
import hashlib
import json
import sys
ROOT=Path(__file__).resolve().parent
library=Path(sys.argv[1]).resolve(strict=True)
dll=ctypes.CDLL(str(library))
dll.luaL_newstate.restype=ctypes.c_void_p
dll.luaL_openlibs.argtypes=[ctypes.c_void_p]
dll.luaL_loadstring.argtypes=[ctypes.c_void_p,ctypes.c_char_p]
dll.lua_pcall.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_int]
dll.lua_tolstring.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_void_p]
dll.lua_tolstring.restype=ctypes.c_char_p
dll.lua_close.argtypes=[ctypes.c_void_p]
names=['lll/lifecycle.lua','lll/native.lua','lll/main.lua','lll/lifecycle_test.lua']
before={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in names}
state=dll.luaL_newstate()
assert state
try:
    dll.luaL_openlibs(state)
    code=('HOB_TEST_ROOT='+json.dumps(ROOT.as_posix())+'; dofile(HOB_TEST_ROOT.."/lll/lifecycle_test.lua")').encode()
    result=dll.luaL_loadstring(state,code) or dll.lua_pcall(state,0,0,0)
    if result:raise RuntimeError(dll.lua_tolstring(state,-1,None).decode())
finally:dll.lua_close(state)
assert before=={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in names}
out=ROOT.parent/'dist'/'releases'/'hob-native-loader-fixture'
out.mkdir(parents=True,exist_ok=True)
(out/'verification.json').write_text(json.dumps({'source_sha256':before,'lua_runtime_sha256':hashlib.sha256(library.read_bytes()).hexdigest(),'tests':'passed','installed':False,'game_modified':False},indent=2)+'\n')
