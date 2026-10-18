"""Build0.1.14 only with an accepted immutable persistent native-menu receipt."""
from pathlib import Path
import argparse
import hashlib
import json
import struct
import zipfile

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parents[1]
SHARED = {
    "animation_io": "src/animation_io.lua",
    "animation_lifecycle": "src/animation_lifecycle.lua",
    "animation_controller": "src/animation_controller.lua",
    "animation_pose": "tools/live_pose_layers_stance.lua",
    "animation_idle": "tools/live_bridge_exit_state.lua",
    "animation_clips": "tools/live_clip_lease.lua",
    "animation_packages": "tools/live_package_lease.lua",
    "animation_blend": "tools/live_blend_pairs.lua",
    "ship_visibility": "src/ship_visibility.lua",
}
LOCAL = ("src/terminal_render.lua", "src/terminal_services.lua", "src/terminal_input_binary.lua", "main.lua", "manifest.json", "README.md", "LICENSE", "config/defaults.cfg",
         "src/ship_return.lua", "src/backend.lua", "src/controller.lua", "src/mcm.lua", "src/runtime.lua",
         "src/bindings.lua", "src/ammo_console.lua", "src/ammo_station_anchor.lua",
         "src/support_weapons.lua", "src/support_catalogue.lua", "src/terminal_icons.lua", "TERMINAL-ICONS.md",
         "src/wall_station.lua", "src/wall_terminal.lua", "src/wall_camera.lua", "src/wall_zoom.lua", "src/wall_pointer.lua",
         "src/wall_terminal_anchor.lua", "src/wall_terminal_assets.lua",
         "src/ui_assets.lua", "src/ui_assets_catalog.lua", "src/ui_package_lease.lua",
         "src/ui_material_readiness.lua", "src/ui_atlas_readiness.lua",
         "src/ui_package_recovery.lua",
         "src/fx_assets.lua", "src/fx_assets_catalog.lua", "src/fx_resource_readiness.lua",
         "src/weapon_menu.lua", "src/weapon_menu_native.lua", "src/weapon_menu_binary.lua", "src/sha256.lua")
EXPORTS = sorted("BC_weapon_menu_" + name for name in ("acquire", "tick", "stop", "phase", "flags", "error"))


def pe_exports(raw):
    """Verify actual AMD64 PE exports; do not trust a receipt's export names."""
    assert len(raw) >= 512 and raw[:2] == b"MZ", "Native DLL DOS header differs"
    pe = struct.unpack_from("<I", raw, 0x3C)[0]
    assert 64 <= pe <= 4096 and raw[pe:pe+4] == b"PE\0\0", "Native DLL PE header differs"
    machine, count, stamp = struct.unpack_from("<HHI", raw, pe+4)
    optional_bytes = struct.unpack_from("<H", raw, pe+20)[0]
    optional = pe+24
    assert machine == 0x8664 and 0 < count <= 96 and optional_bytes >= 120 and struct.unpack_from("<H", raw, optional)[0] == 0x20B and struct.unpack_from("<H", raw, pe+22)[0] & 0x2000, "Native DLL is not an AMD64 PE32+ DLL"
    assert struct.unpack_from("<I", raw, optional+108)[0] >= 1, "Native DLL has no export directory"
    image_bytes, header_bytes = struct.unpack_from("<II", raw, optional+56)
    sections = []
    for i in range(count):
        at = optional+optional_bytes+i*40
        virtual_bytes, rva, size, start = struct.unpack_from("<IIII", raw, at+8)
        flags = struct.unpack_from("<I", raw, at+36)[0]
        assert start+size <= len(raw), "Native PE section file bounds differ"
        sections.append((rva, max(virtual_bytes, size), start, size, flags))
    def offset(rva, size):
        assert 0 <= rva < image_bytes and size >= 0 and rva+size <= image_bytes, "Native PE RVA bounds differ"
        if rva+size <= header_bytes:
            assert rva+size <= len(raw)
            return rva
        for begin, _, start, file_size, _ in sections:
            if begin <= rva and rva+size <= begin+file_size:
                return start+rva-begin
        raise AssertionError("Native PE RVA is not backed by file bytes")
    directory_rva, directory_size = struct.unpack_from("<II", raw, optional+112)
    directory = offset(directory_rva, 40)
    functions, names = struct.unpack_from("<II", raw, directory+20)
    address_rva, name_rva, ordinal_rva = struct.unpack_from("<III", raw, directory+28)
    assert 0 < names <= functions <= 64, "Native export count differs"
    address_at, name_at, ordinal_at = offset(address_rva, functions*4), offset(name_rva, names*4), offset(ordinal_rva, names*2)
    result = []
    for i in range(names):
        name = offset(struct.unpack_from("<I", raw, name_at+i*4)[0], 1)
        end = raw.find(b"\0", name, name+128)
        assert end > name, "Native export name is unterminated"
        result.append(raw[name:end].decode("ascii"))
        ordinal = struct.unpack_from("<H", raw, ordinal_at+i*2)[0]
        assert ordinal < functions, "Native export ordinal differs"
        function = struct.unpack_from("<I", raw, address_at+ordinal*4)[0]
        assert not directory_rva <= function < directory_rva+directory_size, "Forwarded native export refused"
        assert any(begin <= function < begin+size and flags & 0x20000000 for begin, size, _, _, flags in sections), "Native export is not executable"
    assert sorted(result) == EXPORTS, "Actual native API differs: " + repr(sorted(result))
    return {"timestamp_hex": hex(stamp), "exports": sorted(result), "image_bytes": image_bytes}


