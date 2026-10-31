"""Assemble Bridge Combat 0.1.17 (the Windows original) for game 26251122.

Sources: the release tree (GooseGadgets Bridge Combat/terminal-0.1.14, its compat/lll-0.1.14 package layout),
unport.py's output (every address line matched to the proven LuaJIT port), the LuaJIT port itself for the
two support-weapon rows and their icons, the warm-up module and its generated site table, and the rebuilt
weapon menu DLL. Every hand-resolved address below names the line it changes and asserts the old text.

Usage: python3 -I assemble.py ORIGINAL_ROOT UNPORT_OUT PORT_SRC WEAPON_MENU_DLL OUT_DIR
"""
import hashlib, json, re, sys
from pathlib import Path

VERSION = '0.1.17-experimental-26251122.3'
LOCAL_FILES = ('main.lua', 'manifest.json', 'config/defaults.cfg', 'LICENSE', 'README.md', 'TERMINAL-ICONS.md')
# (file, line, old literal, new literal, why): lines unport.py could not match because the port rewrote them.
HAND = [
    ('backend.lua', 274, '0x347CF20', '0x3382000', 'game.dll SizeOfImage on 26251122 (the original used the 6AB3B43F size as the minimum)'),
    ('animation_io.lua', 5, '0x347CF20', '0x3382000', 'game.dll SizeOfImage on 26251122'),
    ('animation_io.lua', 5, '0x1A100F8', '0x1AB7700', 'exe actor registry (exe+0x1AB76F8, the port) plus 8, as the original defined it'),
    ('support_weapons.lua', 115, '0x1A10238', '0x1AB7838', 'exe resource root: the port, support_weapons.lua stable()'),
    ('wall_terminal_assets.lua', 44, '0x346D538', '0x2E28788', 'game UI/chat global: the port, wall_terminal_assets.lua'),
    ('wall_terminal_assets.lua', 46, '0x346D538', '0x2E28788', 'game UI/chat global: the port, wall_terminal_assets.lua'),
    ('ui_package_lease.lua', 34, '0x3326308', '0x2ce14c8', 'engine API root: the port, ui_package_lease.lua'),
    ('ui_package_recovery.lua', 27, '0x347CEB0', '0x2e381e8', 'package manager global: the port, ui_package_recovery.lua'),
    ('ui_package_recovery.lua', 27, '0x3326308', '0x2ce14c8', 'engine API root: the port, ui_package_recovery.lua'),
    # Package API thunks: the port keeps whole thunk bodies; the original compares #hex/2 bytes, so the
    # exact thunk (no padding, which the protector refills) and the first 24 bytes of the longer one.
    ('ui_package_lease.lua', 6, '0x320DD0', '0x2f01e0', 'exe package API thunk 0x2F0: the port'),
    ('ui_package_lease.lua', 6, '488bd1488b0d2ef46e01488b8900040000e98a282e00cccc', '488bd1488b0d1e767c01488b8900040000e97a333500', 'the port'),
    ('ui_package_lease.lua', 7, '0x321030', '0x2f0440', 'exe package API thunk 0x300: the port'),
    ('ui_package_lease.lua', 7, '488bd1488b0dcef16e01488b8900040000e93a2a2e00cccc', '488bd1488b0dbe737c01488b8900040000e92a353500', 'the port'),
    ('ui_package_lease.lua', 8, '0x321450', '0x2f0860', 'exe package API thunk 0x328: the port'),
    ('ui_package_lease.lua', 8, '48895c2408574883ec20488b05a7ed6e01488bd1488bf948', '48895c2408574883ec20488b05976f7c01488bd1488bf948', 'the port, first 24 bytes'),
]
# Like HAND, but not a build-constant substitution the fixtures should share (port_fixtures.py reads HAND only).
HAND_ONLY = [
    ('backend.lua', 353, 'pc + 0xFE0, 12', 'pc + 0xFD8, 12',
     'the three control words start at pc+0xFD8 on this build (controller.lua); the port read its 12-byte readability window 8 bytes late'),
]
# Lines unport.py could not match whose literals are not addresses (masks, table offsets, SHA-256 constants).
KEEP = {('terminal_services.lua', 55), ('ship_return.lua', 24), ('backend.lua', 168), ('support_weapons.lua', 214),
        ('sha256.lua', 6), ('sha256.lua', 7), ('sha256.lua', 8), ('sha256.lua', 9), ('sha256.lua', 10),
        ('animation_io.lua', 212), ('ship_visibility.lua', 16), ('ship_visibility.lua', 17),
        ('ui_material_readiness.lua', 11), ('ui_material_readiness.lua', 14)}
