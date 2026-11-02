# Bridge Combat 0.1.17 on Steam build 26251122

The 0.1.17 Experimental Armory terminal ([terminal-0.1.14](../terminal-0.1.14/README.md)) rebuilt for the game as updated on 2026-10-29 (Steam build 26251122, game `6AE0E5FF`, executable `6AE0964A`), with the two support weapons added since 0.1.17: LAS-44 Nova and AMW-20 Apex. The design is the 0.1.17 one: read a function's prologue, then call it; no instruction patches, no page-protection changes, no game memory written. One module is new, because of what the 7.2.0 game update changed.

Package: `goose_bridge_combat/`, version `0.1.17-experimental-26251122.12`, LLL only (Live Lua Loader, LuaJIT build); [download](https://github.com/HWG90/GooseGadgets/releases/tag/bridge-combat-0.1.17-26251122.12-20261102). Its hashes are in `goose_bridge_combat-RECEIPT.json`. The first published build was `.3` ([its release](https://github.com/HWG90/GooseGadgets/releases/tag/bridge-combat-0.1.17-26251122-20261030), superseded); `.12` adds the fixes below, from the Apex backpack to combat in multiplayer sessions.

## What 7.2.0 changed

Before 7.2.0 the game's code was readable in memory once loaded. From 7.2.0 (build 26088801) the executable loads `preloader.dll`, which maps `bin/runtime.dll`; that runtime keeps every code page of `game.dll` and the executable encrypted (PAGE_NOACCESS) until the game first executes it. The game's own code barely moved, but on the ship, before any mission, the pages Bridge Combat checks before calling are still encrypted: the weapon wheel, the support drop, the ammo pickup, the stamina bar constructor. The 0.1.17 package therefore refused on the ship.

`src/code_warmup.lua` and `src/code_warmup_sites.lua` are the one addition. For every `game.dll` page any witness of this tree or of the native menu sits on (44 pages), the table holds one one-byte `ret` on that page, found in a decrypted capture by following the code from real call and jump targets, with the eight bytes at the site. Once the runtime has observed the ship actor, `main.lua` steps the warm-up one page per frame: a page that is still unreadable is checked with VirtualQuery (committed, no-access, image or mapped), logged, then gets one FFI call to its `ret`; the game's handler decrypts the page; the eight bytes are read back and must match the capture. The combat hotkey waits for the warm-up to finish. Running the whole table inside the loader's enable at boot ended the process, so the stepped form is the only one shipped.

## How the port was made

| Step | Tool | Evidence |
| --- | --- | --- |
| Lua addresses | `tools/unport.py` | every address line of the 0.1.17 source matched, with addresses masked, to a proven LuaJIT port of the same files on this build; the literals copied in order; 283 lines changed, the rest listed in `evidence/unport-report.json` |
| Hand-finished lines | `tools/assemble.py` (`HAND`, `HAND_ONLY`, `KEEP`) | each names the line, the old literal, the new one and its source |
| Witnesses | the build workspace's witness checker | every located witness of the assembled tree is `same` against the 26251122 capture (`evidence/verify-original-lua.json`); the native source likewise (`evidence/verify-original-dll.json`) |
| Native weapon menu | `tools/unport_cpp.py`, `tools/build_dll.py` | the release `weapon_menu.cpp` with health and stamina bars; 32 shared ABI rows moved by two recorded maps, the four vitals functions with prologues from the capture; Zig 0.14.1, x86_64-windows-gnu; the release fixture moved the same way passes all 110 modes under Wine (`native/weapon-menu-build-receipt.json`) |
| Lua fixtures | `tools/port_fixtures.py`, `tools/run_lua_fixtures.py` | the release fixtures given the sources' own build-constant substitutions (`tests-ported/`), run with LuaJIT, with the fixtures added since `.3` (`tools/*_tests.lua`, `tools/*_fixture.lua`): 35 of 35 (`evidence/lua-fixture-results.json`) |

Decisions that are not address swaps:

- `support_catalogue.lua`, `terminal_icons.lua`: LAS-44 Nova and AMW-20 Apex added (icons 34 and 35). The Apex row carries its backpack (authored pickup row 234, id 780093772): the game's tables name no pack for the Apex, but the authored table runs in internal-name order and the Apex's stratagem is "SniperRifleDuo", which places its pack at that unnamed row; tried as `.6` and confirmed in game on 2026-10-31, the pack equips and feeds the weapon.
- `backend.lua`: 412 base locomotion definitions (408 on the 0.1.17 build); the control-word window starts at `pc+0xFD8`, the row having moved by 8 bytes.
- `animation_blend.lua`, `animation_controller.lua`: on 26088801 and later the blend-pair definition table is not loaded, so `supported=false` and the controller skips that step. `blend_pairs_fixture.lua` is therefore not run.
- `runtime.lua` `photo_state`: the current War Journalist publishes `DBF_PHOTO_MODE_OWNER`; that branch is read ahead of the 0.1.17 discovery.
- `main.lua`: the warm-up above; `start_off` behaviour kept.
- Not run: `ffi_binding_cache_fixture.lua` and `runtime_registry_fixture.lua` (older compat trees the package does not ship).
- Exact address keys (`.5`): three caches keyed a read or a binding by the address's text. LuaJIT prints numbers with 14 significant digits, so two addresses a few bytes apart share a key once the module sits high enough; on 2026-10-30 game.dll's PE signature (module+0x108) and its stamp (+0x110) collided and every combat enable refused with "identity changed during observation". The keys are now `%X` (the resolver's sample cache and the native binding cache in `animation_io.lua`, the prologue cache in `backend.lua`). The 0.1.17 release carries the same keys and will refuse the same way at such a base.
- Armory pause (`.8`, `.10`): the native weapon menu is lost whenever the game replaces the HUD, and with no ship menu open that is the Armory. On the first evaluation that finds the menu retired, `runtime.lua` restores the pose and releases its leases, and once the menu is owned again the ordinary path re-initializes the animation for the current loadout. `.9` debounced this by half a second and the Armory re-acquired its rebuilt menu first; `.10` pauses on the first lost step. Test `tools/hud_pause_tests.lua`.
- Equipment-package holds (`.11`): four Armory weapon-swap crashes (2026-10-31 and 11-01) were one engine fatal check in the resource release, reached from the swap's own package unload: a magazine attachment unit left in the world by ship combat still held a resource whose package the swap unloaded. `src/equipment_hold.lua` keeps one counted reference, through the game's own wrapper, on every loaded loadout and attachment package of `src/equipment_packages.lua` (317 packages, generated by `tools/equipment_catalog.py` from a listing of the game's data directory) while combat is on; combat controls arm only once the holds are acknowledged, and a reference is returned only when the game has let the package go and no live unit still holds one of its units. Tests `tools/equipment_hold_fixture.lua`, `tools/equipment_runtime_tests.lua`.
- Multiplayer sessions (`.12`): in a session with other players the Wielder manager holds more than one row, and the 0.1.17 live lease compared its count with a field that is not the row capacity (it reads 1 whatever the count), so the bridge animation never initialized away from a solo ship. The three sites (`animation_packages.lua`, the unarmed cleanup in `runtime.lua`, the floor cleanup in `support_weapons.lua`) now bound the local row by the manager's count; the engine's own hand-row accessors use no such bound, and the descriptor ownership check after each site validates the row. Tests `tools/wielder_bound_tests.lua`, `tools/roster_observer_fixture.lua`.

## Install

LLL with the LuaJIT build. Copy the whole `goose_bridge_combat` folder into LLL's `Helldivers2/Mods` folder and enable it. On Windows that is `%LOCALAPPDATA%\LLL\Helldivers2\Mods`; under Proton it is `compatdata/553850/pfx/drive_c/users/steamuser/AppData/Local/LLL/Helldivers2/Mods`. Disable any other Bridge Combat copy. Combat starts Off; the terminal is enabled. `LiveLuaLoader.log` shows `Code warm-up: page +0x… (n/44)` lines on the bridge and then `Code warm-up: 44 pages ready, N decrypted now`; the hotkey works from that line on.

## Validation

Offline: the witness checks, the 110 native fixture modes and the 33 Lua fixtures above. Live, 2026-10-30, on Linux under Proton with LLL: the mod loaded, the warm-up ran on the bridge, combat switched on and off, Photo Mode and Bridge Combat handed over cleanly, the Apex and the Nova were delivered from the terminal, and the session ended by the user's own stop. The game is the same Windows build under Proton, but no run on Windows itself has been made.

`.5` and `.6` ran live on 2026-10-31: the enable goes straight to "Bridge animation active", and the Apex pack equipped and fed the weapon. `.7` is `.6` with the pack named plainly. `.8` and `.10` paused and resumed through Armory visits with weapon swaps; `.11` was accepted live with a swap after a reload (the case that had crashed). `.12` ran live on 2026-11-02 in sessions of three and four players: five combat starts on the ship each reached "Bridge animation active" within the same second, with Armory-style pauses, mission drops and ship returns in between, no refusal and no crash dump; `.11` had looped on "Wielder live row refused" in that state.

## Not done

- No BSL variant.
- The 0.1.17 limits remain: fitted cabinet collision and weapon holstering during emotes.
- Combat must be switched on again after each mission: the runtime re-initializes to Off on the ship return.

## Rebuilding

`tools/assemble.py ORIGINAL_ROOT UNPORT_OUT PORT_SRC WEAPON_MENU_DLL OUT_DIR` with `ORIGINAL_ROOT` = `../terminal-0.1.14`. It needs inputs that are not in this repository: the decrypted capture of `game.dll` on this build, the witness maps and checker of the author's build workspace, the LuaJIT port's `src` and capstone. `tools/run_lua_fixtures.py ../terminal-0.1.14 goose_bridge_combat` runs the fixtures from this tree with the system LuaJIT and needs none of them. `tools/build_release_zip.py` packs `goose_bridge_combat/` into `dist/releases/` with a checksum file.
