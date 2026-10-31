"""Run the release's offline Lua fixtures against the assembled 26251122 tree with the system LuaJIT.

The release runs them through the game's lua51.dll (terminal-0.1.14/tests/run_controller.py) with
BRIDGE_COMBAT_TEST_ROOT pointing at the terminal-0.1.14 tree. Here a test root is built from symlinks so
every source path the fixtures load resolves to the assembled package (the shared tools/live_*.lua modules
are the package's src/animation_*.lua), and each fixture runs in its own LuaJIT process.

Usage: python3 -I run_lua_fixtures.py ORIGINAL_ROOT ASSEMBLED_PACKAGE [--only name]
"""
import json, os, shutil, subprocess, sys
from pathlib import Path

CASES_COMPAT = ("terminal_services_fixture.lua", "runtime_fixture.lua", "ship_return_fixture.lua", "session_restart_fixture.lua",
                "one_shot_cleanup_fixture.lua", "cleanup_native_fixture.lua", "ui_assets_fixture.lua", "ui_package_fixture.lua",
                "ui_material_fixture.lua", "ui_atlas_fixture.lua", "ui_package_recovery_fixture.lua", "fx_assets_fixture.lua",
                "fx_resource_fixture.lua", "weapon_menu_fixture.lua", "weapon_menu_native_fixture.lua", "sha256_fixture.lua",
                "bindings_fixture.lua", "ammo_console_fixture.lua", "ammo_console_native_fixture.lua", "support_weapons_fixture.lua",
                "wall_terminal_fixture.lua", "wall_camera_fixture.lua", "wall_zoom_fixture.lua", "wall_station_fixture.lua",
                "wall_terminal_assets_fixture.lua")
CASES_ROOT = ("animation_controller_fixture.lua", "animation_io_fixture.lua", "animation_lifecycle_fixture.lua",
              "pose_layers_stance_fixture.lua", "bridge_exit_state_fixture.lua", "clip_lease_fixture.lua", "package_lease_fixture.lua",
              "ship_visibility_fixture.lua")
# Not run: ffi_binding_cache_fixture.lua and runtime_registry_fixture.lua exercise the older compat/lll-0.1.1 and
# lll-0.1.2 trees, which this package does not ship; blend_pairs_fixture.lua captures blend pairs, which this build
# does not expose (animation_blend.lua keeps supported=false and the controller skips that step).
TOOLS = {"live_pose_layers_stance.lua": "animation_pose.lua", "live_bridge_exit_state.lua": "animation_idle.lua",
         "live_clip_lease.lua": "animation_clips.lua", "live_package_lease.lua": "animation_packages.lua",
         "live_blend_pairs.lua": "animation_blend.lua"}


def link(target, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink() or path.exists(): path.unlink()
    path.symlink_to(target)


def main():
    original, package = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    only = sys.argv[4] if len(sys.argv) > 4 and sys.argv[3] == '--only' else None
    root = package.parent / 'lua-test-root'
    # Always a fresh root: a stale directory link here would make the per-file links below land elsewhere.
    if root.is_dir() and not root.is_symlink(): shutil.rmtree(root)
    link(package / 'src', root / 'compat/lll-0.1.14/src')
    link(package / 'src', root / 'src')
    # The fixtures with the sources' build constants (port_fixtures.py); the older compat trees two of them compare against.
    # Linked one file at a time: a fixture opens `../src/...` next to its own path, which must resolve inside the root.
    ported = package.parent / 'tests-ported'
    for rel in ('compat/lll-0.1.14/tests', 'tests'):
        for fixture in sorted((ported / rel).glob('*')):
            if fixture.is_file(): link(fixture, root / rel / fixture.name)
    for old in ('lll-0.1.1', 'lll-0.1.2'):
        link(original / 'compat' / old, root / 'compat' / old)
    for name in os.listdir(original / 'tools'):
        link(package / 'src' / TOOLS[name] if name in TOOLS else original / 'tools' / name, root / 'tools' / name)
    for name in ('main.lua', 'manifest.json', 'config'):
        link(package / name, root / 'compat/lll-0.1.14' / name)
    link(package / 'native', root / 'compat/lll-0.1.14/native')
    cases = [root / 'compat/lll-0.1.14/tests' / n for n in CASES_COMPAT] + [root / 'tests' / n for n in CASES_ROOT]
    results = []
    for case in cases:
        if only and only not in case.name: continue
        env = dict(os.environ, DBF_BRIDGE_COMBAT_TEST_ROOT=str(root))
        r = subprocess.run(['luajit', '-e', "BRIDGE_COMBAT_TEST_ROOT=%r;assert(jit and jit.version);require('ffi');require('bit')" % str(root),
                            str(case)], env=env, cwd=str(root), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
        results.append({'case': case.name, 'code': r.returncode, 'tail': r.stdout[-700:]})
        print(('PASS ' if r.returncode == 0 else 'FAIL ') + case.name, flush=True)
        if r.returncode: print('    ' + r.stdout.strip().replace('\n', '\n    ')[-900:])
    passed = sum(1 for r in results if r['code'] == 0)
    (package.parent / 'lua-fixture-results.json').write_text(json.dumps({'passed': passed, 'total': len(results), 'results': results}, indent=1) + '\n')
    print('lua fixtures', passed, '/', len(results))


if __name__ == '__main__':
    main()
