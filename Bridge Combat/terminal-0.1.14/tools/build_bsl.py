"""Build the self-contained BSL Bridge Combat 0.1.14 review ZIP; never install or publish it.

Modules are taken byte-for-byte from the validated LLL review build so the BSL
variant runs the same tested sources; the native helper is revalidated through
the accepted immutable receipt before embedding.
"""
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

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
COMPAT = ROOT / "compat" / "lll-0.1.14"
LLL_REVIEW = ROOT / "dist" / "releases" / "bridge-combat-0.1.14-experimental-review"
ENTRY = "mods/goose/bridge_combat_014/startup"
GUID = "3d9b4a1f-7c52-4e6a-8b31-9f0d2c5a6e84"
ARCHIVE = "9ba626afa44a3aa3.patch_0"
EXTRA_MODULES = ("bsl/mcm_bridge.lua", "bsl/render_bridge.lua")
PACKAGE_FILES = ("manifest.json", "Addon/" + ARCHIVE, "Addon/" + ARCHIVE + ".stream",
                 "Addon/" + ARCHIVE + ".gpu_resources", "README-BSL.md", "LICENSE", "TERMINAL-ICONS.md")
STARTUP_NAME = "BridgeCombat-0.1.14-BSL-startup.lua"
BUILD_ID = "bridge-combat-014-bsl-v1"
VERSION = "0.1.14-experimental"


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


lua_archive = _load("bridge_combat_lua_archive", HERE / "lua_archive.py")
lll_build = _load("bridge_combat_lll_build_014", COMPAT / "build.py")


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def json_bytes(value: dict) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def read_lll_modules() -> tuple[dict[str, bytes], dict]:
    """Every module byte-identical to the validated LLL review build."""
    manifest = json.loads((LLL_REVIEW / "build-manifest.json").read_text(encoding="utf-8"))
    assert manifest["version"] == VERSION, "LLL review build version differs"
    assert sha256((LLL_REVIEW / manifest["archive"]).read_bytes()) == manifest["sha256"], "LLL archive hash differs"
    module_names = sorted(name for name in manifest["files"] if name.startswith("src/") and name.endswith(".lua"))
    lll_modules = json.loads((LLL_REVIEW / "goose_bridge_combat" / "manifest.json").read_text(encoding="utf-8"))
    assert module_names == sorted(lll_modules["lll"]["modules"]), "LLL module list differs from its manifest"
    folder = LLL_REVIEW / "goose_bridge_combat"
    modules = {name: (folder / name).read_bytes() for name in module_names}
    for name, digest in manifest["files"].items():
        if name in modules:
            assert sha256(modules[name]) == digest, "LLL module differs from its manifest: " + name
    return modules, manifest


def long_string(text: str) -> str:
    level = 0
    while "]" + "=" * level + "]" in text:
        level += 1
    # A leading newline after [[ is discarded by Lua, so preserve the first one.
    return "[" + "=" * level + "[\n" + text + "]" + "=" * level + "]"


def make_startup(sources: dict[str, bytes], native_asset: str, native_body: bytes,
                 native_sha: str, binary_spec: bytes) -> bytes:
    scripts = {}
    for name, body in sources.items():
        if body.startswith((b"\xef\xbb\xbf", b"\x1b")) or b"\0" in body:
            raise ValueError("Lua source must be plaintext UTF-8 without a BOM: " + name)
        scripts[name] = body.decode("utf-8").replace("\r\n", "\n")
    scripts["src/weapon_menu_binary.lua"] = binary_spec.decode("utf-8")
    template = scripts["bsl/startup.lua"]
    header = "-- HD2-Addon: " + ENTRY
    first, separator, _ = template.partition("\n")
    if not separator or first != header or len((first + separator).encode("utf-8")) > 256:
        raise ValueError("BSL startup must begin with its exact discovery declaration")
    for marker in ("-- __MODULES__", "__NATIVE_HEX__", "'__VERSION__'", "'__NATIVE_ASSET__'", "'__NATIVE_SHA256__'"):
        if template.count(marker) != 1:
            raise ValueError("BSL startup template markers differ from the build contract: " + marker)
    names = [name for name in scripts if name != "bsl/startup.lua"]
    modules = "\n".join("sources[" + repr(name) + "]=" + long_string(scripts[name]) for name in sorted(names))
    startup = (template.replace("-- __MODULES__", modules)
               .replace("__NATIVE_HEX__", "'" + native_body.hex() + "'")
               .replace("'__VERSION__'", repr(VERSION))
               .replace("'__NATIVE_ASSET__'", repr(native_asset))
               .replace("'__NATIVE_SHA256__'", repr(native_sha)))
    return startup.encode("utf-8")


