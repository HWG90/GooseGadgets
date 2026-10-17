"""Build the standalone LLL package without installation or publication."""
from pathlib import Path
import argparse
import hashlib
import json
import struct
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FILES = ("main.lua", "manifest.json", "config/defaults.cfg", "README.md", "LICENSE",
         "src/backend.lua", "src/controller.lua", "src/mcm.lua")
NOTICES = {"MINHOOK-LICENSE.txt": "native/vendor/minhook/LICENSE.txt"}
NATIVE_ASSET = "runtime/BridgeCombatNative-0.2.0-experimental.dll"
NATIVE_RECEIPT = "runtime/BridgeCombatNative-0.2.0-experimental.json"
REQUIRED_EXPORTS = {"BC_start", "BC_start_actor", "BC_tick", "BC_stop", "BC_status", "BC_ready", "BC_error"}


def validate_native(data):
    """Inspect the supplied DLL's PE headers/imports/exports without loading it."""
    def require(ok, why):
        if not ok:
            raise ValueError(why)

    def unpack(fmt, offset):
        size = struct.calcsize(fmt)
        require(0 <= offset <= len(data) - size, "Native PE data is truncated")
        return struct.unpack_from(fmt, data, offset)

    require(512 <= len(data) <= 16 * 1024 * 1024 and data[:2] == b"MZ", "Native asset is not a bounded PE DLL")
    pe, = unpack("<I", 0x3C)
    require(data[pe:pe+4] == b"PE\0\0", "Native PE signature is invalid")
    machine, count = unpack("<HH", pe+4)
    optional_size, characteristics = unpack("<HH", pe+20)
    opt = pe+24
    magic, = unpack("<H", opt)
    require(machine == 0x8664 and magic == 0x20B and characteristics & 0x2000,
            "Native helper must be an AMD64 PE32+ DLL")
    require(0 < count <= 96 and optional_size >= 240, "Native PE section layout is unsupported")
    headers, = unpack("<I", opt+60)
    directories, = unpack("<I", opt+108)
    require(directories >= 2, "Native PE export/import directories are missing")
    sections = []
    for i in range(count):
        at = opt+optional_size+i*40
        virtual_size, rva, raw_size, raw = unpack("<IIII", at+8)
        flags, = unpack("<I", at+36)
        require(raw <= len(data) and raw_size <= len(data)-raw, "Native PE section bytes are truncated")
        sections.append((rva, virtual_size, raw_size, raw, flags))

    def offset(rva, size=1):
        if rva < headers and rva+size <= min(headers, len(data)):
            return rva
        for base, _, raw_size, raw, _ in sections:
            if base <= rva and rva+size <= base+raw_size:
                return raw+rva-base
        raise ValueError("Native PE RVA is outside its saved sections")

    def string(rva):
        at = offset(rva)
        end = data.find(b"\0", at, min(at+256, len(data)))
        require(end >= at, "Native PE name is unterminated")
        return data[at:end].decode("ascii")

    export_rva, export_size, import_rva, _ = unpack("<IIII", opt+112)
    require(export_rva and export_size >= 40, "Native helper exports are missing")
    fields = unpack("<IIHHIIIIIII", offset(export_rva, 40))
    functions, names, functions_rva, names_rva, ordinals_rva = fields[6:]
    require(0 < names <= functions <= 1024, "Native helper export table is unsupported")
    exports = {}
    for i in range(names):
        name_rva, = unpack("<I", offset(names_rva+i*4, 4))
        ordinal, = unpack("<H", offset(ordinals_rva+i*2, 2))
        require(ordinal < functions, "Native helper export ordinal is invalid")
        function_rva, = unpack("<I", offset(functions_rva+ordinal*4, 4))
        name = string(name_rva)
        require(name not in exports, "Native helper export name is duplicated")
        exports[name] = function_rva
    require(REQUIRED_EXPORTS <= exports.keys(), "Native actor helper exports are missing")
    require(not any(name.startswith("BC_test_") or name.endswith("_test") for name in exports),
            "Review-only native test exports cannot be packaged")
    for name in REQUIRED_EXPORTS:
        rva = exports[name]
        require(not export_rva <= rva < export_rva+export_size
                and any(base <= rva < base+raw_size and flags & 0x20000000
                        for base, _, raw_size, _, flags in sections),
                "Required native export is not local executable code: " + name)
    imports = []
    if import_rva:
        for i in range(256):
            row = unpack("<IIIII", offset(import_rva+i*20, 20))
            if not any(row):
                break
            imports.append(string(row[3]))
        else:
            raise ValueError("Native import table exceeds the limit")
    require(not any(name.lower().startswith(("vcruntime", "msvcp", "msvcr", "api-ms-win-crt"))
                    or name.lower() == "ucrtbase.dll" for name in imports),
            "Native helper must bundle its C/C++ runtime through the static build")
    return {"machine": "AMD64", "exports": sorted(exports), "imports": sorted(imports)}


