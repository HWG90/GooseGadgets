"""Bridge Combat 0.1.17 (the Windows original, game 6AB3B43F) on game 26251122 offsets.

The LuaJIT port (luajit-ports/goose_bridge_combat) is the original plus additions, with every
address literal already moved to 26251122 and proven live. This takes the original files and,
for every line that carries an address (0x… literal or a hex fingerprint), finds the identical
line (addresses masked) in the port and copies its literals in order. Lines with no such line
are listed as unresolved and are finished by hand in assemble.py; nothing is guessed.

Usage: python3 -I unport.py ORIGINAL_ROOT PORT_SRC OUT_DIR   (writes OUT_DIR/src and OUT_DIR/unport-report.json)
"""
import json, re, sys
from pathlib import Path

HEX = re.compile(r'0[xX][0-9A-Fa-f]+')
HEXSTR = re.compile(r'(?<![0-9A-Za-z])[0-9a-f]{16,}(?![0-9A-Za-z])')
NUM = re.compile(r'(?<![0-9A-Za-z_.])[0-9]{4,}(?![0-9A-Za-z_])')
LOCAL = ("terminal_render.lua", "terminal_services.lua", "terminal_input_binary.lua", "ship_return.lua", "backend.lua",
         "controller.lua", "mcm.lua", "runtime.lua", "bindings.lua", "ammo_console.lua", "ammo_station_anchor.lua",
         "support_weapons.lua", "support_catalogue.lua", "terminal_icons.lua", "wall_station.lua", "wall_terminal.lua",
         "wall_camera.lua", "wall_zoom.lua", "wall_pointer.lua", "wall_terminal_anchor.lua", "wall_terminal_assets.lua",
         "ui_assets.lua", "ui_assets_catalog.lua", "ui_package_lease.lua", "ui_material_readiness.lua",
         "ui_atlas_readiness.lua", "ui_package_recovery.lua", "fx_assets.lua", "fx_assets_catalog.lua",
         "fx_resource_readiness.lua", "weapon_menu.lua", "weapon_menu_native.lua", "sha256.lua")
# The release build (compat/lll-0.1.14/build.py SHARED) takes these from the terminal-0.1.14 tree.
SHARED = {"animation_io.lua": "src/animation_io.lua", "animation_lifecycle.lua": "src/animation_lifecycle.lua",
          "animation_controller.lua": "src/animation_controller.lua", "animation_pose.lua": "tools/live_pose_layers_stance.lua",
          "animation_idle.lua": "tools/live_bridge_exit_state.lua", "animation_clips.lua": "tools/live_clip_lease.lua",
          "animation_packages.lua": "tools/live_package_lease.lua", "animation_blend.lua": "tools/live_blend_pairs.lua",
          "ship_visibility.lua": "src/ship_visibility.lua"}
# Lines of these original files may also match these port files (the port moved the code).
EXTRA = {"runtime.lua": ("combat_control_cleanup.lua",)}


def literals(line):
    return [m.group(0) for m in HEX.finditer(line)] + [m.group(0) for m in HEXSTR.finditer(line)]


def mask(line):
    return NUM.sub('NUM', HEXSTR.sub('HEXSTR', HEX.sub('HEX', line))).replace('"', "'").strip()


# Build identity literals: the same everywhere, so a line the port rewrote still maps when these are all it holds.
GLOBAL = {'0x6AB3B43F': '0x6AE0E5FF', '0x6AB382E4': '0x6AE0964A'}


def substitute(line, values):
    values = list(values)
    def take(_m):
        return values.pop(0)
    out = HEX.sub(take, line)
    # A fingerprint keeps the original's length: the port extended many prologues to whole-body
    # witnesses, and the original's io.native refuses anything over 128 bytes (and reads that many).
    def take_fingerprint(m):
        new = values.pop(0)
        return new[:len(m.group(0))] if len(new) > len(m.group(0)) else new
    out = HEXSTR.sub(take_fingerprint, out)
    assert not values
    return out


def main():
    original, port, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    (out / 'src').mkdir(parents=True, exist_ok=True)
    report = {'files': {}, 'unresolved': [], 'changed_lines': 0}
    for name in LOCAL + tuple(SHARED):
        src = original / 'compat/lll-0.1.14/src' / name if name in LOCAL else original / SHARED[name]
        text = src.read_text()
        index = {}
        for pname in (name,) + EXTRA.get(name, ()):
            ppath = port / pname
            if not ppath.exists(): continue
            plines = ppath.read_text().splitlines()
            for lineno, pline in enumerate(plines, 1):
                lits = literals(pline)
                if lits: index.setdefault(mask(pline), []).append((pname, lineno, lits))
                if lineno < len(plines) and lits:
                    nxt = plines[lineno]; nl = literals(nxt)
                    if nl: index.setdefault(mask(pline + ' ' + nxt), []).append((pname, lineno, lits + nl))
        lines = text.splitlines()
        changed = 0
        for i, line in enumerate(lines):
            lits = literals(line)
            if not lits: continue
            hits = index.get(mask(line), [])
            same = {tuple(h[2]) for h in hits if len(h[2]) == len(lits)}
            if len(same) != 1 and all(l in GLOBAL for l in lits):
                same = {tuple(GLOBAL[l] for l in lits)}
            if len(same) != 1 and i > 0:
                # The port joined this continuation line with the one before it.
                prev = lines[i - 1]; plits = literals(prev)
                joined = mask(prev + ' ' + line)
                jhits = {tuple(h[2]) for h in index.get(joined, []) if len(h[2]) == len(plits) + len(lits)}
                if len(jhits) == 1:
                    same = {tuple(next(iter(jhits))[len(plits):])}
            if len(same) != 1:
                report['unresolved'].append({'file': name, 'line': i + 1, 'text': line.strip()[:160],
                                             'candidates': [h[:2] for h in hits][:4]})
                continue
            new = next(iter(same))
            if list(new) != lits:
                lines[i] = substitute(line, new); changed += 1
        (out / 'src' / name).write_text('\n'.join(lines) + '\n')
        report['files'][name] = {'lines': len(lines), 'changed': changed}
        report['changed_lines'] += changed
    (out / 'unport-report.json').write_text(json.dumps(report, indent=1) + '\n')
    print('changed lines', report['changed_lines'], 'unresolved', len(report['unresolved']))
    for u in report['unresolved']: print(f"  {u['file']}:{u['line']}: {u['text'][:110]}")


if __name__ == '__main__':
    main()
