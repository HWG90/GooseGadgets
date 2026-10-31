"""Rebuild the original weapon menu DLL (0.1.17, with the health and stamina bars) for game 26251122.

Source: the release weapon_menu.cpp after unport_cpp.py (every line matched to the ported source gets its
literals). The hand map below finishes the lines the port rewrote: the four vitals functions, moved by a
constant -0x17EDB0 with their first 24 bytes read from the decrypted capture; the shared ABI rows, whose
RVAs the two recorded maps (6AB3B43F->26088801 probe mappings, 26088801->26251122 literals-wm) compose
to exactly the ported rows; and the struct offsets the port proved live. Then the release fixture is moved
the same way, both are compiled with Zig for x86_64-windows-gnu, and every fixture mode runs under Wine.

Usage: python3 -I build_dll.py   (writes dll/BridgeCombatWeaponMenu-<sha12>.dll and dll/build-receipt.json)
"""
import hashlib, json, os, re, subprocess, sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from unport import literals, mask, GLOBAL

HERE = Path(__file__).resolve().parent
ORIGINAL = Path('/home/goose/Documents/Codex/2026-10-22/a-2/work/GooseGadgets/Bridge Combat/terminal-0.1.14')
WT = Path('/home/goose/Worktrees/linux-hd2/bridge-combat-26251122/native-work/bridge-terminal')
WS = Path('/home/goose/Projects/Linux HD2 Mods/builds/26251122')
ZIG = '/home/goose/Documents/Codex/2026-10-22/a-2/work/ffi-comparison/toolchain/zig-x86_64-linux-0.14.1/zig'
VITALS = {0x1816A60: 0x1697cb0, 0x181DE50: 0x169f0a0, 0x1819A70: 0x169acc0, 0x181EB90: 0x169fde0}  # -0x17EDB0 each
# Struct offsets that moved between 6AB3B43F and 26251122 (the port's values, proven live), by line.
OFFSETS = {153: {'0xAC21C': '0xac29c'}, 267: {'0xAC21C': '0xac29c'}, 409: {'0xAC21C': '0xac29c'},
           156: {'0xFD8': '0xfe0'}, 519: {'0xFD8': '0xfe0'}, 468: {'0xFD0': '0xfd8'}, 484: {'0xFD0': '0xfd8'},
           233: {'0x46D900': '0x46d480'},
           # The protector refills the padding after a jmp, so only the jmp itself identifies the GUI release thunk (as the port).
           252: {'e98b1cf2ffcccccccccccccccccccccc4883ec28e80756f2': 'e9ab8df4ff'}}
KEEP = {48, 172, 174, 175, 177, 186, 191, 202, 205, 211, 217, 234, 286, 290, 291, 295, 306, 347, 399, 404, 437, 470, 481, 492, 500, 503, 520}
FIXTURE_OFFSETS = {'0xFD0': '0xfd8', '0xFD8': '0xfe0', '0xF80': '0xf88', '0xF88': '0xf90'}
FIXTURE_KEEP_LITERALS = {'0x3F0000003F000000', '0x258', '0x2C5BC', '0x2C5B8', '0x53D8B0', '0xE0000049', '0x1A18', '0x1208', '0x148',
                         '0x50', '0x1CD0', '0xE0000045', '0x110', '0x220', '0x330', '0xE000004B', '0xA8', '0xB0', '0xE0000048', '0xE000004A',
                         '0x226', '0x4280000000000000', '0x3F000000', '0xE0000050', '0xE0000051', '0x248', '0x1000', '0xF0', '0x820', '0xF8',
                         '0x3698', '0x41011', '0xA', '0x20A', '0x08000000', '0x202', '0x08400000', '0xA0', '0x88', '0x4298'}


def apply(line, pairs):
    for old, new in pairs.items():
        assert old in line, (old, line[:80])
        line = line.replace(old, new)
    return line


