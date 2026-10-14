"""Run isolated MDL lifecycle and deterministic allowlisted package checks."""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class Package(unittest.TestCase):
    def setUp(self):
        self.builder = module("hob_mdl_builder", ROOT / "tools/build_mdl.py")
        self.temp = tempfile.TemporaryDirectory(prefix="hob-mdl-fixture-")
        self.base = Path(self.temp.name)
        self.builder.REVIEW = self.base / "review"

    def tearDown(self):
        self.temp.cleanup()

    def test_allowlist_selfcontained_and_reproducible(self):
        archive = self.builder.build()
        original = archive.read_bytes()
        self.assertEqual(self.builder.build().read_bytes(), original)
        with zipfile.ZipFile(archive) as package:
            self.assertEqual(set(package.namelist()), {"goose_hob/" + name for name in self.builder.PACKAGE_FILES})
            manifest = json.loads(package.read("goose_hob/manifest.json"))
            self.assertNotIn("lll", manifest)
            self.assertEqual(manifest["mdl"]["api"], 2)
            for name in manifest["mdl"]["modules"]:
                self.assertEqual(package.read("goose_hob/" + name), (ROOT / name).read_bytes())
            for name in package.namelist():
                data = package.read(name)
                self.assertNotIn(b"C:\\Users\\david", data)
                self.assertNotIn(b"LinksLinkToMemory", data)

    def test_unknown_output_preserved(self):
        file = self.builder.REVIEW / "goose_hob/user.cfg"
        file.parent.mkdir(parents=True)
        file.write_text("preserve")
        with self.assertRaises(ValueError):
            self.builder.build()
        self.assertEqual(file.read_text(), "preserve")
        self.assertFalse((file.parent / "mod.lua").exists())

    def test_output_cannot_escape_review(self):
        with self.assertRaises(ValueError):
            self.builder.build(self.base / "installed")
        self.assertFalse((self.base / "installed").exists())


if __name__ == "__main__":
    runner = module("hob_existing_runner", ROOT / "tests/run_tests.py")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dll", type=Path, default=runner.DEFAULT_DLL)
    args = parser.parse_args()
    status = runner.run_lua(args.dll, ("mdl.lua",))
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Package))
    raise SystemExit(0 if status == 0 and result.wasSuccessful() else 1)
