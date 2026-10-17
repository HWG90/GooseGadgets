"""Offline BSL package contracts: build, archive identity and the packaged entry in LuaJIT."""
from pathlib import Path
import importlib.util
import io
import json
import struct
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_adapter import literal, native_fixture, run_lua  # noqa: E402


def load_builder():
    spec = importlib.util.spec_from_file_location("bridge_build_bsl", ROOT / "tools" / "build_bsl.py")
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)
    return builder


def lua_path(path: Path) -> str:
    return str(path).replace("\\", "/")


class BSLPackageTests(unittest.TestCase):
    def setUp(self):
        self.builder = load_builder()
        self.folder = tempfile.TemporaryDirectory(prefix="bridge-combat-bsl-")
        self.temp = Path(self.folder.name)
        self.review = self.temp / "review"
        zip_name = self.builder.names(self.builder.version())[0]
        self.builder.names = lambda ver: (zip_name, self.review)
        self.native = self.temp / "production.dll"
        self.native.write_bytes(native_fixture())

    def tearDown(self):
        self.folder.cleanup()

    def build(self):
        return self.builder.build(self.native)

    def test_deterministic_allowlisted_package(self):
        archive = self.build()
        first = archive.read_bytes()
        self.assertEqual(self.build().read_bytes(), first)
        with zipfile.ZipFile(io.BytesIO(first)) as package:
            self.assertEqual(set(package.namelist()), set(self.builder.PACKAGE_FILES))
            self.assertIsNone(package.testzip())
            manifest = json.loads(package.read("manifest.json"))
            self.assertEqual(manifest["Guid"], self.builder.GUID)
            self.assertEqual(manifest["Options"][0]["Include"], ["Addon"])
            self.assertEqual(package.read("MINHOOK-LICENSE.txt"), (ROOT / "native/vendor/minhook/LICENSE.txt").read_bytes())
            resources = self.builder.lua_archive.read(package.read("Addon/" + self.builder.ARCHIVE))
        name_hash = self.builder.lua_archive.hash_name(self.builder.ENTRY)
        self.assertEqual(set(resources), {name_hash})
        kind, envelope = resources[name_hash]
        self.assertEqual(kind, self.builder.lua_archive.LUA_TYPE)
        size, version = struct.unpack_from("<II", envelope)
        startup = envelope[8:]
        self.assertEqual((size, version), (len(startup), 2))
        self.assertEqual(startup, (self.review / self.builder.STARTUP_NAME).read_bytes())
        self.assertTrue(startup.startswith(b"-- HD2-Addon: mods/goose/bridge_combat/startup\n"))
        text = startup.decode("utf-8")
        self.assertIn("'" + self.native.read_bytes().hex() + "'", text)
        for marker in ("-- __MODULES__", "__NATIVE_HEX__", "'__VERSION__'", "'__NATIVE_ASSET__'"):
            self.assertNotIn(marker, text)
        receipt = json.loads((self.review / "build-manifest.json").read_text())
        self.assertEqual(receipt["builder"], self.builder.BUILD_ID)
        self.assertTrue(receipt["native"]["asset"].startswith("runtime/BridgeCombatNative-" + receipt["version"] + "-"))
        self.assertEqual(receipt["native"]["asset"][-16:-4], receipt["native"]["sha256"][:12])

    def test_refuses_missing_or_invalid_native_without_output(self):
        with self.assertRaisesRegex(ValueError, "--native-dll"):
            self.builder.build(None)
        for data in (b"not a PE", native_fixture(self.builder.lll_build.REQUIRED_EXPORTS | {"BC_start_actor_test"}),
                     native_fixture(imports=["VCRUNTIME140.dll"])):
            self.native.write_bytes(data)
            with self.assertRaises(ValueError):
                self.build()
            self.assertFalse(self.review.exists())

    def test_refuses_mismatched_native_receipt(self):
        (self.temp / "native-build-receipt.json").write_text(json.dumps({"sha256": "wrong"}))
        with self.assertRaisesRegex(ValueError, "receipt"):
            self.build()

    def test_refuses_unowned_review_output(self):
        self.review.mkdir()
        (self.review / "foreign.txt").write_text("preserve")
        with self.assertRaisesRegex(ValueError, "unowned"):
            self.build()
        self.assertEqual((self.review / "foreign.txt").read_text(), "preserve")
        with self.assertRaises(ValueError):
            self.builder.build(self.native, self.temp / "elsewhere")

    def test_module_contracts(self):
        prefix = "BRIDGE_COMBAT_TEST_ROOT=" + literal(lua_path(ROOT)) + "\n"
        for name in ("bindings_fixture.lua", "options_fixture.lua"):
            run_lua(prefix + (ROOT / "tests" / name).read_text(encoding="utf-8"))

    def test_packaged_entry_contracts(self):
        self.build()
        appdata = self.temp / "appdata"
        appdata.mkdir()
        prefix = "".join(name + "=" + literal(lua_path(value)) + "\n" for name, value in (
            ("BSL_STARTUP", self.review / self.builder.STARTUP_NAME), ("BSL_TEMP", appdata), ("BSL_NATIVE", self.native)))
        run_lua(prefix + (ROOT / "tests" / "bsl.lua").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
