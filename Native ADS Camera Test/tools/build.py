"""Build the allowlisted native ADS review candidate; never install or publish."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.1.49-test"
IDENTITY = "goose_native_ads_camera_test"
MODULES = {"src/backend.lua", "src/profile.lua", "src/controller.lua", "src/menu.lua", "src/alignment.lua", "src/pose.lua", "src/placement_editor.lua", "src/fov.lua", "src/camera.lua", "src/motion.lua", "src/locomotion.lua", "src/motion_runtime.lua", "src/action_state.lua", "src/camera_compat.lua", "src/head_visibility.lua", "src/first_person_movement.lua", "src/blur.lua", "src/dof.lua", "src/action_placement.lua", "src/fird_person.lua", "src/skinned_placement.lua", "src/support_hand.lua", "src/head_placement.lua"}
FILES = (
    "main.lua", "manifest.json", "config/defaults.cfg", "README.md", "TECHNICAL.md", "LICENSE",
    "src/backend.lua", "src/profile.lua", "src/controller.lua", "src/menu.lua", "src/alignment.lua", "src/pose.lua", "src/placement_editor.lua", "src/fov.lua", "src/camera.lua", "src/motion.lua", "src/locomotion.lua", "src/motion_runtime.lua", "src/action_state.lua", "src/camera_compat.lua", "src/head_visibility.lua", "src/first_person_movement.lua", "src/blur.lua", "src/dof.lua", "src/action_placement.lua", "src/fird_person.lua", "src/skinned_placement.lua", "src/support_hand.lua", "src/head_placement.lua",
    "native/native_ads_alignment_0_1_5.dll",
    "native/native_ads_editor_0_1_43.dll",
    "native/native_ads_fov_0_1_23.dll",
    "native/native_ads_camera_0_1_48.dll",
    "native/native_ads_blur_0_1_16.dll",
)
SOURCES = {"native/native_ads_alignment_0_1_5.dll": "dist/native/native_ads_alignment_0_1_5.dll",
           "native/native_ads_editor_0_1_43.dll": "dist/native/native_ads_editor_0_1_43.dll",
           "native/native_ads_fov_0_1_23.dll": "dist/native/native_ads_fov_0_1_23.dll",
           "native/native_ads_camera_0_1_48.dll": "dist/native/native_ads_camera_0_1_48.dll",
           "native/native_ads_blur_0_1_16.dll": "dist/native/native_ads_blur_0_1_16.dll"}
REVIEW = ROOT / "dist" / "releases" / "native-ads-camera-0.1.49-test"


def validate_manifest(manifest: dict) -> None:
    if not isinstance(manifest, dict) or manifest.get("id") != IDENTITY or manifest.get("version") != VERSION:
        raise ValueError("Manifest must name the exact native ADS test identity/version")
    lll = manifest.get("lll")
    if not isinstance(lll, dict) or lll.get("entry") != "main.lua" or lll.get("defaults") != "config/defaults.cfg":
        raise ValueError("Manifest must declare the allowlisted LLL entry/defaults")
    if lll.get("retain_until_exit") is not True:
        raise ValueError("The native alignment project must retain its instance until process exit")
    modules = lll.get("modules")
    if not isinstance(modules, list) or len(modules) != len(MODULES) or not all(isinstance(m, str) for m in modules) or set(modules) != MODULES:
        raise ValueError("Manifest modules differ from the native ADS source allowlist")
    if "native" in manifest:
        raise ValueError("Native payload is controlled by the package allowlist")


def build(output: Path | str | None = None) -> Path:
    payload = {}
    for name in FILES:
        source = ROOT / SOURCES.get(name,name)
        if not source.resolve().is_relative_to(ROOT.resolve()) or not source.is_file():
            raise ValueError("Missing or redirected allowlisted source: " + name)
        payload[name] = source.read_bytes()
    manifest = json.loads(payload["manifest.json"].decode("utf-8"))
    validate_manifest(manifest)
    review = REVIEW.resolve()
    output = Path(output).resolve() if output is not None else review
    if not output.is_relative_to(review):
        raise ValueError("Output must stay in the named native ADS review directory")
    folder = output / IDENTITY
    if folder.exists():
        for file in folder.rglob("*"):
            if file.is_file():
                name = file.relative_to(folder).as_posix()
                if name not in payload or not file.resolve().is_relative_to(folder.resolve()):
                    raise ValueError("Review payload contains an unowned file: " + name)
    for name in FILES:
        if not (folder / name).resolve().is_relative_to(output):
            raise ValueError("A review destination is redirected outside its output")
    output.mkdir(parents=True, exist_ok=True)
    for name, data in payload.items():
        target = folder / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    archive = output / ("Native-ADS-Camera-" + VERSION + "-LLL.zip")
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as package:
        for name in FILES:
            entry = zipfile.ZipInfo(IDENTITY + "/" + name, (1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            package.writestr(entry, payload[name])
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    receipt = {
        "id": IDENTITY, "version": VERSION, "archive": archive.name, "sha256": digest,
        "files": {name: hashlib.sha256(data).hexdigest() for name, data in payload.items()},
        "state": "review candidate; not installed, published, or live-proven",
    }
    (output / "build-manifest.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    (output / "SHA256SUMS.txt").write_text(digest + "  " + archive.name + "\n", encoding="ascii")
    with zipfile.ZipFile(archive) as package:
        if set(package.namelist()) != {IDENTITY + "/" + name for name in FILES} or package.testzip() is not None:
            raise ValueError("Saved archive failed its allowlist/integrity check")
        for name, data in payload.items():
            if package.read(IDENTITY + "/" + name) != data:
                raise ValueError("Saved archive differs from source: " + name)
    return archive


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Optional subdirectory within the named review directory")
    print(build(parser.parse_args().output))
