# Bridge Combat 0.1.17 on Steam build 26251122

The 0.1.17 Experimental Armory terminal ([terminal-0.1.14](../terminal-0.1.14/README.md)) rebuilt for the game as updated on 2026-10-29 (Steam build 26251122, game `6AE0E5FF`, executable `6AE0964A`), with the two support weapons added since 0.1.17: LAS-44 Nova and AMW-20 Apex. The design is the 0.1.17 one: read a function's prologue, then call it; no instruction patches, no page-protection changes, no game memory written. One module is new, because of what the 7.2.0 game update changed.

Package: `goose_bridge_combat/`, version `0.1.17-experimental-26251122.3`, LLL only (Live Lua Loader, LuaJIT build); [download](https://github.com/HWG90/GooseGadgets/releases/tag/bridge-combat-0.1.17-26251122-20261030). Its hashes are in `goose_bridge_combat-RECEIPT.json`.

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
| Lua fixtures | `tools/port_fixtures.py`, `tools/run_lua_fixtures.py` | the release fixtures given the sources' own build-constant substitutions (`tests-ported/`), run with LuaJIT: 33 of 33 (`evidence/lua-fixture-results.json`) |

Decisions that are not address swaps:

- `support_catalogue.lua`, `terminal_icons.lua`: LAS-44 Nova and AMW-20 Apex added (icons 34 and 35). The Apex row has no backpack entry yet; that is the next build.
- `backend.lua`: 412 base locomotion definitions (408 on the 0.1.17 build); the control-word window starts at `pc+0xFD8`, the row having moved by 8 bytes.
- `animation_blend.lua`, `animation_controller.lua`: on 26088801 and later the blend-pair definition table is not loaded, so `supported=false` and the controller skips that step. `blend_pairs_fixture.lua` is therefore not run.
- `runtime.lua` `photo_state`: the current War Journalist publishes `DBF_PHOTO_MODE_OWNER`; that branch is read ahead of the 0.1.17 discovery.
- `main.lua`: the warm-up above; `start_off` behaviour kept.
- Not run: `ffi_binding_cache_fixture.lua` and `runtime_registry_fixture.lua` (older compat trees the package does not ship).

## Install

LLL with the LuaJIT build. Copy the whole `goose_bridge_combat` folder into LLL's `Helldivers2/Mods` folder and enable it. On Windows that is `%LOCALAPPDATA%\LLL\Helldivers2\Mods`; under Proton it is `compatdata/553850/pfx/drive_c/users/steamuser/AppData/Local/LLL/Helldivers2/Mods`. Disable any other Bridge Combat copy. Combat starts Off; the terminal is enabled. `LiveLuaLoader.log` shows `Code warm-up: page +0x… (n/44)` lines on the bridge and then `Code warm-up: 44 pages ready, N decrypted now`; the hotkey works from that line on.

## Validation

Offline: the witness checks, the 110 native fixture modes and the 33 Lua fixtures above. Live, 2026-10-30, on Linux under Proton with LLL: the mod loaded, the warm-up ran on the bridge, combat switched on and off, Photo Mode and Bridge Combat handed over cleanly, the Apex and the Nova were delivered from the terminal, and the session ended by the user's own stop. The game is the same Windows build under Proton, but no run on Windows itself has been made.

The package in this tree equals the one that ran live except for two lines of its `README.md` (the supported-builds line and the build note).

## Not done

- AMW-20 Apex backpack: the catalogue needs its backpack record, which the game's armory catalogue does not pair with the weapon; it is being read from the running game.
- No BSL variant.
- The 0.1.17 limits remain: fitted cabinet collision and weapon holstering during emotes.

## Rebuilding

`tools/assemble.py ORIGINAL_ROOT UNPORT_OUT PORT_SRC WEAPON_MENU_DLL OUT_DIR` with `ORIGINAL_ROOT` = `../terminal-0.1.14`. It needs inputs that are not in this repository: the decrypted capture of `game.dll` on this build, the witness maps and checker of the author's build workspace, the LuaJIT port's `src` and capstone. `tools/run_lua_fixtures.py ../terminal-0.1.14 goose_bridge_combat` runs the fixtures from this tree with the system LuaJIT and needs none of them. `tools/build_release_zip.py` packs `goose_bridge_combat/` into `dist/releases/` with a checksum file.
