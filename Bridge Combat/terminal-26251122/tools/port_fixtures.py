"""Give the release's Lua fixtures the same literal substitutions their sources received.

unport.py rewrote source lines by matching them to the proven port; the fixtures build synthetic game
memory with the same build constants (stamps, struct offsets, data globals), so each old->new pair that
the sources received consistently (one old literal, one new value everywhere it changed) is applied to
the fixtures too. A literal that mapped to different values in different places is left alone and listed.

Usage: python3 -I port_fixtures.py ORIGINAL_ROOT UNPORTED_SRC OUT_TESTS_DIR
"""
import json, re, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from unport import literals, LOCAL, SHARED, GLOBAL


def main():
    original, unported, out = (Path(a) for a in sys.argv[1:4])
    pairs = {}
    for name in LOCAL + tuple(SHARED):
        src = original / 'compat/lll-0.1.14/src' / name if name in LOCAL else original / SHARED[name]
        old_lines, new_lines = src.read_text().splitlines(), (unported / name).read_text().splitlines()
        assert len(old_lines) == len(new_lines), name
        for a, b in zip(old_lines, new_lines):
            la, lb = literals(a), literals(b)
            if la == lb: continue
            assert len(la) == len(lb), (name, a[:60])
            for x, y in zip(la, lb):
                if x.lower() != y.lower(): pairs.setdefault(x.upper(), {})[y.lower()] = y
    for k, v in GLOBAL.items(): pairs.setdefault(k, {})[v.lower()] = v
    # The lines assemble.py finishes by hand carry the same build constants.
    from assemble import HAND
    for _name, _line, old, new, _why in HAND: pairs.setdefault(old.upper(), {})[new.lower()] = new
    # The same new value in two spellings is one substitution; different values are a real conflict.
    consistent = {k: next(iter(v.values())) for k, v in pairs.items() if len(v) == 1}
    conflicts = {k: sorted(v.values()) for k, v in pairs.items() if len(v) > 1}
    print('consistent substitutions', len(consistent), 'conflicting (left alone)', conflicts)
    changed = {}
    for tests in ('compat/lll-0.1.14/tests', 'tests'):
        (out / tests).mkdir(parents=True, exist_ok=True)
        for path in sorted((original / tests).glob('*')):
            if not path.is_file(): continue
            text = path.read_text()
            # ui_material_readiness.lua keeps the original 24-byte prologues (assemble.py KEEP); its fixture must match them,
            # while the same prologue elsewhere was extended to the port's whole-body witness.
            skip = {'4053415641574883EC30488B02488BD98B89C00200004533', '4C894424184889542410535556574155415641574883EC30'} \
                if path.name == 'ui_material_fixture.lua' else set()
            def sub(m):
                lit = m.group(0)
                new = consistent.get(lit.upper())
                if new is None or lit.upper() in skip: return lit
                changed[path.name] = changed.get(path.name, 0) + 1
                return new
            text = re.sub(r'0[xX][0-9A-Fa-f]+|(?<![0-9A-Za-z])[0-9a-f]{16,}(?![0-9A-Za-z])', sub, text)
            # The player-control row moved by 8 bytes (pc+0xFD0 -> +0xFD8, as the sources); 0xFD0 alone is
            # ambiguous because backend.lua's 12-byte precheck window moved differently.
            text = re.sub(r'(pc\+|0x53D8B0\+)0xFD0\b', lambda m: m.group(1) + '0xfd8', text)
            # Two support weapons were added after 0.1.17 (LAS-44 Nova, AMW-20 Apex, no backpacks): 35 rows now.
            # main.lua now also loads the warm-up (src/code_warmup.lua, src/code_warmup_sites.lua); the restart fixture's
            # require stub must answer for them with an inert warm-up.
            for needle, new in (('#catalogue==33', '#catalogue==35'), ('assert(count==31)', 'assert(count==33)'),
                                ('and count==8)', 'and count==9)'), ('and8 matching backpacks', 'and9 matching backpacks'),
                                ("    if path=='src/terminal_render.lua'then return {}end\n",
                                 "    if path=='src/terminal_render.lua'then return {}end\n"
                                 "    if path=='src/code_warmup.lua'then return {new=function()return{done=true,step=function()return true end}end}end\n"
                                 "    if path=='src/code_warmup_sites.lua'then return {stamp=0,sites={}}end\n")):
                if needle in text: text = text.replace(needle, new); changed[path.name] = changed.get(path.name, 0) + 1
            if path.name == 'runtime_fixture.lua':  # 26251122 .8: Armory HUD pause (hud_pause_tests.lua, same local harness)
                text += (Path(__file__).resolve().parent / 'hud_pause_tests.lua').read_text(); changed[path.name] = changed.get(path.name, 0) + 1
                # .11: the runtime builds src/equipment_hold.lua (and loads its catalogue); the shared stand-in runtime gets an
                # always-acknowledged equipment owner, the real-import test counts the two modules, and the .11 tests ride along.
                for needle, new in (('        ammo_station=ammo,support=support,\n',
                                     '        ammo_station=ammo,support=support,\n'
                                     "        equipment=options.equipment or {hold=function()return true end,drain=function()return true end,status=function()return '0 equipment package holds'end},\n"),
                                    ('eq(#imports,23)', 'eq(#imports,25)')):
                    assert text.count(needle) == 1, needle
                    text = text.replace(needle, new); changed[path.name] += 1
                text += (Path(__file__).resolve().parent / 'equipment_runtime_tests.lua').read_text(); changed[path.name] += 1
            if path.name == 'package_lease_fixture.lua':  # 26251122 .12: other wielders present (multiplayer session)
                needle = "print('Package lease fixtures: "; assert text.count(needle) == 1
                text = text.replace(needle, (Path(__file__).resolve().parent / 'wielder_bound_tests.lua').read_text() + needle)
                changed[path.name] = changed.get(path.name, 0) + 1
            (out / tests / path.name).write_text(text)
    # Fixtures reach their sources as tests/../src; run_lua_fixtures.py builds a test root where that resolves.
    (out / 'port-fixtures-report.json').write_text(json.dumps({'substitutions': consistent, 'conflicts': conflicts, 'changed': changed}, indent=1) + '\n')
    print('fixture files with changes', changed)


if __name__ == '__main__':
    main()
