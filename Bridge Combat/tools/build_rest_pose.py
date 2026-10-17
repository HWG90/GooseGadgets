"""Export authored rest matrices with the pinned Photo Mode decoder, offline only."""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PHOTO = Path(r"C:\Users\david\OneDrive\Documents\GitHub\DBF_PhotoMode")
DECODER_SHA = "c6161ffcd3ce96666c88890d93dfd8410a119466a8e55f4748b6264020b15ca2"
RESOURCES = {
    "unit": ("4d1c334d294dfa97.e0a48d0be9a7453f.bin", "cb7273778c6b5d8771376c75b5fb021eda233062eca5773a539adfdf21de67bd"),
    "bones": ("4d1c334d294dfa97.18dead01056b72e9.bin", "36441822f5420de9a38683b95438a80f9e47fc78b7a8245f156e91e9ae716081"),
}
EXTENSION = r'''
function Clip.rest_export(folder)
 local resources={}
 for _,key in ipairs({'unit','bones'})do
  local f=assert(io.open(folder..'/'..Clip.FILES[key],'rb'))
  resources[key]=f:read(Clip.MAX_BYTES+1);f:close()
  assert(#resources[key]<=Clip.MAX_BYTES,'Rest resource size bound')
 end
 local names,hashes=bones(resources.bones);local nodes=rig(resources.unit,names,hashes)
 local out={string.format('R\t%d\t%d',#nodes,#names)}
 for i,node in ipairs(nodes)do
  local values={};for _,j in ipairs({1,2,3,5,6,7,9,10,11,13,14,15})do values[#values+1]=string.format('%.17g',node.rest[j])end
  out[#out+1]=table.concat({'N',i,node.parent,node.bone or 0,node.name or '',table.concat(values,',')},'\t')
 end
 return table.concat(out,'\n')
end
return Clip
'''


def lua_result(source: bytes, dll: Path) -> str:
    # This LuaJIT interpreter belongs to this Python process, never the game.
    directory = os.add_dll_directory(str(dll.parent))
    lua = ctypes.CDLL(str(dll))
    lua.luaL_newstate.restype = ctypes.c_void_p
    lua.luaL_openlibs.argtypes = [ctypes.c_void_p]
    lua.luaL_loadbuffer.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p]
    lua.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
    lua.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
    lua.lua_tolstring.restype = ctypes.c_void_p
    lua.lua_close.argtypes = [ctypes.c_void_p]
    state = lua.luaL_newstate()
    assert state, "Cannot create isolated Lua state"
    try:
        lua.luaL_openlibs(state)
        status = lua.luaL_loadbuffer(state, source, len(source), b"bridge-authored-rest-export")
        if not status:
            status = lua.lua_pcall(state, 0, 1, 0)
        size = ctypes.c_size_t()
        at = lua.lua_tolstring(state, -1, ctypes.byref(size))
        result = ctypes.string_at(at, size.value).decode() if at else ""
        assert status == 0, result
        return result
    finally:
        lua.lua_close(state)
        directory.close()


def build(decoder: Path, cache: Path, dll: Path, output: Path) -> dict:
    source = decoder.read_bytes()
    assert hashlib.sha256(source).hexdigest() == DECODER_SHA, "Pinned maintained decoder differs"
    for _, (name, expected) in RESOURCES.items():
        assert hashlib.sha256((cache / name).read_bytes()).hexdigest() == expected, "Authored resource identity differs: " + name
    text = source.decode().replace("\r\n", "\n")
    assert text.endswith("return Clip\n")
    text = text[:-len("return Clip\n")] + EXTENSION
    chunk = ("if jit then jit.off() end\nlocal Clip=(function()\n" + text + "\nend)()\nreturn Clip.rest_export(" + json.dumps(cache.resolve().as_posix()) + ")").encode()
    exported = lua_result(chunk, dll)
    nodes = []
    rows = exported.splitlines()
    assert rows[0].split("\t") == ["R", "107", "90"], "Authored rig layout differs"
    for row in rows[1:]:
        kind, index, parent, bone, name, values = row.split("\t")
        assert kind == "N" and int(index) == len(nodes)+1
        assert 0 <= int(parent) < int(index) and 0 <= int(bone) <= 90
        pose = [float(v) for v in values.split(",")]
        assert len(pose) == 12 and all(math.isfinite(v) and abs(v) < 1e8 for v in pose)
        assert not name or name.replace("_", "").isalnum()
        nodes.append({"parent": int(parent), "bone": int(bone), "name": name or None, "pose": pose})
    assert len(nodes) == 107 and sum(bool(n["name"]) for n in nodes) == 90
    lines = ["-- Offline authored rest data; review-only, not a runtime package asset.",
             "return {version=1,resource='4d1c334d294dfa97',node_count=107,bone_count=90,nodes={"]
    for node in nodes:
        name = ",name=" + json.dumps(node["name"]) if node["name"] else ""
        numbers = ",".join(format(v, ".17g") for v in node["pose"])
        lines.append("{parent=%d,bone=%d%s,pose={%s}}," % (node["parent"], node["bone"], name, numbers))
    lines.append("}}")
    encoded = ("\n".join(lines)+"\n").encode()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(encoded)
    receipt = {"status": "offline review candidate; not installed or live tested", "output": str(output),
               "sha256": hashlib.sha256(encoded).hexdigest(), "nodes": 107, "bones": 90,
               "mutable_nodes": [9, 92], "decoder": str(decoder), "decoder_sha256": DECODER_SHA,
               "resources": {name: sha for name, sha in RESOURCES.values()}}
    output.with_suffix(".json").write_text(json.dumps(receipt, indent=2)+"\n", encoding="utf-8")
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--decoder", type=Path, default=PHOTO / "tools/subject_pose_decoder.lua")
    parser.add_argument("--cache", type=Path, default=PHOTO / "dist/review/all-emotes-096/cache")
    parser.add_argument("--dll", type=Path, default=Path(r"C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2\bin\lua51.dll"))
    parser.add_argument("--output", type=Path, default=ROOT.parent / "dist/releases/bridge-rest-pose-review/authored_rest_pose.lua")
    args = parser.parse_args()
    print(json.dumps(build(args.decoder, args.cache, args.dll, args.output), indent=2))
