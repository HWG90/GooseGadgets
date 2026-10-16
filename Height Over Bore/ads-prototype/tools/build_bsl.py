"""Build the self-contained BSL HOB review ZIP; never install or publish it."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.1.1-experimental"
ENTRY = "mods/goose/hob_ads_prototype/startup"
GUID = "171b4e3f-b3a4-43c1-b632-8ad679180ae1"
ARCHIVE = "9ba626afa44a3aa3.patch_0"
ZIP_NAME = "HOB-" + VERSION + "-BSL.zip"
REVIEW = ROOT / "dist" / "releases" / "hob-v0.1.1-experimental-bsl"
MODULES = ("src/memory.lua", "src/backend.lua", "src/controller.lua", "src/options.lua", "src/ads_gate.lua", "src/parameters.lua")
SOURCE_FILES = ("bsl/startup.lua", *MODULES, "BSL-README.md", "LICENSE")
PACKAGE_FILES = ("manifest.json", "Addon/" + ARCHIVE,
                 "Addon/" + ARCHIVE + ".stream", "Addon/" + ARCHIVE + ".gpu_resources",
                 "README-BSL.md", "LICENSE")
OUTPUT_FILES = (ZIP_NAME, "HOB-BSL-startup.lua", "build-manifest.json", "SHA256SUMS.txt")
BUILD_ID = "hob-v0.1.1-experimental-bsl-v1"

# Reuse the original DBF archive writer, copied byte-identically from Epic-LUT.
_spec = importlib.util.spec_from_file_location("hob_bsl_lua_archive", Path(__file__).with_name("lua_archive.py"))
lua_archive = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lua_archive)


def json_bytes(value: dict) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def read_sources() -> dict[str, bytes]:
    root = ROOT.resolve()
    payload = {}
    for name in SOURCE_FILES:
        source = ROOT / name
        if not source.resolve().is_relative_to(root) or not source.is_file():
            raise ValueError("Missing or redirected allowlisted source: " + name)
        payload[name] = source.read_bytes()
    return payload


def make_startup(sources: dict[str, bytes]) -> bytes:
    scripts = {}
    for name in ("bsl/startup.lua", *MODULES):
        body = sources[name]
        if body.startswith((b"\xef\xbb\xbf", b"\x1b")) or b"\0" in body:
            raise ValueError("Lua source must be plaintext UTF-8 without a BOM: " + name)
        scripts[name] = body.decode("utf-8")
    template = scripts["bsl/startup.lua"]
    header = "-- HD2-Addon: " + ENTRY
    first, separator, _ = template.partition("\n")
    if not separator or first.rstrip("\r") != header or len((first + separator).encode("utf-8")) > 256:
        raise ValueError("BSL startup must begin with its exact discovery declaration")
    if template.count("-- __MODULES__") != 1 or "__VERSION__" not in template:
        raise ValueError("BSL startup template markers differ from the build contract")
    factories = "\n".join("factories[" + repr(name) + "]=function()\n" + scripts[name] + "\nend"
                          for name in MODULES)
    startup = template.replace("-- __MODULES__", factories).replace("__VERSION__", VERSION)
    return startup.encode("utf-8")


def make_package(sources: dict[str, bytes], startup: bytes) -> dict[str, bytes]:
    description = ("Height Over Bore " + VERSION + ". Requires Bingus Shared Loader v15+ / API 1. "
                   "Configure Enabled in the original Mod Options Menu. Experimental projectile ADS aiming; hip fire, third-person aiming and beams stay native.")
    manifest = {"Version": 1, "Guid": str(uuid.UUID(GUID)), "Author": "Goose",
                "Name": "Height Over Bore " + VERSION, "Description": description,
                "Options": [{"Name": "Height Over Bore " + VERSION, "Description": description,
                             "Include": ["Addon"]}]}
    envelope = struct.pack("<II", len(startup), 2) + startup
    name_hash = lua_archive.hash_name(ENTRY)
    archive = lua_archive.write({name_hash: envelope})
    if lua_archive.read(archive) != {name_hash: (lua_archive.LUA_TYPE, envelope)}:
        raise ValueError("BSL Lua archive failed source/type round-trip")
    return {"manifest.json": json_bytes(manifest), "Addon/" + ARCHIVE: archive,
            "Addon/" + ARCHIVE + ".stream": b"", "Addon/" + ARCHIVE + ".gpu_resources": b"",
            "README-BSL.md": sources["BSL-README.md"], "LICENSE": sources["LICENSE"]}


def zip_bytes(payload: dict[str, bytes]) -> bytes:
    if set(payload) != set(PACKAGE_FILES):
        raise ValueError("BSL package differs from its fixed allowlist")
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as package:
        for name, body in sorted(payload.items()):
            entry = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            package.writestr(entry, body, compresslevel=9)
    result = buffer.getvalue()
    with zipfile.ZipFile(io.BytesIO(result)) as package:
        if len(package.namelist()) != len(PACKAGE_FILES) or set(package.namelist()) != set(PACKAGE_FILES):
            raise ValueError("BSL ZIP failed its allowlist check")
        if package.testzip() is not None or any(package.read(name) != body for name, body in payload.items()):
            raise ValueError("BSL ZIP failed its byte/integrity check")
    return result


def validate_output(output: Path | str | None) -> Path:
    review = REVIEW.resolve()
    destination = Path(output).resolve() if output is not None else review
    if not destination.is_relative_to(review):
        raise ValueError("Output must stay inside the named HOB BSL review directory")
    if destination.exists():
        if not destination.is_dir():
            raise ValueError("Review output must be a directory")
        for child in destination.iterdir():
            if child.name not in OUTPUT_FILES or not child.is_file() or child.is_symlink():
                raise ValueError("Review output contains an unowned entry: " + child.name)
        # A similarly named user file is not owned until a valid receipt exists.
        if any(destination.iterdir()):
            receipt_path = destination / "build-manifest.json"
            try:
                receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            except (OSError, ValueError) as why:
                raise ValueError("Existing review output has no valid ownership receipt") from why
            if not isinstance(receipt, dict) or receipt.get("builder") != BUILD_ID or receipt.get("id") != "goose_hob_ads_prototype" or receipt.get("archive") != ZIP_NAME:
                raise ValueError("Existing review output is not owned by this BSL builder")
    for name in OUTPUT_FILES:
        target = destination / name
        if not target.resolve().is_relative_to(destination) or target.is_symlink():
            raise ValueError("Review destination is redirected outside its output")
    return destination


def build(output: Path | str | None = None) -> Path:
    # Complete validation and assemble all bytes before writing any output.
    sources = read_sources()
    startup = make_startup(sources)
    payload = make_package(sources, startup)
    packed = zip_bytes(payload)
    destination = validate_output(output)
    receipt = {"builder": BUILD_ID, "id": "goose_hob_ads_prototype", "version": VERSION,
               "guid": GUID, "entry": ENTRY, "resource_hash": format(lua_archive.hash_name(ENTRY), "016x"),
               "lua_type": format(lua_archive.LUA_TYPE, "016x"), "archive": ZIP_NAME,
               "sha256": sha256(packed), "startup_sha256": sha256(startup),
               "source_files": {name: sha256(body) for name, body in sorted(sources.items())},
               "package_files": {name: sha256(body) for name, body in sorted(payload.items())},
               "state": "review candidate; not installed, published, or live-proven",
               "validation": "Deterministic ZIP, allowlist, archive type/header/source round-trip and byte integrity passed"}
    outputs = {ZIP_NAME: packed, "HOB-BSL-startup.lua": startup, "build-manifest.json": json_bytes(receipt),
               "SHA256SUMS.txt": (sha256(packed) + "  " + ZIP_NAME + "\n").encode("ascii")}
    destination.mkdir(parents=True, exist_ok=True)
    for name, body in outputs.items():
        (destination / name).write_bytes(body)
    if (destination / ZIP_NAME).read_bytes() != packed:
        raise ValueError("Saved BSL ZIP differs from the validated package")
    return destination / ZIP_NAME


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Optional subdirectory inside the named BSL review folder")
    args = parser.parse_args()
    print(build(args.output))
