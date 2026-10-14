"""Check standalone BSL bytes and output ownership without loading the game."""
from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]


class BSLPackaging(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("hob_bsl_builder_tests", ROOT / "tools" / "build_bsl.py")
        cls.builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.builder)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hob-bsl-package-contract-")
        self.base = Path(self.temp.name)
        self.source, self.output = self.base / "hob", self.base / "review"
        self.old_root, self.old_review = self.builder.ROOT, self.builder.REVIEW
        self.builder.ROOT, self.builder.REVIEW = self.source, self.output
        self.files = {}
        for name in self.builder.SOURCE_FILES:
            body = ("-- fixture for " + name + "\nreturn {}\n").encode() if name.endswith(".lua") else ("fixture for " + name + "\n").encode()
            self.write(name, body)
        self.template = ("-- HD2-Addon: " + self.builder.ENTRY + "\n"
                         "local mod={version='__VERSION__'}\nlocal factories={}\n"
                         "-- __MODULES__\nreturn mod\n").encode()
        self.write("bsl/startup.lua", self.template)

    def tearDown(self):
        self.builder.ROOT, self.builder.REVIEW = self.old_root, self.old_review
        self.temp.cleanup()

    def write(self, name, body):
        target = self.source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(body)
        self.files[name] = body

    def snapshot(self):
        return {path.relative_to(self.output).as_posix(): path.read_bytes()
                for path in self.output.rglob("*") if path.is_file()}

    def test_zip_archive_header_allowlist_and_version(self):
        for name in ("main.lua", "manifest.json", "src/mcm.lua", "private-research.txt", "settings.ini"):
            self.write(name, b"private/unrelated contents must not ship\n")
        archive = self.builder.build()
        self.assertEqual(archive.name, "HOB-0.1.0-experimental-BSL.zip")
        with zipfile.ZipFile(archive) as package:
            self.assertEqual(len(package.namelist()), len(self.builder.PACKAGE_FILES))
            self.assertEqual(set(package.namelist()), set(self.builder.PACKAGE_FILES))
            self.assertIsNone(package.testzip())
            manifest = json.loads(package.read("manifest.json"))
            self.assertEqual(manifest["Version"], 1)
            self.assertEqual(manifest["Guid"], self.builder.GUID)
            self.assertEqual(manifest["Author"], "Goose")
            self.assertIn(self.builder.VERSION, manifest["Name"])
            self.assertEqual(manifest["Options"][0]["Include"], ["Addon"])
            for suffix in (".stream", ".gpu_resources"):
                self.assertEqual(package.read("Addon/" + self.builder.ARCHIVE + suffix), b"")
            entries = self.builder.lua_archive.read(package.read("Addon/" + self.builder.ARCHIVE))
            key = self.builder.lua_archive.hash_name(self.builder.ENTRY)
            self.assertEqual(set(entries), {key})
            kind, envelope = entries[key]
            self.assertEqual(kind, 0xA14E8DFA2CD117E2)
            length, version = struct.unpack_from("<II", envelope)
            self.assertEqual(version, 2)
            startup = envelope[8:]
            self.assertEqual(length, len(startup))
            self.assertTrue(startup.startswith(("-- HD2-Addon: " + self.builder.ENTRY + "\n").encode()))
            self.assertIn(("version='" + self.builder.VERSION + "'").encode(), startup)
            self.assertNotIn(b"__MODULES__", startup)
            self.assertNotIn(b"__VERSION__", startup)
            self.assertNotIn(b"src/mcm.lua", startup)
            self.assertNotIn(b"private/unrelated", startup)
            for name in self.builder.MODULES:
                self.assertIn(("factories['" + name + "']=function()\n").encode() + self.files[name] + b"\nend", startup)
            self.assertEqual(package.read("README-BSL.md"), self.files["BSL-README.md"])
            self.assertEqual(package.read("LICENSE"), self.files["LICENSE"])
            self.assertEqual((self.output / "HOB-BSL-startup.lua").read_bytes(), startup)

    def test_hash_receipts_and_reproducibility(self):
        archive = self.builder.build()
        first = self.snapshot()
        receipt = json.loads(first["build-manifest.json"])
        digest = hashlib.sha256(first[archive.name]).hexdigest()
        self.assertEqual(receipt["builder"], self.builder.BUILD_ID)
        self.assertEqual(receipt["version"], self.builder.VERSION)
        self.assertEqual(receipt["sha256"], digest)
        self.assertEqual(first["SHA256SUMS.txt"], (digest + "  " + archive.name + "\n").encode())
        self.assertEqual(receipt["startup_sha256"], hashlib.sha256(first["HOB-BSL-startup.lua"]).hexdigest())
        self.assertEqual(set(receipt["source_files"]), set(self.builder.SOURCE_FILES))
        for name, value in receipt["source_files"].items():
            self.assertEqual(value, hashlib.sha256(self.files[name]).hexdigest())
        with zipfile.ZipFile(archive) as package:
            self.assertEqual(set(receipt["package_files"]), set(package.namelist()))
            for name, value in receipt["package_files"].items():
                self.assertEqual(value, hashlib.sha256(package.read(name)).hexdigest())
            for item in package.infolist():
                self.assertEqual(item.date_time, (1980, 1, 1, 0, 0, 0))
                self.assertEqual(item.create_system, 3)
                self.assertEqual(item.external_attr >> 16, 0o100644)
        self.builder.build()
        self.assertEqual(self.snapshot(), first)

    def test_discovery_header_and_markers_refuse_before_writes(self):
        invalid = (b"\xef\xbb\xbf" + self.template,
                   b" " + self.template,
                   self.template.replace(self.builder.ENTRY.encode(), b"mods/other/hob/startup"),
                   self.template.replace(b"-- __MODULES__", b"-- no factories"),
                   self.template.replace(b"__VERSION__", b"future"),
                   self.template + b"-- __MODULES__\n")
        for body in invalid:
            with self.subTest(body=body[:80]):
                self.write("bsl/startup.lua", body)
                with self.assertRaises(ValueError):
                    self.builder.build()
                self.assertFalse(self.output.exists())

    def test_missing_source_preserves_existing_outputs(self):
        self.builder.build()
        first = self.snapshot()
        (self.source / "src/controller.lua").unlink()
        with self.assertRaises(ValueError):
            self.builder.build()
        self.assertEqual(self.snapshot(), first)

    def test_nonplaintext_module_refuses_before_writes(self):
        self.write("src/options.lua", b"\x1bLJ\0bytecode")
        with self.assertRaises(ValueError):
            self.builder.build()
        self.assertFalse(self.output.exists())

    def test_unowned_output_preserved_before_any_writes(self):
        self.builder.build()
        unknown = self.output / "saved-user-setting.txt"
        unknown.write_bytes(b"preserve\n")
        first = self.snapshot()
        self.write("src/controller.lua", b"return {changed=true}\n")
        with self.assertRaises(ValueError):
            self.builder.build()
        self.assertEqual(self.snapshot(), first)

    def test_similarly_named_unowned_file_is_preserved(self):
        self.output.mkdir()
        unknown = self.output / self.builder.ZIP_NAME
        unknown.write_bytes(b"user file without builder ownership\n")
        first = self.snapshot()
        with self.assertRaises(ValueError):
            self.builder.build()
        self.assertEqual(self.snapshot(), first)

    def test_wrong_ownership_receipt_preserves_existing_outputs(self):
        self.builder.build()
        receipt = self.output / "build-manifest.json"
        receipt.write_text('{"builder":"another-builder"}\n', encoding="utf-8")
        first = self.snapshot()
        with self.assertRaises(ValueError):
            self.builder.build()
        self.assertEqual(self.snapshot(), first)

    def test_output_cannot_leave_review(self):
        outside = self.base / "installed"
        with self.assertRaises(ValueError):
            self.builder.build(outside)
        self.assertFalse(outside.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