def build(output=None, native_dll=None):
    manifest = json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["id"] == "goose_bridge_combat"
    assert manifest["version"] == "0.2.0-experimental"
    assert manifest["native"]["route"] == "actor" and manifest["native"]["asset"] == NATIVE_ASSET
    assert set(manifest["lll"]["modules"]) == set(FILES) & {"src/backend.lua", "src/controller.lua", "src/mcm.lua"}
    payload = {name: (ROOT / name).read_bytes() for name in FILES}
    payload.update({name: (ROOT / source).read_bytes() for name, source in NOTICES.items()})
    if native_dll is None:
        raise ValueError("Supply the production helper explicitly with --native-dll")
    native_dll = Path(native_dll).resolve()
    native_bytes = native_dll.read_bytes()
    native = validate_native(native_bytes)
    native.update({"asset": NATIVE_ASSET, "sha256": hashlib.sha256(native_bytes).hexdigest(),
                   "route": "actor", "game_timestamp": "6AB3B43F", "exe_timestamp": "6AB382E4"})
    source_receipt = native_dll.parent / "native-build-receipt.json"
    if source_receipt.is_file():
        receipt = json.loads(source_receipt.read_text(encoding="utf-8"))
        if any(receipt.get(key) != native[key] for key in ("sha256", "game_timestamp", "exe_timestamp")):
            raise ValueError("Native build receipt does not match the supplied DLL/build")
        for name, digest in receipt.get("source_sha256", {}).items():
            source = ROOT / name
            if not source.resolve().is_relative_to((ROOT / "native").resolve()) \
                    or not source.is_file() or hashlib.sha256(source.read_bytes()).hexdigest() != digest:
                raise ValueError("Native source changed after its supplied build: " + name)
        native["source_sha256"] = receipt.get("source_sha256", {})
    payload[NATIVE_ASSET] = native_bytes
    payload[NATIVE_RECEIPT] = (json.dumps(native, indent=2)+"\n").encode("utf-8")
    output = Path(output).resolve() if output else ROOT.parent / "dist" / "releases" / ("bridge-combat-" + manifest["version"] + "-review")
    output.mkdir(parents=True, exist_ok=True)
    folder = output / manifest["id"]
    if folder.exists():
        unknown = {str(file.relative_to(folder)).replace("\\", "/") for file in folder.rglob("*") if file.is_file()} - payload.keys()
        if unknown:
            raise ValueError("Review output contains files outside the allowlist: " + ", ".join(sorted(unknown)))
    for name, data in payload.items():
        target = folder / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    archive = output / ("BridgeCombat-" + manifest["version"] + "-LLL.zip")
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as package:
        for name, data in payload.items():
            entry = zipfile.ZipInfo(manifest["id"] + "/" + name, (2026, 10, 13, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            package.writestr(entry, data)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / "SHA256SUMS.txt").write_text(digest + "  " + archive.name + "\n", encoding="ascii")
    records = {name: hashlib.sha256(data).hexdigest() for name, data in payload.items()}
    (output / "build-manifest.json").write_text(json.dumps({"id": manifest["id"], "version": manifest["version"],
        "archive": archive.name, "sha256": digest, "files": records, "native": native,
        "state": "actor review candidate; Armory cleanup awaits live retest; not installed or published"}, indent=2) + "\n", encoding="utf-8")
    return archive


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", help="Explicit review output directory")
    parser.add_argument("--native-dll", type=Path, required=True, help="Production AMD64 static-runtime helper to bundle")
    args = parser.parse_args()
    print(build(args.output, args.native_dll))
