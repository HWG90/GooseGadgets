"""Assemble Bridge Combat 0.1.17 (the Windows original) for game 26251122.

Sources: the release tree (GooseGadgets Bridge Combat/terminal-0.1.14, its compat/lll-0.1.14 package layout),
unport.py's output (every address line matched to the proven LuaJIT port), the LuaJIT port itself for the
two support-weapon rows and their icons, the warm-up module and its generated site table, and the rebuilt
weapon menu DLL. Every hand-resolved address below names the line it changes and asserts the old text.

Usage: python3 -I assemble.py ORIGINAL_ROOT UNPORT_OUT PORT_SRC WEAPON_MENU_DLL OUT_DIR
"""
import hashlib, json, re, sys
from pathlib import Path

VERSION = '0.1.17-experimental-26251122.12'
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
         'needs one per frame once the ship is observed, before the hotkey is accepted; no game memory is written. '
         'From .11 combat controls arm only once every loaded loadout and weapon attachment package carries a Bridge '
         'reference, and a reference is returned only once the game has let the package go and no live unit (a dropped '
         'magazine, a casing) still holds one of its units, so an Armory weapon swap cannot unload a resource such a unit '
         'holds. While the native weapon menu is lost outside a ship menu (the Armory), the bridge animation pauses and '
         're-initializes for the new loadout afterwards (.8, first lost step since .10). From .12 the bridge animation also '
         'initializes with other wielders present (a multiplayer session): the Wielder manager field the 0.1.17 lease read as a '
         'row capacity is not one, and the local row is bounded by the manager\'s count.')
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
    # .6/.7: the Apex's backpack. The game's tables name no pack for it; the authored pickup table's indices run in
    # internal-name order and the Apex's stratagem is "SniperRifleDuo", which places its pack at the unnamed row 234
    # (type 0949eeb3dc920324, package 6f09a6ce25c8ca77, id 780093772). Tried as .6 on 2026-10-31 and confirmed by
    # the user in game: the pack equips and feeds the weapon. Row 230 (id 4010403312) is the other unnamed pack.
    edit(out / 'src/support_catalogue.lua',
         '    {name="AMW-20 Apex",id=3082503125,kind=2,type="b814eece17533bc4",package="a193a00ce4bbd529"},\n',
         '    {name="AMW-20 Apex",id=3082503125,kind=2,type="b814eece17533bc4",package="a193a00ce4bbd529",'
         'backpack={name="AMW-20 Apex backpack",id=780093772,kind=6,type="0949eeb3dc920324",package="6f09a6ce25c8ca77"}},\n')
    edit(out / 'src/support_catalogue.lua', '-- New rows go last:', '-- Apex backpack: authored row 234 (unnamed in the game tables), confirmed in game 2026-10-31.\n-- New rows go last:')
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
    # .5: keys built from an address's text. LuaJIT prints numbers with 14 significant digits, so two addresses
    # within a few bytes of each other can share a key once the module sits high enough (2026-10-30 21:49: the
    # PE signature at game+0x108 and the stamp at game+0x110 collided, every enable failed). Exact keys instead.
    edit(out / 'src/animation_io.lua', "        local key = tostring(at)..':'..n\n", "        local key = ('%X:%d'):format(at,n)\n")
    edit(out / 'src/animation_io.lua', "            local key=abi..':'..tostring(address)..':'..fingerprint:lower()\n",
         "            local key=abi..':'..('%X'):format(address)..':'..fingerprint:lower()\n")
    edit(out / 'src/backend.lua', "            local key=spec[2]..':'..tostring(game+spec[1])\n", "            local key=spec[2]..':'..('%X'):format(game+spec[1])\n")
    # .4: when a read repeated inside one resolve differs, say which address and both values (the 2026-10-30
    # 21:28 enable failed 31 times with this message and nothing to go on). The prefix is unchanged.
    edit(out / 'src/animation_io.lua',
         "        if samples[key] then assert(samples[key].value==value, 'identity changed during observation')\n",
         "        if samples[key] then\n"
         "            if samples[key].value~=value then\n"
         "                error(('identity changed during observation at %X (%d bytes): %s then %s'):format(at,n,hex(samples[key].value),hex(value)))\n"
         "            end\n")
    # Current War Journalist publishes DBF_PHOTO_MODE_OWNER; the original only knew the upvalue discovery.
    edit(out / 'src/runtime.lua', 'local function photo_state(globals)\n', PHOTO_OWNER)
    # .8 (2026-10-31/11-01): the one-shot latch never updated the animation once combat was ready, so the pose and its
    # leases outlived an Armory visit and its weapon swap. Now: the native weapon menu is lost whenever the game replaces
    # the HUD; with no ship menu open that is the Armory (or another terminal). The runtime then marks hud_pause, the
    # animation observer reports not ready (pose restored, clips and assets released through the existing cleanup), and
    # once the menu is owned again the runtime un-latches so the ordinary path re-initializes the animation for the new
    # loadout and latches again. .8 was built on a wrong cause: the four Armory crashes (10-31 23:51, 23:54, 11-01 00:08
    # on .6; 14:53 on .9) are the engine's fatal check in the resource release (exe+0x635b43, reached from the swap's own
    # package unload) on a magazine attachment unit that a live unit still held, not on a clip. The pause timing does
    # not decide whether a swap is safe; .11's equipment holds (below) do.
    runtime = out / 'src/runtime.lua'
    edit(runtime, "    local weapon_ui_paused,weapon_resume_delay=false,0\n",
         "    local weapon_ui_paused,weapon_resume_delay=false,0\n"
         "    -- .8: the native weapon menu is lost whenever the game replaces the HUD; with no ship menu open\n"
         "    -- that is the Armory (or another terminal). hud_pause restores the pose there and re-initializes it after.\n"
         "    local hud_pause,hud_owned=false,false\n")
    edit(runtime, "        return {token=observation.token,ready=observation.ready==true and owned,\n"
                  "            hold=observation.hold==true and owned,\n"
                  "            reason=not owned and 'Waiting for acknowledged bridge controls' or observation.reason}\n",
         "        return {token=observation.token,ready=observation.ready==true and owned and not hud_pause,\n"
         "            hold=observation.hold==true and owned and not hud_pause,\n"
         "            reason=not owned and 'Waiting for acknowledged bridge controls' or hud_pause and 'Native weapon menu unavailable (Armory or HUD change)' or observation.reason}\n")
    edit(runtime, "    -- Publish lifecycle changes through the retained station UI, not a timer.\n    local function publish_progress()\n",
         "    -- .8: while the native menu is lost outside a ship menu (the Armory), the animation observer reports\n"
         "    -- not ready, so the pose is restored and its leases released; once the menu is owned again the ordinary\n"
         "    -- path re-initializes the animation for the current loadout and latches. Whether a weapon swap may\n"
         "    -- unload a package is decided by the equipment holds (.11), not by this timing.\n"
         "    local function track_hud(acquired)\n"
         "        if acquired then\n"
         "            hud_owned=true\n"
         "            if hud_pause then hud_pause=false;log('Native weapon menu owned again; the bridge animation resumes')end\n"
         "        elseif hud_owned and weapon_menu:is_clean()and not hud_pause then\n"
         "            -- .10: pause on the first evaluation that finds the menu retired, as .8 did live (.9 debounced\n"
         "            -- half a second, and the Armory re-acquired its rebuilt menu first). A loss on an unreadable\n"
         "            -- observation is eligible (.9). Photo Mode retires the menu too; its camera hold keeps the pose\n"
         "            -- and stays authoritative; a ship menu (ESC) keeps the one-shot pose.\n"
         "            if self.enabled and(not observation or observation.menu_closed==true and observation.hold~=true and observation.photo~=true)then\n"
         "                hud_pause=true;log('Native weapon menu lost outside a ship menu (Armory): pausing the bridge animation')\n"
         "            end\n"
         "        end\n"
         "    end\n"
         "    -- Publish lifecycle changes through the retained station UI, not a timer.\n    local function publish_progress()\n")
    edit(runtime, "        if not value then self.latched=false;weapon_ui_paused=false;weapon_resume_delay=0 end\n",
         "        if not value then self.latched=false;weapon_ui_paused=false;weapon_resume_delay=0;hud_pause=false;hud_owned=false end\n")
    edit(runtime, "                if weapon_resume_delay>0 then return true end\n                weapon_resume_delay=.25\n",
         "                if weapon_resume_delay>0 then\n"
         "                    if hud_pause then animation:update(dt)end -- .8: restore the pose while paused\n"
         "                    return true\n"
         "                end\n"
         "                weapon_resume_delay=.25\n")
    edit(runtime, "                    local done,why=weapon_menu_step(dt)\n"
                  "                    if done==true and not weapon_menu:is_clean()then\n"
                  "                        weapon_ui_paused=false;weapon_menu_reason=nil\n"
                  "                    else weapon_menu_reason=why end\n",
         "                    local done,why=weapon_menu_step(dt)\n"
         "                    track_hud(done==true and not weapon_menu:is_clean())\n"
         "                    if hud_pause then animation:update(dt)end\n"
         "                    if done==true and not weapon_menu:is_clean()then\n"
         "                        weapon_ui_paused=false;weapon_menu_reason=nil\n"
         "                        -- .8: a paused animation re-initializes through the ordinary path and latches again.\n"
         "                        if not animation:is_ready()then self.latched=false end\n"
         "                    else weapon_menu_reason=why end\n")
    edit(runtime, "            local menu_done,menu_why=weapon_menu_step(dt)\n            if menu_done~=true then return false,menu_why end\n",
         "            local menu_done,menu_why=weapon_menu_step(dt)\n"
         "            track_hud(menu_done==true and not weapon_menu:is_clean())\n"
         "            if menu_done~=true then return false,menu_why end\n")
    # .11: the four Armory crashes are the engine's resource release refusing to unload a magazine attachment unit
    # that a live unit still held (exe+0x635b43; MurmurHash64A names from the dumps). Firing and reloading on the ship
    # leave units of the equipped weapon's packages in the world; stock HD2 never reloads there, so the Armory's swap
    # never meets them. A magazine attachment ships in a one-unit package of its own (game data, pkgscan listing), which
    # the animation's loadout-package lease never held. src/equipment_hold.lua keeps one counted reference (the game's
    # own wrapper, as the support and animation package journals do) on every loaded loadout/attachment package of
    # src/equipment_packages.lua while combat is on, taken before combat controls arm, and returns a reference only
    # when the game has let the package go and the engine's live-unit hold map holds none of its unit resources.
    (out / 'src/equipment_hold.lua').write_bytes((Path(__file__).resolve().parent / 'equipment_hold.lua').read_bytes())
    (out / 'src/equipment_packages.lua').write_bytes((Path(__file__).resolve().parent / 'equipment_packages.lua').read_bytes())
    edit(runtime, "    local observation,observation_reason\n",
         "    local observation,observation_reason\n"
         "    -- .11 (Armory swap fatal, four crashes 10-31/11-01): ship combat leaves units of the equipped weapon's\n"
         "    -- packages in the world (a reload drops a magazine attachment unit), and the Armory's swap must not unload\n"
         "    -- a package such a unit still holds. Combat controls arm only once every loaded loadout and attachment\n"
         "    -- package carries a Bridge hold; holds refresh while combat is on and drain in every state.\n"
         "    local equipment=options.equipment or load('src/equipment_hold.lua').new(io,{globals=options.globals,log=log,\n"
         "        catalogue=load('src/equipment_packages.lua')})\n"
         "    local equipment_ready,equipment_reason,equipment_wait,equipment_drain_wait=false,nil,0,0\n"
         "    local function equipment_hold()\n"
         "        local held,why=equipment:hold()\n"
         "        equipment_wait=held==true and 1 or .25 -- a new weapon needs its hold before a later swap, seconds away\n"
         "        local reason=held~=true and tostring(why or 'Equipment holds pending')or nil\n"
         "        if reason and reason~=equipment_reason then log('Equipment hold: '..reason)end\n"
         "        equipment_ready,equipment_reason=held==true,reason\n"
         "        return equipment_ready\n"
         "    end\n"
         "    local function equipment_step(dt)\n"
         "        dt=type(dt)=='number'and math.max(0,math.min(dt,1))or .016\n"
         "        equipment_wait,equipment_drain_wait=math.max(0,equipment_wait-dt),math.max(0,equipment_drain_wait-dt)\n"
         "        if not self.enabled then equipment_ready=false\n"
         "        elseif observation and equipment_wait<=0 then equipment_hold()end\n"
         "        if equipment_drain_wait<=0 then\n"
         "            equipment_drain_wait=2\n"
         "            local drained,why=equipment:drain()\n"
         "            if drained~=true and tostring(why)~=equipment_reason then equipment_reason=tostring(why);log('Equipment hold: '..equipment_reason)end\n"
         "        end\n"
         "    end\n")
    edit(runtime, "            or not ui_assets_ready or not fx_assets_ready then return end\n",
         "            or not ui_assets_ready or not fx_assets_ready then return end\n"
         "        -- .11: no shot before every loaded loadout/attachment package carries a Bridge hold.\n"
         "        if not base.active and not equipment_ready and(equipment_wait>0 or not equipment_hold())then return end\n")
    edit(runtime, "        if self.reinitialize then return true end\n",
         "        if self.reinitialize then return true end\n"
         "        equipment_step(dt)\n")
    edit(runtime, "        if self.enabled and weapon_menu_reason then return animation:status()..' / Native weapon menu unavailable'end\n",
         "        if self.enabled and weapon_menu_reason then return animation:status()..' / Native weapon menu unavailable'end\n"
         "        if self.enabled and not equipment_ready and equipment_reason then return animation:status()..' / Equipment holds pending: '..equipment_reason end\n")
    # .12 (2026-11-01 23:35Z, "combat not loading" in a 4-player session the user had joined as a client): the Wielder
    # manager (game+0x2ce1fd0) held 105-148 rows, and the field the 0.1.17 live lease read as the row capacity (+0x20)
    # read 1 in every live sample, so `count <= capacity` only ever passed while the local avatar was the only wielder
    # (a solo ship). The engine's own hand-row accessors (game+0x790a50 and +0x791290 in the capture) touch the map
    # (+0x30..+0x40), the descriptors (+0x48) and the rows (+0x60), never +0x1C/+0x20 as bounds. The user wants combat
    # to load in a multiplayer session: the row is bounded by the count, and the descriptor ownership check that
    # follows each site validates the row. Tests: wielder_bound_tests.lua (package lease), roster_observer_fixture.lua.
    edit(out / 'src/animation_packages.lua',
         "            local wc,wcap=number32(take(wm+0x1C,4)),number32(take(wm+0x20,4))\n"
         "            assert(wc<=wcap and wcap<=4096 and wi<wc,'Wielder live row refused')\n",
         "            -- .12: +0x20 is not the row capacity (it reads 1 with 105-148 live rows); the count bounds the row.\n"
         "            local wc=number32(take(wm+0x1C,4))\n"
         "            assert(wc<=4096 and wi<wc,'Wielder live row refused')\n")
    edit(runtime, "        assert(wi<u32(manager+0x1C) and u32(manager+0x1C)<=u32(manager+0x20)\n"
                  "            and u32(manager+0x20)<=65536,'Cleanup Wielder row changed')\n",
         "        assert(wi<u32(manager+0x1C) and u32(manager+0x1C)<=65536,'Cleanup Wielder row changed') -- .12: +0x20 is not a capacity\n")
    edit(out / 'src/support_weapons.lua',
         "        local ww=p(c.game+0x2ce1fd0);local n=u(ww+0x1C);assert(n<=256 and n<=u(ww+0x20),'Floor cleanup Wielder bound differs')\n",
         "        local ww=p(c.game+0x2ce1fd0);local n=u(ww+0x1C);assert(n<=4096,'Floor cleanup Wielder bound differs') -- .12: other wielders present; +0x20 is not a capacity\n")
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
