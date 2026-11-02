# Bridge Combat — Armory terminal

Experimental Helldivers 2 mod by Goose. Use your loadout on the Super Destroyer bridge, or request support weapons from an integrated Armory cabinet.

The current release is **0.1.17 Experimental**. [Download the LLL or self-contained BSL package](https://github.com/HWG90/GooseGadgets/releases/tag/bridge-combat-0.1.14-standalone-20261018). Choose one variant and disable duplicate Bridge Combat installs. Neither download bundles a loader; MCM is optional.

## What it includes

- A fixed cabinet with a sharp charcoal, gold and white screen, a 7 × 5 stratagem-icon grid, wrapped labels and native mousewheel scrolling.
- The game's Interact action opens and closes the terminal. A confined arrow cursor and framing camera restore normal input/view on exit; rebinding Interact is supported.
- WEAPONS FREE toggles combat and turns red while enabled. Requesting a weapon enables combat before delivery.
- Support weapons equip directly with their normal attachments and matching backpack. Replacement removes old terminal gear and preserves primary/sidearm loadouts. Refill ammo and clear loose support gear from the same screen.
- Native combat animations, health/stamina, moving crosshair, weapon quick actions, chat, weapon effects and zoom audio. Combat Off removes terminal gear and restores ship animations and carried weapon attachments.
- Asset preloading begins when normal, focused ship gameplay is available, without enabling combat. A stage-based loading bar shows pending work and disappears when ready. Area return reacquires the current bridge session.

## Install

| Variant | Requirement | Installation |
| --- | --- | --- |
| `BridgeCombat-0.1.17-experimental-LLL.zip` | Live Lua Loader R31+ | Extract the full `goose_bridge_combat` folder into `%LOCALAPPDATA%/LLL/Helldivers2/Mods`, then enable it in LLL. |
| `BridgeCombat-0.1.17-BSL-Standalone.zip` | An existing Bingus Shared Loader installation, API 1 | Import through Arsenal or your mod manager, enable the addon, and launch normally. No MCM, Mod Options Menu, or extra input/render provider is required. |

The terminal is enabled by default; new combat settings start Off. MCM can optionally expose settings. Mod Bindings Menu can optionally supply a combat hotkey. The terminal works without either menu. BSL details: [installation and settings](BSL-README.md).

## Loading and performance

Independent UI and FX/audio providers are submitted together. Requests that have been accepted are never repeated. Completion discovery is bounded to four checks per second while loading, then stops once the runtime is ready; area changes explicitly invalidate the old session. Native HUD rendering and active input handling still run as needed.

Live LLL fresh-process testing verified UI assets in **1.11 seconds** and all FX/audio providers in **1.64 seconds**. Previously, serialized requests and exponential backoff delayed the last FX request until about **47 seconds after the first**. These measure different stages: the 47-second figure is the old request spread, not a measured old total load time. Disk cache and focus can affect results. See [validation and timing details](terminal-0.1.14/CHECKPOINT.md).

## Compatibility and limits

Windows x64; the 0.1.17 release supports game/executable fingerprints `6AB3B43F` / `6AB382E4`, and the 26251122 build below supports `6AE0E5FF` / `6AE0964A`. Unknown builds or uncertain native ownership refuse unsafe work. No account unlocks or saved loadout choices are changed.

A correctly sized cabinet collision box and normal weapon holstering during emotes remain unfinished. The oversized environmental-blocker trial was removed; it is not included in either download. BSL shares the source modules and passes package/startup contracts; the newest loading timings were measured under LLL.

## Steam build 26251122 (7.2.0 and later)

The 7.2.0 game update (2026-10-20) keeps code pages encrypted until the game first runs them, which stops the 0.1.17 package on the ship. [terminal-26251122](terminal-26251122/README.md) is the same 0.1.17 design rebuilt on the 26251122 offsets, with LAS-44 Nova and AMW-20 Apex and a per-frame code warm-up on the bridge; the LLL package `0.1.17-experimental-26251122.12` is [the 26251122 download](https://github.com/HWG90/GooseGadgets/releases/tag/bridge-combat-0.1.17-26251122.12-20261102) and is in that tree with its receipt, fixtures and evidence. LLL only (LuaJIT build); checked live on Linux under Proton from 2026-10-30 to 2026-11-02, not yet on Windows itself. `.12` adds the Apex backpack, exact cache keys (the 0.1.17 release can refuse every enable at some module bases), an Armory pause, equipment-package holds against the Armory weapon-swap crash, and combat in multiplayer sessions. A BSL variant is not done.

Current source, builds and tests: [terminal-0.1.14](terminal-0.1.14/README.md) for the 0.1.17 release and [terminal-26251122](terminal-26251122/README.md) for Steam build 26251122. The older 0.2 actor-route investigation is preserved separately as [historical documentation](docs/LEGACY-0.2-ACTOR-ROUTE.md); it is not the current Armory release.
