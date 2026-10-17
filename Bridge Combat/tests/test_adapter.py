"""Offline LuaJIT tests using the maintained MCM core and stub gameplay controller."""
from pathlib import Path
import ctypes
import hashlib
import importlib.util
import json
import os
import struct
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = Path(r"C:\Users\david\OneDrive\Documents\GitHub\DBF-Suite")
CORE = WORKSPACE / "DBF-MCM" / "src" / "core.lua"
DLL = Path(os.environ.get("LLM_LUA51", r"C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2\bin\lua51.dll"))
LUA = ctypes.CDLL(str(DLL))
LUA.luaL_newstate.restype = ctypes.c_void_p
LUA.luaL_openlibs.argtypes = [ctypes.c_void_p]
LUA.luaL_loadbuffer.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p]
LUA.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
LUA.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
LUA.lua_tolstring.restype = ctypes.c_char_p
LUA.lua_close.argtypes = [ctypes.c_void_p]


def literal(text):
    assert "]====]" not in text
    return "[====[" + text + "]====]"


def run_lua(code):
    state = LUA.luaL_newstate()
    LUA.luaL_openlibs(state)
    data = code.encode("utf-8")
    try:
        result = LUA.luaL_loadbuffer(state, data, len(data), b"@bridge-combat-tests")
        if result == 0:
            result = LUA.lua_pcall(state, 0, 0, 0)
        if result:
            raise AssertionError(LUA.lua_tolstring(state, -1, None).decode(errors="replace"))
    finally:
        LUA.lua_close(state)


def build_module():
    spec = importlib.util.spec_from_file_location("bridge_build", ROOT / "tools" / "build.py")
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)
    return builder