PHOTO_OWNER = """local function photo_state(globals)
    -- Current War Journalist publishes an acknowledged lifecycle state. Unknown or closing
    -- states retain the block; the original discovery below remains for older versions.
    local current=rawget(globals,'DBF_PHOTO_MODE_OWNER')
    if current~=nil then
        assert(type(current)=='table'and type(current.active)=='boolean','Photo Mode lifecycle owner is unreadable')
        if current.active then return true,true,tostring(current) end
        assert(current.state=='closed','Photo Mode cleanup is not acknowledged')
        return false,false,tostring(current)
    end
"""
WARMUP_CALL = """        -- 26251122: the game decrypts a code page on first execution. Once the ship actor is observed, one
        -- page per frame gets one ret executed on it (src/code_warmup.lua), so every page Bridge checks or
        -- calls is readable before combat arms. Running the table inside this enable killed the process.
        warm=mod.require('src/code_warmup.lua').new({sites=mod.require('src/code_warmup_sites.lua'),log=log})
"""
WARMUP_STEP = """        if warm and not warm.done and controller.preload_requested then
            local ok,why=pcall(warm.step,warm)
            if not ok then warm.done=true;log('Code warm-up failed: '..tostring(why))end
        end
"""

def edit(path, old, new, count=1):
    s = path.read_text()
    assert s.count(old) == count, (path.name, old[:60], s.count(old))
    path.write_text(s.replace(old, new))


