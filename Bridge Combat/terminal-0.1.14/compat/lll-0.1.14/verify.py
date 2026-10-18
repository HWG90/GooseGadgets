"""Run focused lifecycle/ownership contracts in separate offline LuaJIT states."""
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CASES = [HERE / "tests" / name for name in (
    "terminal_services_fixture.lua", "runtime_fixture.lua", "session_restart_fixture.lua", "one_shot_cleanup_fixture.lua", "cleanup_native_fixture.lua", "ui_assets_fixture.lua", "ui_package_fixture.lua",
    "ui_material_fixture.lua", "ui_atlas_fixture.lua", "ui_package_recovery_fixture.lua", "fx_assets_fixture.lua",
    "fx_resource_fixture.lua", "weapon_menu_fixture.lua", "weapon_menu_native_fixture.lua",
    "sha256_fixture.lua", "bindings_fixture.lua", "ammo_console_fixture.lua",
    "ammo_console_native_fixture.lua", "support_weapons_fixture.lua",
    "wall_terminal_fixture.lua", "wall_camera_fixture.lua", "wall_zoom_fixture.lua", "wall_station_fixture.lua",
    "wall_terminal_assets_fixture.lua")] + [ROOT / "tests" / name for name in (
    "animation_controller_fixture.lua", "animation_io_fixture.lua", "animation_lifecycle_fixture.lua",
    "pose_layers_stance_fixture.lua", "bridge_exit_state_fixture.lua", "clip_lease_fixture.lua",
    "package_lease_fixture.lua", "blend_pairs_fixture.lua", "ffi_binding_cache_fixture.lua",
    "ship_visibility_fixture.lua", "runtime_registry_fixture.lua")]
for case in CASES:
    result = subprocess.run([sys.executable, str(ROOT / "tests/run_controller.py"), "--lua", str(case)],
                            capture_output=True, text=True)
    if result.returncode:
        print(result.stdout, result.stderr)
        raise SystemExit(result.returncode)
    lines = result.stdout.strip().splitlines()
    print(case.name + ": " + (lines[-1] if lines else "PASS"))
result = subprocess.run([sys.executable, str(HERE / "tests/build_native_gate_fixture.py")],
                        capture_output=True, text=True)
if result.returncode:
    print(result.stdout, result.stderr)
    raise SystemExit(result.returncode)
print(result.stdout.strip())
print("PASS all focused contracts; no game process attached")