def native_payload(receipt_path):
    receipt_path = Path(receipt_path).resolve()
    receipt_bytes = receipt_path.read_bytes()
    receipt = json.loads(receipt_bytes)
    assert receipt.get("persistent_lifetime_proof_accepted") is True, "Persistent native lifetime proof is not accepted"
    assert receipt.get("afk_dirty_retirement_proof_accepted") is True, "AFK dirty-only retirement proof is not accepted"
    assert receipt.get("ship_active_cleanup_proof_accepted") is True, "Normal ShipActive cleanup proof is not accepted"
    assert receipt.get("drop_widget_constructor_prerequisite_proof_accepted") is True, "Native equipment panel prerequisite proof is not accepted"
    assert receipt.get("drop_detached_primitive_lifetime_proof_accepted") is True, "Detached equipment panel lifetime proof is not accepted"
    assert receipt.get("supported_game_stamp") == "0x6AB3B43F" and receipt.get("supported_exe_stamp") == "0x6AB382E4", "Native supported builds differ"
    dll = Path(receipt["dll"])
    dll = dll.resolve() if dll.is_absolute() else (receipt_path.parent / dll).resolve()
    data = dll.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    assert digest == receipt["dll_sha256"] and dll.name == "BridgeCombatWeaponMenu-"+digest[:12]+".dll", "Native immutable file/hash identity differs"
    assert receipt.get("exports") == EXPORTS, "Native receipt API differs"
    pe = pe_exports(data)
    name = "native/"+dll.name
    spec = ("-- Generated from accepted immutable native build receipt.\nreturn {available=true,file="+json.dumps(name)+",sha256="+json.dumps(digest)+",bytes="+str(len(data))+"}\n").encode("utf-8")
    return name, data, spec, {"file": name, "sha256": digest, "bytes": len(data), "receipt": str(receipt_path),
                              "receipt_sha256": hashlib.sha256(receipt_bytes).hexdigest(), "pe": pe}


def build(output, native_receipt):
    manifest = json.loads((HERE / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["id"] == "goose_bridge_combat"
    assert manifest["version"] == "0.1.14-experimental"
    native_name, native_bytes, native_spec, native = native_payload(native_receipt)
    manifest["description"] = "Bridge combat with a fixed equipment terminal, focused mouse controls, resupply and support weapons."
    manifest["native"] = {"file": native_name, "sha256": native["sha256"], "api": 1}
    payload = {name: (HERE / name).read_bytes() for name in LOCAL}
    payload["manifest.json"] = (json.dumps(manifest, indent=2)+"\n").encode("utf-8")
    payload["src/weapon_menu_binary.lua"] = native_spec
    payload[native_name] = native_bytes
    sources = {}
    for name, source in SHARED.items():
        data = (SOURCE / source).read_bytes()
        payload["src/" + name + ".lua"] = data
        sources[source] = hashlib.sha256(data).hexdigest()
    modules = {name for name in payload if name.startswith("src/")}
    assert modules == set(manifest["lll"]["modules"]), "Module allowlist differs"
    assert [name for name in payload if name.endswith(".dll")] == [native_name], "Unexpected native payload"
    output = Path(output).resolve()
    folder = output / manifest["id"]
    if folder.exists():
        unknown = {p.relative_to(folder).as_posix() for p in folder.rglob("*") if p.is_file()} - payload.keys()
        assert not unknown, "Unknown output files: " + str(sorted(unknown))
    for name, data in payload.items():
        target = folder / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    archive = output / "BridgeCombat-0.1.14-experimental-LLL.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in sorted(payload.items()):
            entry = zipfile.ZipInfo(manifest["id"] + "/" + name, (2026, 10, 16, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            z.writestr(entry, data)
    hashes = {name: hashlib.sha256(data).hexdigest() for name, data in payload.items()}
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    receipt = {"id": manifest["id"], "version": manifest["version"], "files": hashes,
               "source_sha256": sources, "archive": archive.name, "sha256": digest,
               "native": native,
               "state": "built; deployed and observed gameplay are separate evidence"}
    (output / "build-manifest.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    (output / "SHA256SUMS.txt").write_text(digest + "  " + archive.name + "\n", encoding="ascii")
    return archive


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--native-receipt", type=Path, required=True,
                        help="Immutable production DLL receipt with accepted persistent and AFK dirty-retirement proofs")
    args = parser.parse_args()
    print(build(args.output, args.native_receipt))