def main():
    original, unported, port, dll, out = (Path(a) for a in sys.argv[1:6])
    compat = original / 'compat/lll-0.1.14'
    if out.exists():
        import shutil; shutil.rmtree(out)
    (out / 'src').mkdir(parents=True); (out / 'native').mkdir(); (out / 'config').mkdir()
    for name in LOCAL_FILES:
        (out / name).write_bytes((compat / name).read_bytes())
    # The package README is the 0.1.17 text; its supported-builds line and build note are this build's.
    edit(out / 'README.md', 'Supported game/executable builds: `6AB3B43F` / `6AB382E4`.',
         'Supported game/executable builds: `6AE0E5FF` / `6AE0964A` (Steam build 26251122; package ' + VERSION + '). '
         'The 7.2.0 game update keeps code pages encrypted until first executed, so this build warms every page it '
         'needs one per frame once the ship is observed, before the hotkey is accepted; no game memory is written.')
    edit(out / 'README.md', '## Build\n\n', '## Build\n\nThis package was assembled from the 0.1.17 source by `terminal-26251122/tools` '
         '(GooseGadgets); the original build steps below are the 0.1.17 ones.\n\n')
    report = json.loads((unported / 'unport-report.json').read_text())
    unresolved = {(u['file'], u['line']) for u in report['unresolved']}
    for src in sorted((unported / 'src').glob('*.lua')):
        (out / 'src' / src.name).write_bytes(src.read_bytes())
    handled = set()
    for name, line, old, new, _why in HAND:
        path = out / 'src' / name; lines = path.read_text().split('\n')
        assert old in lines[line - 1], (name, line, old)
        lines[line - 1] = lines[line - 1].replace(old, new, 1)
        path.write_text('\n'.join(lines)); handled.add((name, line))
    for name, line, old, new, _why in HAND_ONLY:
        path = out / 'src' / name; lines = path.read_text().split('\n')
        assert old in lines[line - 1], (name, line, old)
        lines[line - 1] = lines[line - 1].replace(old, new, 1); path.write_text('\n'.join(lines))
    missing = unresolved - handled - KEEP
    assert not missing, 'unresolved address lines without a decision: %s' % sorted(missing)
    assert not (KEEP & handled)
    # The original keeps its 24-byte material/fetch prologues; the port's longer bodies start with them.
    ptext = (port / 'ui_material_readiness.lua').read_text()
    for prologue in ('4053415641574883ec30488b02488bd98b89c00200004533', '4c894424184889542410535556574155415641574883ec30'):
        assert prologue in ptext
    # Weapon additions since 0.1.17: the port's catalogue and icon rows carry no addresses.
    for name in ('support_catalogue.lua', 'terminal_icons.lua'):
        (out / 'src' / name).write_bytes((port / name).read_bytes())
    assert 'LAS-44 Nova' in (out / 'src/support_catalogue.lua').read_text() and '[35]=' in (out / 'src/terminal_icons.lua').read_text()
    # Blend pairs: on 26088801 and later [world+0xF12E30] is null and the definition table is not loaded
    # (the port's animation_blend.lua), so the controller skips that one step; both files are the originals
    # plus that gate and the 26251122 literals.
    for name in ('animation_blend.lua', 'animation_controller.lua'):
        (out / 'src' / name).write_bytes((port / name).read_bytes())
    assert 'supported=false' in (out / 'src/animation_blend.lua').read_text() and 'deps.blend.supported==false' in (out / 'src/animation_controller.lua').read_text()
    # Base locomotion definition table: 412 entries on 26088801 and later (the port, proven live).
    backend = out / 'src/backend.lua'
    edit(backend, 'self:read(table_address, 408 * 16)', 'self:read(table_address, 412 * 16)')
    edit(backend, 'for i = 0, 407 do', 'for i = 0, 411 do')
    edit(backend, 'index >= 408 then', 'index >= 412 then')
    # Current War Journalist publishes DBF_PHOTO_MODE_OWNER; the original only knew the upvalue discovery.
    edit(out / 'src/runtime.lua', 'local function photo_state(globals)\n', PHOTO_OWNER)
    # The one addition for the packer: warm every page before the first native check.
    here = Path(__file__).resolve().parent
    (out / 'src/code_warmup.lua').write_bytes((here / 'code_warmup.lua').read_bytes())
    # The warm-up table covers exactly the pages this tree's witnesses and the DLL's sit on: verify both
    # against the 26251122 capture (every located witness must be 'same'), then pick a ret per page.
    import subprocess
    ws = Path('/home/goose/Projects/Linux HD2 Mods/builds/26251122')
    verify = {}
    for tag, root, files in (('lua', out, sorted('src/' + p.name for p in (out / 'src').glob('*.lua'))),
                             ('dll', dll.parent, ['native/weapon_menu.cpp'])):
        vreport = out.parent / ('verify-original-%s.json' % tag)
        subprocess.run([sys.executable, '-I', str(ws / 'maps/bridge/witnesses.py'), str(vreport), str(root)] + files,
                       check=True, env={**__import__('os').environ, 'HD2_BRIDGE_VERIFY': '1'}, stdout=subprocess.DEVNULL)
        rows = json.loads(vreport.read_text())
        bad = [r for r in rows if r.get('status') not in ('same', 'resource-id', 'nowhere', 'ambiguous')]
        assert not bad, [(r.get('status'), r.get('uses')) for r in bad][:5]
        ambiguous = [r for r in rows if r.get('status') == 'ambiguous']
        # Position-independent prologues the mod searches for at runtime (wall_camera) and a zero constant.
        assert all(any(u['file'] in ('src/wall_camera.lua', 'src/support_weapons.lua') for u in r['uses']) for r in ambiguous), ambiguous
        verify[tag] = {'rows': len(rows), 'same': sum(1 for r in rows if r.get('status') == 'same')}
    sites = out / 'src/code_warmup_sites.lua'
    with open(sites, 'w') as f:
        run = subprocess.run([sys.executable, '-I', str(here / 'warmup_sites.py'), str(ws / 'capture/game-6ae0e5ff.merged.bin'),
                              str(out.parent / 'verify-original-lua.json'), str(out.parent / 'verify-original-dll.json'),
                              '--rva', '0x1697cb0', '--rva', '0x169f0a0', '--rva', '0x169acc0', '--rva', '0x169fde0'],
                             check=True, stdout=f, stderr=subprocess.PIPE, text=True)
    assert 'missing []' in run.stderr, run.stderr
    main_lua = out / 'main.lua'
    edit(main_lua, "        local Runtime = mod.require('src/runtime.lua')\n", WARMUP_CALL + "        local Runtime = mod.require('src/runtime.lua')\n")
    edit(main_lua, 'local controller, menu, bindings, services\n', 'local controller, menu, bindings, services, warm\n')
    edit(main_lua, '    controller, menu, bindings = nil, nil, nil\n', '    controller, menu, bindings, warm = nil, nil, nil, nil\n')
    edit(main_lua, '        controller:update(dt)\n', WARMUP_STEP + '        controller:update(dt)\n')
    edit(main_lua, "            allowed=function()return menu:hotkey_allowed() and controller:hotkey_allowed()end,\n",
         "            allowed=function()return (not warm or warm.done) and menu:hotkey_allowed() and controller:hotkey_allowed()end,\n")
    # Native weapon menu: the rebuilt original DLL, named and pinned as the release build does.
    data = dll.read_bytes(); sha = hashlib.sha256(data).hexdigest()
    native_name = 'native/BridgeCombatWeaponMenu-%s.dll' % sha[:12]
    (out / native_name).write_bytes(data)
    (out / 'src/weapon_menu_binary.lua').write_text(
        '-- Generated from the rebuilt original weapon menu (native-work/bridge-original).\n'
        'return {available=true,file=%s,sha256=%s,bytes=%d}\n' % (json.dumps(native_name), json.dumps(sha), len(data)))
    manifest = json.loads((out / 'manifest.json').read_text())
    assert manifest['version'] == '0.1.17-experimental'
    manifest['version'] = VERSION
    manifest['description'] = 'Bridge combat with a fixed equipment terminal, focused mouse controls, resupply and support weapons.'
    manifest['native'] = {'file': native_name, 'sha256': sha, 'api': 1}
    modules = sorted('src/' + p.name for p in (out / 'src').glob('*.lua'))
    assert set(manifest['lll']['modules']) <= set(modules), set(manifest['lll']['modules']) - set(modules)
    manifest['lll']['modules'] = modules
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    receipt = {'version': VERSION, 'weapon_menu': {'file': native_name, 'sha256': sha, 'bytes': len(data)}, 'verify': verify,
               'warmup_sites': sites.read_text().count('\n {'),
               'unport': {'changed_lines': report['changed_lines'], 'hand': [h[:4] for h in HAND + HAND_ONLY], 'keep': sorted(KEEP)},
               'files': {str(p.relative_to(out)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(out.rglob('*')) if p.is_file()}}
    (out.parent / (out.name + '-RECEIPT.json')).write_text(json.dumps(receipt, indent=1) + '\n')
    print('assembled', out, len(receipt['files']), 'files; modules', len(modules))


if __name__ == '__main__':
    main()