def main():
    cap = (WS / 'capture/game-6ae0e5ff.merged.bin').read_bytes()
    probe = {int(k, 16): int(v, 16) for k, v in json.loads((Path('/home/goose/Documents/ChatGPT/Linux HD2/native-work/bridge-terminal/probe-build.json')).read_text())['mappings'].items()}
    wm = {}
    for e in json.loads((WS / 'maps/bridge/literals-wm.json').read_text()):
        if e.get('new') is not None: wm.setdefault(e['value'], set()).add(e['new'])
    assert all(len(v) == 1 for v in wm.values())
    composed = {old: next(iter(wm.get(mid, {mid}))) for old, mid in probe.items()}
    composed.update(VITALS)
    # Start from the release source every time: unport_cpp.py rewrites the matched lines and lists the rest.
    subprocess.run([sys.executable, '-I', str(HERE / 'unport_cpp.py'), str(ORIGINAL / 'native/weapon_menu.cpp'),
                    str(WT / 'native/weapon_menu.cpp'), str(HERE / 'dll/native/weapon_menu.cpp'), str(HERE / 'dll/unport-cpp-report.json')],
                   check=True, stdout=subprocess.DEVNULL)
    report = json.loads((HERE / 'dll/unport-cpp-report.json').read_text())
    lines = (HERE / 'dll/native/weapon_menu.cpp').read_text().split('\n')
    wt_rows = re.findall(r'\{(0x[0-9a-fA-F]+),"([0-9a-f]+)"\}', (WT / 'native/weapon_menu.cpp').read_text())
    assert len(wt_rows) == 32
    handled = set()
    for u in report['unresolved']:
        i = u['line']; line = lines[i - 1]
        if 95 <= i <= 98:
            old = int(u['literals'][0], 16); new = VITALS[old]
            lines[i - 1] = '    {0x%X,"%s"},' % (new, cap[new:new + 24].hex())
        elif 99 <= i <= 129:
            old = int(u['literals'][0], 16); row = wt_rows[i - 99]
            assert composed[old] == int(row[0], 16), (hex(old), row[0])
            lines[i - 1] = '    {%s,"%s"},' % (row[0], row[1])
        elif i == 472:
            def rva(m):
                return '0x%x' % composed[int(m.group(0), 16)]
            lines[i - 1] = re.sub(r'0x[0-9A-Fa-f]{6,}', rva, line)
        elif i in OFFSETS:
            lines[i - 1] = apply(line, OFFSETS[i])
        elif i in KEEP:
            pass
        else:
            raise SystemExit('no decision for weapon_menu.cpp line %d: %s' % (i, line.strip()[:120]))
        handled.add(i)
    assert handled == {u['line'] for u in report['unresolved']}
    source = '\n'.join(lines)
    # Every address-sized literal now in the source is one the port uses, or one of the vitals.
    allowed = set(literals((WT / 'native/weapon_menu.cpp').read_text())) | {'0x%x' % v for v in VITALS.values()} | {'0x%X' % v for v in VITALS.values()} \
        | {'0x3F000000', '0x4280000000000000'}  # the vitals constructors' float anchors, not addresses
    strange = sorted({l for l in literals(source) if l.startswith('0x') and int(l, 16) >= 0x100000 and l.lower() not in {a.lower() for a in allowed}})
    assert not strange, strange
    (HERE / 'dll/native/weapon_menu.cpp').write_text(source)
    (HERE / 'dll/native/weapon_menu.h').write_bytes((ORIGINAL / 'native/weapon_menu.h').read_bytes())
    # The fixture: matched lines from the ported fixture, then the same moved offsets.
    wt_fixture = (WT / 'tests/native_weapon_menu_tests.cpp').read_text().splitlines()
    index = {}
    for pline in wt_fixture:
        lits = literals(pline)
        if lits: index.setdefault(mask(pline), []).append(lits)
    # Every other literal on a rewritten fixture line is one the ported fixture also uses, or a vitals-only constant.
    fixture_allowed = {l.lower() for l in literals('\n'.join(wt_fixture))} | {l.lower() for l in FIXTURE_KEEP_LITERALS}
    flines = (ORIGINAL / 'tests/native_weapon_menu_tests.cpp').read_text().split('\n')
    for i, line in enumerate(flines):
        lits = literals(line)
        if not lits: continue
        same = {tuple(h) for h in index.get(mask(line), []) if len(h) == len(lits)}
        if len(same) != 1 and all(l.upper() in GLOBAL for l in lits): same = {tuple(GLOBAL[l.upper()].lower() for l in lits)}
        if len(same) == 1:
            new = list(next(iter(same)))
            if new != lits:
                from unport import substitute
                flines[i] = substitute(line, new)
            continue
        for lit in lits:
            if lit in FIXTURE_OFFSETS: line = line.replace(lit, FIXTURE_OFFSETS[lit])
            else: assert lit.lower() in fixture_allowed, (i + 1, lit, line.strip()[:100])
        flines[i] = line
    fixture = '\n'.join(flines)
    assert fixture.count('#include <cassert>') == 1
    fixture = fixture.replace('#include <cassert>', '#include <cassert>\n#ifdef NDEBUG\n#error Bridge fixtures require active assertions\n#endif')
    (HERE / 'dll/tests/native_weapon_menu_tests.cpp').write_text(fixture)
    modes = sorted(set(re.findall(r'mode=="([a-z0-9-]+)"', fixture)))
    common = [ZIG, 'c++', '-target', 'x86_64-windows-gnu', '-std=c++17', '-fms-extensions', '-fno-rtti', '-O2']
    dll = HERE / 'dll/BridgeCombatWeaponMenu.dll'; exe = HERE / 'dll/tests/bridge_fixture.exe'
    if '--fixtures-only' in sys.argv:
        # Rerun the modes against the already built DLL and fixture (the source regenerated above is identical).
        assert hashlib.sha256(source.encode()).hexdigest() == json.loads((HERE / 'dll/build-receipt.json').read_text())['source_sha256']
    else:
        subprocess.run(common + ['-shared', str(HERE / 'dll/native/weapon_menu.cpp'), '-o', str(dll)], check=True)
        subprocess.run(common + ['-UNDEBUG', str(HERE / 'dll/tests/native_weapon_menu_tests.cpp'), '-o', str(exe)], check=True)
    env = dict(os.environ, WINEPREFIX=str(WT / 'wine-prefix'), WINEDEBUG='-all', WINEDLLOVERRIDES='winemenubuilder.exe=d;winedbg.exe=d')
    subprocess.run(['wine', 'cmd', '/c', 'exit'], env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    subprocess.run(['wineserver', '-p'], env=env, check=False)
    results = []
    for mode in ['ordinary'] + modes:
        start = time.monotonic()
        row = None
        for attempt in range(2):  # the first process after a Wine prefix start can exceed the budget once
            try:
                r = subprocess.run(['wine', str(exe), mode], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=25)
                row = {'mode': mode, 'code': r.returncode, 'seconds': round(time.monotonic() - start, 3), 'output': r.stdout.decode(errors='replace')[-1500:]}
                break
            except subprocess.TimeoutExpired:
                row = {'mode': mode, 'code': None, 'seconds': 25, 'output': 'timeout'}
        results.append(row)
        if row['code'] != 0: print('FAIL', mode, row['output'][-600:], flush=True)
    passed = sum(1 for r in results if r['code'] == 0)
    sha = hashlib.sha256(dll.read_bytes()).hexdigest()
    final = HERE / ('dll/BridgeCombatWeaponMenu-%s.dll' % sha[:12]); final.write_bytes(dll.read_bytes())
    receipt = {'file': str(final), 'sha256': sha, 'bytes': final.stat().st_size, 'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
               'fixture_exe_sha256': hashlib.sha256(exe.read_bytes()).hexdigest(), 'fixture_modes': len(results), 'fixture_passed': passed,
               'vitals': {'0x%X' % k: '0x%x' % v for k, v in VITALS.items()}, 'results': results}
    (HERE / 'dll/build-receipt.json').write_text(json.dumps(receipt, indent=1) + '\n')
    print('PASS' if passed == len(results) else 'FAIL', passed, '/', len(results), final.name, final.stat().st_size, 'bytes')
    raise SystemExit(0 if passed == len(results) else 1)


if __name__ == '__main__':
    main()
