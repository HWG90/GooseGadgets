"""Build the self-contained BSL Bridge Combat review ZIP; never install or publish it."""
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
ENTRY = "mods/goose/bridge_combat/startup"
GUID = "b5beb699-98e0-450e-81a2-ca25c1775a1d"
ARCHIVE = "9ba626afa44a3aa3.patch_0"
MODULES = ("src/backend.lua", "src/controller.lua", "src/options.lua", "src/bindings.lua")
SOURCE_FILES = ("bsl/startup.lua", *MODULES, "BSL-README.md", "LICENSE", "native/vendor/minhook/LICENSE.txt")
PACKAGE_FILES = ("manifest.json", "Addon/" + ARCHIVE, "Addon/" + ARCHIVE + ".stream",
                 "Addon/" + ARCHIVE + ".gpu_resources", "README-BSL.md", "LICENSE", "MINHOOK-LICENSE.txt")
STARTUP_NAME = "BridgeCombat-BSL-startup.lua"
BUILD_ID = "bridge-combat-bsl-v1"


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


lua_archive = _load("bridge_combat_lua_archive", Path(__file__).with_name("lua_archive.py"))
lll_build = _load("bridge_combat_lll_build", Path(__file__).with_name("build.py"))


def version() -> str:
    manifest = json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("id") != "goose_bridge_combat" or manifest.get("native", {}).get("route") != "actor":
        raise ValueError("manifest.json is not the Bridge Combat actor release")
    return manifest["version"]


def names(ver: str) -> tuple[str, Path]:
    return "BridgeCombat-" + ver + "-BSL.zip", ROOT / "dist" / "releases" / ("bridge-combat-" + ver + "-bsl-review")


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


def read_native(path: Path | str) -> tuple[bytes, dict]:
    """Apply the LLL package's PE/receipt checks to the supplied production helper."""
    path = Path(path).resolve()
    body = path.read_bytes()
    native = lll_build.validate_native(body)
    native.update({"sha256": sha256(body), "route": "actor", "game_timestamp": "6AB3B43F", "exe_timestamp": "6AB382E4"})
    receipt_path = path.parent / "native-build-receipt.json"
    if receipt_path.is_file():
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        if any(receipt.get(key) != native[key] for key in ("sha256", "game_timestamp", "exe_timestamp")):
            raise ValueError("Native build receipt does not match the supplied DLL/build")
        for name, digest in receipt.get("source_sha256", {}).items():
            source = ROOT / name
            if not source.resolve().is_relative_to((ROOT / "native").resolve()) \
                    or not source.is_file() or sha256(source.read_bytes()) != digest:
                raise ValueError("Native source changed after its supplied build: " + name)
        native["source_sha256"] = receipt.get("source_sha256", {})
    return body, native


def long_string(text: str) -> str:
    level = 0
    while "]" + "=" * level + "]" in text:
        level += 1
    # A leading newline after [[ is discarded by Lua, so preserve the first one.
    return "[" + "=" * level + "[\n" + text + "]" + "=" * level + "]"


def make_startup(sources: dict[str, bytes], ver: str, native_asset: str, native_body: bytes) -> bytes:
    scripts = {}
    for name in ("bsl/startup.lua", *MODULES):
        body = sources[name]
        if body.startswith((b"\xef\xbb\xbf", b"\x1b")) or b"\0" in body:
            raise ValueError("Lua source must be plaintext UTF-8 without a BOM: " + name)
        scripts[name] = body.decode("utf-8").replace("\r\n", "\n")
    template = scripts["bsl/startup.lua"]
    header = "-- HD2-Addon: " + ENTRY
    first, separator, _ = template.partition("\n")
    if not separator or first != header or len((first + separator).encode("utf-8")) > 256:
        raise ValueError("BSL startup must begin with its exact discovery declaration")
    for marker in ("-- __MODULES__", "__NATIVE_HEX__", "'__VERSION__'", "'__NATIVE_ASSET__'", "'__NATIVE_SHA256__'"):
        if template.count(marker) != 1:
            raise ValueError("BSL startup template markers differ from the build contract: " + marker)
    modules = "\n".join("sources[" + repr(name) + "]=" + long_string(scripts[name]) for name in MODULES)
    startup = (template.replace("-- __MODULES__", modules)
               .replace("__NATIVE_HEX__", "'" + native_body.hex() + "'")
               .replace("'__VERSION__'", repr(ver))
               .replace("'__NATIVE_ASSET__'", repr(native_asset))
               .replace("'__NATIVE_SHA256__'", repr(sha256(native_body))))
    return startup.encode("utf-8")


