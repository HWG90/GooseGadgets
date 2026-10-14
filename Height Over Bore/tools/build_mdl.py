"""Build an allowlisted standalone MDL review ZIP; never install or publish."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.1.0-experimental"
REVIEW = ROOT / "dist" / "releases" / "hob-0.1.0-mdl-review"
SOURCE_FILES = ("mdl/mod.lua", "manifest.json", "src/memory.lua", "src/backend.lua",
                "src/controller.lua", "src/mcm.lua", "MDL-README.md", "LICENSE")
PACKAGE_FILES = ("mod.lua", "manifest.json", "src/memory.lua", "src/backend.lua",
                 "src/controller.lua", "src/mcm.lua", "README.md", "LICENSE")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def build(output: Path | str | None = None) -> Path:
    root = ROOT.resolve()
    sources = {}
    for name in SOURCE_FILES:
        path = ROOT / name
        if not path.is_file() or not path.resolve().is_relative_to(root):
            raise ValueError("Missing or redirected allowlisted source: " + name)
        sources[name] = path.read_bytes()
    original = json.loads(sources["manifest.json"].decode("utf-8"))
    if original.get("id") != "goose_hob" or original.get("version") != VERSION:
        raise ValueError("Height Over Bore manifest identity/version differs")
    modules = ("src/memory.lua", "src/backend.lua", "src/controller.lua", "src/mcm.lua")
    manifest = {key: original[key] for key in ("id", "name", "author", "version", "description")}
    manifest["mdl"] = {"api": 2, "entry": "mod.lua", "modules": list(modules), "requires": ["DBF-MCM"]}
    payload = dict(zip(PACKAGE_FILES, (sources[name] for name in SOURCE_FILES)))
    payload["manifest.json"] = (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode("utf-8")
    for name in ("mod.lua", *modules):
        text = payload[name]
        if text.startswith((b"\xef\xbb\xbf", b"\x1b")) or b"\0" in text:
            raise ValueError("Lua package source must be plaintext without BOM: " + name)
        text.decode("utf-8")
    review = REVIEW.resolve()
    output = Path(output).resolve() if output is not None else review
    if not output.is_relative_to(review):
        raise ValueError("Output must stay inside the named MDL review directory")
    folder = output / "goose_hob"
    if folder.exists():
        for path in folder.rglob("*"):
            if not path.resolve().is_relative_to(folder.resolve()):
                raise ValueError("Review folder contains a redirected path")
            if path.is_file() and path.relative_to(folder).as_posix() not in payload:
                raise ValueError("Review folder contains an unowned file")
    for name in payload:
        if not (folder / name).resolve().is_relative_to(output):
            raise ValueError("Review destination is redirected")
    output.mkdir(parents=True, exist_ok=True)
    for name, data in payload.items():
        path = folder / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    archive = output / ("HOB-" + VERSION + "-MDL.zip")
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as package:
        for name, data in payload.items():
            entry = zipfile.ZipInfo("goose_hob/" + name, (1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            package.writestr(entry, data)
    with zipfile.ZipFile(archive) as package:
        if set(package.namelist()) != {"goose_hob/" + name for name in payload} or package.testzip() is not None:
            raise ValueError("Saved archive failed allowlist/integrity verification")
        for name, data in payload.items():
            if package.read("goose_hob/" + name) != data:
                raise ValueError("Saved archive differs from payload: " + name)
    archive_hash = digest(archive.read_bytes())
    receipt = {"id": "goose_hob", "version": VERSION, "loader": "MDL API 2", "archive": archive.name,
               "sha256": archive_hash, "files": {name: digest(data) for name, data in payload.items()},
               "sources": {name: digest(data) for name, data in sources.items()},
               "state": "review candidate; not installed, published, or live-proven"}
    (output / "build-manifest.json").write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    (output / "SHA256SUMS.txt").write_text(archive_hash + "  " + archive.name + "\n", encoding="ascii")
    return archive


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Optional subdirectory inside the MDL review directory")
    args = parser.parse_args()
    print(build(args.output))
