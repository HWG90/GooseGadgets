# Bridge Combat 0.1.17 experimental — Armory terminal

Use your loadout on the Super Destroyer with native combat controls, animations, health/stamina, weapon options and chat. Supported game/executable builds: `6AB3B43F` / `6AB382E4`.

Choose LLL (Live Lua Loader R31+) or BSL (Bingus Shared Loader API 1). Bridge Combat includes its own terminal input, settings, render dispatcher and native helpers. MCM is optional. No loader or menu framework is bundled. Use only one variant at a time.

## Use

Enable Bridge Combat in your loader. The wall terminal is enabled by default; MCM can optionally expose its settings. At the fixed cabinet, press the game's **Interact action** to focus its screen; press Interact again or Escape to return. Rebinding Interact is supported. The virtual arrow cursor follows the display, stays within the game window and scales with it. The camera frames the cabinet and restores your view afterward.

The charcoal, gold and white Armory displays a **7 × 5** icon grid on a **4096 × 2560** render target. Longer labels wrap. Mousewheel scrolls the weapon list when it exceeds the visible rows. Icons are credited in TERMINAL-ICONS.md.

**WEAPONS FREE** toggles combat and reflects its saved state in red. Requesting a weapon while combat is off enables combat before delivery. Support weapons equip directly with their default attachments and matching backpack. Replacement first unequips and removes the old support gear; primary and sidearm loadouts are preserved. **Clear floor weapons** removes loose support gear. **Refill ammo** replenishes reserves; reload normally afterward.

Turning combat off removes terminal-delivered support gear, restores native ship animations and returns loadout weapons to their carried attachments. Changing areas retires the old owners and initializes the new bridge session. Shared effects are loaded through the normal package loader with exact resource checks; settled FX state does no polling.

## Loading and performance

Shared combat UI, effects and audio preload as normal ship gameplay becomes available; preloading does not enable combat. A retained charcoal/gold loading bar shows the current stage and disappears when ready. Independent providers are submitted together, accepted requests are never replayed, and readiness checks run at most four times per second while loading. Ready runtime asset state is idle until lifecycle invalidation.

A fresh LLL process verified UI providers in 1.11 seconds and all FX/audio providers in 1.64 seconds. The old request spread was about 47 seconds due to serialized providers and 15-second retry delays. This is a loading-stage comparison, not a full old/new startup benchmark. A one-time UI verification peak of 22 ms was observed; no hitch-free startup claim is made. Detailed evidence is in CHECKPOINT.md.

## Validation and limits

Experimental test build. The Recoilless material/texture dependency fix was confirmed in gameplay and after an area change. Offline fixtures cover ownership, cleanup acknowledgements, replacement ordering and idle behavior. BSL uses the same embedded modules but has not received equivalent gameplay validation for this checkpoint. Native helper results that cannot be acknowledged retain ownership and are never replayed.

A fitted cabinet collision box and native weapon holstering during emotes remain unfinished. The oversized fog-producing environmental collider trial was removed and is not packaged. Native zoom audio, chat, hidden name/XP and the emote wheel have been confirmed in prior live checks. No account unlocks or saved loadout choices are changed.

## Build

Run `py -3 compat/lll-0.1.14/verify.py`, then `py -3 compat/lll-0.1.14/build.py --output dist/releases/terminal-review --native-receipt native/weapon-menu-receipt.json` from this source folder. The immutable native DLL and receipt must match. The BSL builder embeds the same allowlisted modules; no external menu or loader archives are combined. Build the independent input helper with `py -3 native/build_terminal_input.py` when changing its native source.
