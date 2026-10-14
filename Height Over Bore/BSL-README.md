# Height Over Bore — BSL

Experimental standalone mod by Goose. Requires **Bingus Shared Loader** and the original **Mod Options Menu** (API 1). DBF-MCM, LLL, LinksLinkToMemory and a separate native DLL are not required.

Install `HOB-0.1.0-experimental-BSL.zip` through Arsenal or your Helldivers 2 mod manager. Enable the included BSL addon, then restart the game normally. Open **Options → Mod Options → Height Over Bore**, switch **Enabled** On and **Apply**. It defaults to Off. Mod Options Menu saves the applied preference under `goose_hob.enabled` in its own settings file; there is no separate HoB settings file.

Use one HoB package at a time. Disable the previous LLL/MCM HoB mod when using this BSL edition. This package does not change or remove that installation or its saved settings.

The saved preference remains active across loadout changes, death, respawn, mission/ship transitions and game restarts. The runtime rediscovers the current inventory and entity-owned aiming definitions; it never saves memory addresses to disk. Missing or retired players suspend application and restore or discard owned records according to their current lifetime.

Turning Enabled Off restores the original aiming bytes for still-live definitions that this instance owns. Unreadable restoration remains pending and retries during updates. Other edits are preserved. BSL archive enable/disable is restart-based; use the in-game Enabled option for reversible live toggling. Original Mod Options Menu has no unregister API, so callbacks are explicitly retired on shutdown and guarded against provider replacement.

The backend changes the per-entity projectile or beam aiming angle to zero so the game derives direction from its normal muzzle basis. It covers the two aiming-component families without weapon-name lists. It retains the original weapon muzzle, damage, ammunition and weapon-specific effects. An engine-owned private definition is materialized through the normal zero-patch modifier path when required; shared base definitions remain read-only.

Supported `game.dll` build timestamp: `6AB3B43F`. Layout and native fingerprints are checked before any game write or call. Unsupported builds refuse activation and log the reason in `%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/HeightOverBore.log`.

The original projectile fix was visually confirmed on the Adjudicator. Beam and other weapon-family visual acceptance remains pending. The BSL integration is checked offline for menu persistence, restoration and lifecycle behavior; its native menu and effects still require an in-game check. This first release is experimental.

Source: [GooseGadgets / Height Over Bore](https://github.com/HWG90/GooseGadgets/tree/main/Height%20Over%20Bore). Inside that folder, build with `py -3 tools/build_bsl.py`, then check with `py -3 tests/run_bsl.py`. Outputs go under `dist/releases`; these commands do not install or publish. The ZIP embeds the entire runtime in one Lua archive entry, so it runs without the source checkout. Original loader/menu contracts: [BSL authoring](https://github.com/CowboyBingus/BingusSharedLoader/blob/main/docs/AUTHORING.md), [Mod Options Menu API](https://github.com/CowboyBingus/ModOptionsMenu/blob/main/src/api.lua).