def native_fixture(exports=None, imports=()):
    """Synthetic saved PE headers for parser/package tests; never executable."""
    exports = sorted(exports if exports is not None else build_module().REQUIRED_EXPORTS)
    data = bytearray(0x2400)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 0x80)
    data[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<HH", data, 0x84, 0x8664, 1)
    struct.pack_into("<HH", data, 0x94, 240, 0x2022)
    opt = 0x98
    struct.pack_into("<H", data, opt, 0x20B)
    struct.pack_into("<I", data, opt+60, 0x400)
    struct.pack_into("<I", data, opt+108, 16)
    struct.pack_into("<IIII", data, opt+112, 0x1000, 0x800, 0x1900 if imports else 0, 0x100)
    section = opt+240
    data[section:section+8] = b".text\0\0\0"
    struct.pack_into("<IIII", data, section+8, 0x2000, 0x1000, 0x2000, 0x400)
    struct.pack_into("<I", data, section+36, 0x60000020)
    struct.pack_into("<IIHHIIIIIII", data, 0x400, 0, 0, 0, 0, 0x1450, 1, len(exports), len(exports), 0x1100, 0x1200, 0x1300)
    at = 0x800
    for i, name in enumerate(exports):
        value = name.encode()+b"\0"
        struct.pack_into("<I", data, 0x500+i*4, 0x2100+i*16)
        struct.pack_into("<I", data, 0x600+i*4, at+0xC00)
        struct.pack_into("<H", data, 0x700+i*2, i)
        data[at:at+len(value)] = value
        at += len(value)
    at = 0x1000
    for i, name in enumerate(imports):
        struct.pack_into("<IIIII", data, 0xD00+i*20, 1, 0, 0, at+0xC00, 1)
        value = name.encode()+b"\0"
        data[at:at+len(value)] = value
        at += len(value)
    return bytes(data)


def fixture():
    return "CORE=assert(loadstring(" + literal(CORE.read_text(encoding="utf-8")) + "))()\n" + \
        "ADAPTER=assert(loadstring(" + literal((ROOT / "src/mcm.lua").read_text(encoding="utf-8")) + "))()\n" + \
        "MAIN=" + literal((ROOT / "main.lua").read_text(encoding="utf-8")) + "\n" + r'''
ID='goose_bridge_combat'; stored={}; logs={}; order={}; applied={}; backendCreated=0
local function copy(t)local r={};for k,v in pairs(t or {})do r[k]=v end;return r end
store={load=function(id)return copy(stored[id])end,save=function(id,values)stored[id]=copy(values);return true end}
function provider()return CORE.new(store,function(message)logs[#logs+1]=message end)end
function log(message)logs[#logs+1]=message end
controller={selected=false,updates=0,shutdownReady=true,shutdownThrows=false}
function controller:set_enabled(value)self.selected=value;applied[#applied+1]=value;return true end
function controller:update()self.updates=self.updates+1 end
function controller:status()return self.selected and 'active' or 'disabled' end
function controller:shutdown()
 order[#order+1]='shutdown'
 if self.shutdownThrows then error('native cleanup failed')end
 if not self.shutdownReady then return false,'pending' end
 self.selected=false;order[#order+1]='ack';return true
end
mod={dir='C:/lll/mods/goose_bridge_combat',log=log,require=function(name)
 if name=='src/backend.lua' then return{new=function(log,io,options)backendCreated=backendCreated+1;backendOptions=options;return{}end}end
 if name=='src/controller.lua' then return{new=function(backend)return controller end}end
 if name=='src/mcm.lua' then return ADAPTER end
 error('Unexpected module '..tostring(name))
end}
function loadMain()return assert(loadstring(MAIN))()end
'''


class AdapterTests(unittest.TestCase):
    def check(self, code):
        run_lua(fixture() + "\n" + code)

    def test_default_off_immediate_and_status(self):
        self.check("""
DBFMCM=provider();local menu=ADAPTER.new(controller,log);assert(menu:update())
local record=DBFMCM.mods[ID];assert(record and record.pages[1].require_confirmation==false)
assert(record.controls.enabled.default==false and record.controls.enabled.require_confirmation==false)
assert(record.handle.get('enabled')==false and controller.selected==false)
assert(#applied==1);assert(record.handle.edit('enabled',true));assert(controller.selected==true)
assert(stored[ID].enabled==true);menu:update();assert(#applied==2,'duplicate notification')
menu:refresh_status();assert(record.pages[1].controls[3].label=='Status: active')
assert(menu:shutdown());assert(DBFMCM.mods[ID]==nil)
""")

    def test_saved_value_without_registration_callback(self):
        self.check("""
stored[ID]={enabled=true};DBFMCM=provider();local menu=ADAPTER.new(controller,log)
assert(menu:update());assert(controller.selected==true and #applied==1)
assert(menu:shutdown())
""")

    def test_provider_replacement_and_foreign_registration(self):
        self.check("""
DBFMCM=provider();DBFMCM.register({id='foreign',name='Foreign',pages={{id='general',name='General',controls={}}}})
local menu=ADAPTER.new(controller,log);assert(menu:update());DBFMCM.mods[ID].handle.set('enabled',true)
local old=DBFMCM;DBFMCM=provider();assert(menu:update())
assert(old.mods[ID]==nil and old.mods.foreign,'foreign old registration changed')
assert(DBFMCM.mods[ID] and controller.selected==true);assert(menu:shutdown())
""")

    def test_duplicate_owner_refused(self):
        self.check("""
DBFMCM=provider();local foreign=DBFMCM.register({id=ID,name='Existing Owner',pages={{id='general',name='General',controls={}}}})
local menu=ADAPTER.new(controller,log);assert(not menu:update());assert(#applied==0)
assert(menu:shutdown());assert(DBFMCM.mods[ID].handle==foreign,'unregistered another owner')
""")

    def test_lazy_backend_and_cleanup_ack_before_unregister(self):
        self.check("""
DBFMCM=provider();local life=loadMain();assert(backendCreated==0)
life.on_enable();assert(backendCreated==1 and DBFMCM.mods[ID])
assert(backendOptions.dir==mod.dir and backendOptions.native_asset=='runtime/BridgeCombatNative-0.2.0-experimental.dll' and backendOptions.native_route=='actor')
local handle=DBFMCM.mods[ID].handle;local unregister=handle.unregister
handle.unregister=function()order[#order+1]='unregister';return unregister()end
controller.shutdownReady=false;local ok=life.on_disable();assert(ok==false)
assert(DBFMCM.mods[ID] and DBFMCM.mods[ID].controls.enabled.disabled)
local before=#applied;assert(not pcall(handle.set,'enabled',true));assert(#applied==before)
life.on_update(.016);assert(controller.updates==0,'updated during cleanup')
controller.shutdownReady=true;assert(life.on_cleanup_poll(.016)==true)
assert(DBFMCM.mods[ID]==nil and order[#order-1]=='ack' and order[#order]=='unregister')
""")

    def test_cleanup_error_retains_registration_for_retry(self):
        self.check("""
DBFMCM=provider();local life=loadMain();life.on_enable()
controller.shutdownThrows=true;local ok,why=life.on_disable();assert(ok==false and why:find('native cleanup failed'))
assert(DBFMCM.mods[ID]);controller.shutdownThrows=false;assert(life.on_cleanup_poll()==true)
assert(DBFMCM.mods[ID]==nil)
""")

    def test_mcm_arrives_after_loader_enable(self):
        self.check("""
DBFMCM=nil;local life=loadMain();life.on_enable();life.on_update(.016)
assert(not controller.selected);DBFMCM=provider();life.on_update(.016)
assert(DBFMCM.mods[ID] and not controller.selected);assert(life.on_disable())
""")

    def test_missing_mcm_queues_off_and_restores_saved_intent(self):
        self.check("""
stored[ID]={enabled=true};DBFMCM=provider();local menu=ADAPTER.new(controller,log);menu:update()
assert(controller.selected);local previous=DBFMCM;DBFMCM=nil;menu:update()
assert(not controller.selected and stored[ID].enabled==true,'missing UI did not fail closed')
DBFMCM=previous;menu:update();assert(controller.selected,'saved intent not restored after UI return')
assert(menu:shutdown())
""")

    def test_runtime_lua_syntax(self):
        for file in [ROOT / "main.lua", *sorted((ROOT / "src").glob("*.lua"))]:
            run_lua("assert(loadstring(" + literal(file.read_text(encoding="utf-8")) + "))")

    def test_release_allowlist_and_reproducible_bytes(self):
        builder = build_module()
        with tempfile.TemporaryDirectory(prefix="bridge-combat-test-") as folder:
            native = Path(folder) / "production.dll"
            native.write_bytes(native_fixture())
            archive = builder.build(folder, native)
            first = archive.read_bytes()
            with zipfile.ZipFile(archive) as package:
                expected = {"goose_bridge_combat/" + file
                            for file in (*builder.FILES, *builder.NOTICES, builder.NATIVE_ASSET, builder.NATIVE_RECEIPT)}
                self.assertEqual(set(package.namelist()), expected)
                for file in builder.FILES:
                    self.assertEqual(package.read("goose_bridge_combat/" + file), (ROOT / file).read_bytes())
                for name, source in builder.NOTICES.items():
                    self.assertEqual(package.read("goose_bridge_combat/" + name), (ROOT / source).read_bytes())
                self.assertEqual(package.read("goose_bridge_combat/" + builder.NATIVE_ASSET), native.read_bytes())
                proof = json.loads(package.read("goose_bridge_combat/" + builder.NATIVE_RECEIPT))
                self.assertEqual(proof["sha256"], hashlib.sha256(native.read_bytes()).hexdigest())
                self.assertEqual(proof["route"], "actor")
            record = json.loads((Path(folder) / "build-manifest.json").read_text())
            self.assertEqual(record["sha256"], hashlib.sha256(first).hexdigest())
            self.assertFalse(any("tests" in file or "tools" in file for file in record["files"]))
            self.assertEqual(json.loads((ROOT / "config/defaults.cfg").read_text())["enabled"], False)
            self.assertEqual(builder.build(folder, native).read_bytes(), first)

    def test_native_package_refuses_missing_test_and_dynamic_runtime_helpers(self):
        builder = build_module()
        with tempfile.TemporaryDirectory(prefix="bridge-native-refusal-") as folder:
            native = Path(folder) / "candidate.dll"
            with self.assertRaisesRegex(ValueError, "--native-dll"):
                builder.build(folder)
            variants = [b"not a PE", native_fixture(builder.REQUIRED_EXPORTS - {"BC_start_actor"}),
                        native_fixture(builder.REQUIRED_EXPORTS | {"BC_start_actor_test"}),
                        native_fixture(imports=["VCRUNTIME140.dll"])]
            for data in variants:
                native.write_bytes(data)
                with self.assertRaises(ValueError):
                    builder.build(folder, native)
                self.assertFalse((Path(folder) / "goose_bridge_combat").exists())

    def test_native_receipt_and_unknown_output_files_refuse_packaging(self):
        builder = build_module()
        with tempfile.TemporaryDirectory(prefix="bridge-native-receipt-") as folder:
            native = Path(folder) / "candidate.dll"
            native.write_bytes(native_fixture())
            receipt = Path(folder) / "native-build-receipt.json"
            receipt.write_text(json.dumps({"sha256": "wrong"}))
            with self.assertRaisesRegex(ValueError, "receipt"):
                builder.build(folder, native)
            receipt.unlink()
            target = Path(folder) / "goose_bridge_combat"
            target.mkdir()
            (target / "foreign.txt").write_text("preserve")
            with self.assertRaisesRegex(ValueError, "allowlist"):
                builder.build(folder, native)
            self.assertEqual((target / "foreign.txt").read_text(), "preserve")


if __name__ == "__main__":
    unittest.main(verbosity=2)