def make_package(sources: dict[str, bytes], startup: bytes, ver: str) -> dict[str, bytes]:
    description = ("Bridge Combat " + ver + ". Requires Bingus Shared Loader v15+ / API 1 and the original Mod Options Menu API 1. "
                   "Optional Mod Bindings Menu v3 adds a Toggle Bridge Combat hotkey. Experimental: use your loadout on the Super Destroyer bridge.")
    manifest = {"Version": 1, "Guid": str(uuid.UUID(GUID)), "Author": "Goose",
                "Name": "Bridge Combat " + ver, "Description": description,
                "Options": [{"Name": "Bridge Combat " + ver, "Description": description, "Include": ["Addon"]}]}
    envelope = struct.pack("<II", len(startup), 2) + startup
    name_hash = lua_archive.hash_name(ENTRY)
    archive = lua_archive.write({name_hash: envelope})
    if lua_archive.read(archive) != {name_hash: (lua_archive.LUA_TYPE, envelope)}:
        raise ValueError("BSL Lua archive failed source/type round-trip")
    return {"manifest.json": json_bytes(manifest), "Addon/" + ARCHIVE: archive,
            "Addon/" + ARCHIVE + ".stream": b"", "Addon/" + ARCHIVE + ".gpu_resources": b"",
            "README-BSL.md": sources["BSL-README.md"], "LICENSE": sources["LICENSE"],
            "MINHOOK-LICENSE.txt": sources["native/vendor/minhook/LICENSE.txt"]}


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
        if set(package.namelist()) != set(PACKAGE_FILES) or len(package.namelist()) != len(PACKAGE_FILES):
            raise ValueError("BSL ZIP failed its allowlist check")
        if package.testzip() is not None or any(package.read(name) != body for name, body in payload.items()):
            raise ValueError("BSL ZIP failed its byte/integrity check")
    return result


def validate_output(output: Path | str | None, review: Path, zip_name: str) -> Path:
    review = review.resolve()
    destination = Path(output).resolve() if output is not None else review
    if not destination.is_relative_to(review):
        raise ValueError("Output must stay inside the named Bridge Combat BSL review directory")
    owned = (zip_name, STARTUP_NAME, "build-manifest.json", "SHA256SUMS.txt")
    if destination.exists():
        if not destination.is_dir():
            raise ValueError("Review output must be a directory")
        children = list(destination.iterdir())
        for child in children:
            if child.name not in owned or not child.is_file() or child.is_symlink():
                raise ValueError("Review output contains an unowned entry: " + child.name)
        if children:
            try:
                receipt = json.loads((destination / "build-manifest.json").read_text(encoding="utf-8"))
            except (OSError, ValueError) as why:
                raise ValueError("Existing review output has no valid ownership receipt") from why
            if not isinstance(receipt, dict) or receipt.get("builder") != BUILD_ID \
                    or receipt.get("id") != "goose_bridge_combat" or receipt.get("archive") != zip_name:
                raise ValueError("Existing review output is not owned by this BSL builder")
    return destination


def build(native_dll: Path | str | None = None, output: Path | str | None = None) -> Path:
    if native_dll is None:
        raise ValueError("Supply the production helper explicitly with --native-dll")
    # Complete validation and assemble all bytes before writing any output.
    ver = version()
    zip_name, review = names(ver)
    sources = read_sources()
    native_body, native = read_native(native_dll)
    native_asset = "runtime/BridgeCombatNative-" + ver + "-" + native["sha256"][:12] + ".dll"
    startup = make_startup(sources, ver, native_asset, native_body)
    payload = make_package(sources, startup, ver)
    packed = zip_bytes(payload)
    destination = validate_output(output, review, zip_name)
    native["asset"] = native_asset
    receipt = {"builder": BUILD_ID, "id": "goose_bridge_combat", "version": ver,
               "guid": GUID, "entry": ENTRY, "resource_hash": format(lua_archive.hash_name(ENTRY), "016x"),
               "lua_type": format(lua_archive.LUA_TYPE, "016x"), "archive": zip_name,
               "sha256": sha256(packed), "startup_sha256": sha256(startup), "native": native,
               "source_files": {name: sha256(body) for name, body in sorted(sources.items())},
               "package_files": {name: sha256(body) for name, body in sorted(payload.items())},
               "state": "BSL review candidate; not installed, published, or live-proven",
               "validation": "Deterministic ZIP, allowlist, native PE checks, archive type/header/source round-trip and byte integrity passed"}
    outputs = {zip_name: packed, STARTUP_NAME: startup, "build-manifest.json": json_bytes(receipt),
               "SHA256SUMS.txt": (sha256(packed) + "  " + zip_name + "\n").encode("ascii")}
    destination.mkdir(parents=True, exist_ok=True)
    for name, body in outputs.items():
        (destination / name).write_bytes(body)
    if (destination / zip_name).read_bytes() != packed:
        raise ValueError("Saved BSL ZIP differs from the validated package")
    return destination / zip_name


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native-dll", type=Path, required=True, help="Production AMD64 static-runtime helper to embed")
    parser.add_argument("--output", type=Path, help="Optional subdirectory inside the named BSL review folder")
    args = parser.parse_args()
    print(build(args.native_dll, args.output))
