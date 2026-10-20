"""Run isolated Lua controller/lifecycle fixtures and package allowlist checks."""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DLL = Path(r"C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2\bin\lua51.dll")


def run_lua(dll_path: Path) -> int:
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
        raise ValueError("Could not create an isolated LuaJIT state")
    try:
        lua.luaL_openlibs(state)
        value = ROOT.as_posix().encode("utf-8")
        lua.lua_pushlstring(state, value, len(value))
        lua.lua_setfield(state, -10002, b"NATIVE_ADS_TEST_ROOT")
        syntax = b"""assert(jit and jit.version); require('ffi'); require('bit')
local files = {'main.lua', 'src/backend.lua', 'src/profile.lua', 'src/controller.lua', 'src/menu.lua', 'src/alignment.lua', 'src/pose.lua', 'src/placement_editor.lua', 'src/fov.lua', 'src/camera.lua', 'src/motion.lua', 'src/locomotion.lua', 'src/motion_runtime.lua', 'src/action_state.lua', 'src/camera_compat.lua', 'src/head_visibility.lua', 'src/first_person_movement.lua', 'src/blur.lua', 'src/dof.lua', 'src/action_placement.lua', 'src/fird_person.lua', 'src/skinned_placement.lua', 'src/support_hand.lua', 'src/head_placement.lua'}
for _, path in ipairs(files) do assert(loadfile(NATIVE_ADS_TEST_ROOT .. '/' .. path)) end
print('Native ADS runtime source compilation: ' .. #files .. ' passed')
"""
        status = lua.luaL_loadstring(state, syntax) or lua.lua_pcall(state, 0, 0, 0)
        for name in ("head_placement.lua", "support_hand.lua", "skinned_placement.lua", "fird_person.lua", "action_placement.lua", "clock.lua", "runtime_frame.lua", "controller.lua", "backend.lua", "pose_adapter.lua", "editor.lua", "menu.lua", "fov.lua", "camera.lua", "motion.lua", "locomotion.lua", "motion_runtime.lua", "action_state.lua", "camera_compat.lua", "head_visibility.lua", "first_person_movement.lua", "blur.lua", "dof.lua"):
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


class Packaging(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("native_ads_builder", ROOT / "tools" / "build.py")
        cls.builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.builder)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="native-ads-package-")
        self.base = Path(self.temp.name)
        self.source, self.output = self.base / "source", self.base / "review"
        self.old_root, self.old_review = self.builder.ROOT, self.builder.REVIEW
        self.builder.ROOT, self.builder.REVIEW = self.source, self.output
        self.manifest = {"id": self.builder.IDENTITY, "version": self.builder.VERSION,
                         "lll": {"entry": "main.lua", "defaults": "config/defaults.cfg", "modules": sorted(self.builder.MODULES), "retain_until_exit": True}}
        for name in self.builder.FILES:
            path = self.source / self.builder.SOURCES.get(name,name)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(("fixture for " + name + "\n").encode())
        self.write_manifest()

    def tearDown(self):
        self.builder.ROOT, self.builder.REVIEW = self.old_root, self.old_review
        self.temp.cleanup()

    def write_manifest(self):
        (self.source / "manifest.json").write_text(json.dumps(self.manifest), encoding="utf-8")

    def test_allowlist_receipt_and_reproducibility(self):
        (self.source / "private-research.bin").write_bytes(b"must not ship")
        archive = self.builder.build()
        first = archive.read_bytes()
        receipt = json.loads((self.output / "build-manifest.json").read_text())
        self.assertEqual(receipt["sha256"], hashlib.sha256(first).hexdigest())
        with zipfile.ZipFile(archive) as package:
            self.assertEqual(set(package.namelist()), {self.builder.IDENTITY + "/" + f for f in self.builder.FILES})
            for name, digest in receipt["files"].items():
                self.assertEqual(hashlib.sha256(package.read(self.builder.IDENTITY + "/" + name)).hexdigest(), digest)
        self.assertEqual(self.builder.build().read_bytes(), first)

    def test_invalid_manifest_refuses_before_writes(self):
        for key, value in (("id", "../other"), ("version", "future"), ("native", {})):
            original = self.manifest.copy()
            self.manifest[key] = value
            self.write_manifest()
            with self.assertRaises(ValueError): self.builder.build()
            self.assertFalse(self.output.exists())
            self.manifest = original
        self.manifest["lll"]["modules"].append("../private.lua")
        self.write_manifest()
        with self.assertRaises(ValueError): self.builder.build()
        self.assertFalse(self.output.exists())

    def test_unowned_output_file_preserved(self):
        unknown = self.output / self.builder.IDENTITY / "saved-setting.txt"
        unknown.parent.mkdir(parents=True)
        unknown.write_text("preserve")
        with self.assertRaises(ValueError): self.builder.build()
        self.assertEqual(unknown.read_text(), "preserve")
        self.assertFalse((unknown.parent / "main.lua").exists())

    def test_output_cannot_leave_named_review(self):
        outside = self.base / "installed"
        with self.assertRaises(ValueError): self.builder.build(outside)
        self.assertFalse(outside.exists())

    def test_missing_source_refuses_before_output(self):
        (self.source / "src" / "controller.lua").unlink()
        with self.assertRaises(ValueError): self.builder.build()
        self.assertFalse(self.output.exists())

    def test_current_manifest_matches_builder(self):
        self.builder.validate_manifest(json.loads((self.old_root / "manifest.json").read_text(encoding="utf-8")))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dll", type=Path, default=Path(os.environ.get("DBF_LUA_DLL", DEFAULT_DLL)))
    args = parser.parse_args()
    # This separate interpreter has no game handle. All controller/backend state
    # and all native entry/exit acknowledgements in these tests are fixtures.
    lua_result = run_lua(args.dll)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Packaging))
    return 0 if lua_result == 0 and result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
