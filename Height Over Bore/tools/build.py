"""Build the allowlisted HOB review package; never install or publish it."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.1.0-experimental"
FILES = (
    "main.lua", "manifest.json", "config/defaults.cfg", "README.md", "LICENSE",
    "src/memory.lua", "src/backend.lua", "src/controller.lua", "src/mcm.lua",
)
MODULES = {"src/memory.lua", "src/backend.lua", "src/controller.lua", "src/mcm.lua"}
REVIEW = ROOT / "dist" / "releases" / "hob-0.1.0-lll-review"


def validate_manifest(manifest: dict) -> None:
    if not isinstance(manifest, dict):
        raise ValueError("Manifest must be an object")
    identity = manifest.get("id")
    if identity != "goose_hob":
        raise ValueError("Manifest id must be goose_hob")
    if manifest.get("version") != VERSION:
        raise ValueError("HOB review version must be " + VERSION)
    lll = manifest.get("lll")
    if not isinstance(lll, dict) or not isinstance(lll.get("modules"), list):
        raise ValueError("Manifest must declare its LLL modules")
    if lll.get("entry") != "main.lua" or lll.get("defaults") != "config/defaults.cfg":
        raise ValueError("Manifest entry/defaults differ from the HOB allowlist")
    modules = lll["modules"]
    if len(modules) != len(MODULES) or not all(isinstance(m, str) for m in modules) or set(modules) != MODULES:
        raise ValueError("Manifest modules differ from the HOB allowlist")
    if "native" in manifest:
        raise ValueError("The HOB package must not contain a native helper")


def build(output: Path | str | None = None) -> Path:
    root = ROOT.resolve()
    payload = {}
    for name in FILES:
        source = ROOT / name
        if not source.resolve().is_relative_to(root) or not source.is_file():
            raise ValueError("Missing or redirected allowlisted source: " + name)
        payload[name] = source.read_bytes()
    manifest = json.loads(payload["manifest.json"].decode("utf-8"))
    validate_manifest(manifest)
    review = REVIEW.resolve()
    output = Path(output).resolve() if output is not None else review
    if not output.is_relative_to(review):
        raise ValueError("Output must stay inside the named HOB review directory")
    folder = output / manifest["id"]
    if folder.exists():
        for file in folder.rglob("*"):
            if file.is_file():
                name = file.relative_to(folder).as_posix()
                if name not in payload or not file.resolve().is_relative_to(folder.resolve()):
                    raise ValueError("Review folder contains an unowned file: " + name)
    # Validate every source and output before writing any payload.
    for name in FILES:
        target = folder / name
        if not target.resolve().is_relative_to(output):
            raise ValueError("Review destination is redirected outside its output")
    output.mkdir(parents=True, exist_ok=True)
    for name, data in payload.items():
        target = folder / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    archive = output / ("HOB-" + VERSION + "-LLL.zip")
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as package:
        for name in FILES:
            entry = zipfile.ZipInfo(manifest["id"] + "/" + name, (1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            package.writestr(entry, payload[name])
    archive_hash = hashlib.sha256(archive.read_bytes()).hexdigest()
    records = {name: hashlib.sha256(data).hexdigest() for name, data in payload.items()}
    receipt = {
        "id": manifest["id"], "version": VERSION, "archive": archive.name,
        "sha256": archive_hash, "files": records,
        "state": "review candidate; not installed, published, or live-proven",
    }
    (output / "build-manifest.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    (output / "SHA256SUMS.txt").write_text(archive_hash + "  " + archive.name + "\n", encoding="ascii")
    with zipfile.ZipFile(archive) as package:
        expected = {manifest["id"] + "/" + name for name in FILES}
        if set(package.namelist()) != expected or package.testzip() is not None:
            raise ValueError("Saved archive failed allowlist/integrity verification")
        for name, data in payload.items():
            if package.read(manifest["id"] + "/" + name) != data:
                raise ValueError("Saved archive differs from source: " + name)
    return archive


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Optional subdirectory inside the named review folder")
    args = parser.parse_args()
    print(build(args.output))