def make_package(startup: bytes) -> dict[str, bytes]:
    description = ("Bridge Combat " + VERSION + ". Requires Bingus Shared Loader v15+ / API 1 and the original Mod Options Menu API 1. "
                   "Optional Mod Bindings Menu v3 adds a Toggle Bridge Combat hotkey. Experimental: use your loadout on the Super Destroyer bridge. "
                   "Includes its screen render dispatcher; the full terminal requires standalone DBF-MCM input services.")
    manifest = {"Version": 1, "Guid": str(uuid.UUID(GUID)), "Author": "Goose",
                "Name": "Bridge Combat " + VERSION, "Description": description,
                "Options": [{"Name": "Bridge Combat " + VERSION, "Description": description, "Include": ["Addon"]}]}
    envelope = struct.pack("<II", len(startup), 2) + startup
    name_hash = lua_archive.hash_name(ENTRY)
    archive = lua_archive.write({name_hash: envelope})
    if lua_archive.read(archive) != {name_hash: (lua_archive.LUA_TYPE, envelope)}:
        raise ValueError("BSL Lua archive failed source/type round-trip")
    readme = (ROOT / "bsl" / "BSL-README.md").read_bytes()
    license_body = (ROOT / "LICENSE").read_bytes()
    return {"manifest.json": json_bytes(manifest), "Addon/" + ARCHIVE: archive,
            "Addon/" + ARCHIVE + ".stream": b"", "Addon/" + ARCHIVE + ".gpu_resources": b"",
            "README-BSL.md": readme, "LICENSE": license_body,
            "TERMINAL-ICONS.md": (COMPAT / "TERMINAL-ICONS.md").read_bytes()}


def zip_bytes(payload: dict[str, bytes]) -> bytes:
    if set(payload) != set(PACKAGE_FILES):
        raise ValueError("BSL package differs from its fixed allowlist")
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as package:
        for name, body in sorted(payload.items()):
            entry = zipfile.ZipInfo(name, (2026, 10, 17, 0, 0, 0))
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


def build(native_receipt: Path, output: Path | None = None) -> Path:
    modules, lll_manifest = read_lll_modules()
    native_name, native_body, binary_spec, native = lll_build.native_payload(native_receipt)
    assert native_name == "native/BridgeCombatWeaponMenu-" + native["sha256"][:12] + ".dll"
    assert binary_spec == modules["src/weapon_menu_binary.lua"], "Binary spec differs from the LLL build"
    sources: dict[str, bytes] = dict(modules)
    for name in EXTRA_MODULES:
        source = ROOT / name
        if not source.resolve().is_relative_to(ROOT.resolve()) or not source.is_file():
            raise ValueError("Missing or redirected allowlisted source: " + name)
        sources[name] = source.read_bytes()
    sources["bsl/startup.lua"] = (ROOT / "bsl" / "startup.lua").read_bytes()
    startup = make_startup(sources, native_name, native_body, native["sha256"], binary_spec)
    payload = make_package(startup)
    packed = zip_bytes(payload)
    review = (ROOT / "dist" / "releases" / ("bridge-combat-" + VERSION + "-bsl-review")).resolve()
    destination = (Path(output).resolve() if output is not None else review)
    if not destination.is_relative_to(review):
        raise ValueError("Output must stay inside the named Bridge Combat BSL review directory")
    zip_name = "BridgeCombat-" + VERSION + "-BSL.zip"
    receipt = {"builder": BUILD_ID, "id": "goose_bridge_combat", "version": VERSION,
               "guid": GUID, "entry": ENTRY, "resource_hash": format(lua_archive.hash_name(ENTRY), "016x"),
               "lua_type": format(lua_archive.LUA_TYPE, "016x"), "archive": zip_name,
               "sha256": sha256(packed), "startup_sha256": sha256(startup),
               "native": dict(native, asset=native_name),
               "lll_build": {"archive": lll_manifest["archive"], "sha256": lll_manifest["sha256"]},
               "module_sources": {name: sha256(body) for name, body in sorted(sources.items())},
               "package_files": {name: sha256(body) for name, body in sorted(payload.items())},
               "state": "BSL review candidate; not installed, published, or live-proven",
               "validation": "Deterministic ZIP, allowlist, native receipt/PE checks, LLL module identity, archive round-trip and byte integrity passed"}
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
    parser.add_argument("--native-receipt", type=Path, required=True,
                        help="Accepted immutable weapon-menu DLL receipt")
    parser.add_argument("--output", type=Path, help="Optional subdirectory inside the named BSL review folder")
    parser.add_argument("--lll-review", type=Path, default=LLL_REVIEW, help="Validated LLL build directory")
    args = parser.parse_args()
    LLL_REVIEW = args.lll_review.resolve()
    print(build(args.native_receipt, args.output))
