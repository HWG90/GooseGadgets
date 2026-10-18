# Bridge Combat 0.1.14 experimental — Armory terminal

Use your loadout on the Super Destroyer with native combat controls, animations, health/stamina, weapon options and chat. Supported game/executable builds: `6AB3B43F` / `6AB382E4`.

The LLL variant requires Live Lua Loader R31+, DBF-MCM and the HUD render bridge. The separate **self-contained BSL test ZIP** bundles its mod prerequisites; use only one variant at a time.

## Use

Enable **Bridge Combat** and **Wall terminal** in MCM. At the fixed cabinet, press the game's **Interact action** to focus its screen; press Interact again or Escape to return. Rebinding Interact is supported. The virtual arrow cursor follows the display, stays within the game window and scales with it. The camera frames the cabinet and restores your view afterward.

The charcoal, gold and white Armory displays a **7 × 5** icon grid on a **4096 × 2560** render target. Longer labels wrap. Mousewheel scrolls the weapon list when it exceeds the visible rows. Icons are credited in TERMINAL-ICONS.md.

**WEAPONS FREE** toggles combat and reflects its saved state in red. Requesting a weapon while combat is off enables combat before delivery. Support weapons equip directly with their default attachments and matching backpack. Replacement first unequips and removes the old support gear; primary and sidearm loadouts are preserved. **Clear floor weapons** removes loose support gear. **Refill ammo** replenishes reserves; reload normally afterward.

Turning combat off removes terminal-delivered support gear, restores native ship animations and returns loadout weapons to their carried attachments. Changing areas retires the old owners and initializes the new bridge session. Shared effects are loaded through the normal package loader with exact resource checks; settled FX state does no polling.

## Validation and limits

Experimental test build. The Recoilless material/texture dependency fix was confirmed in gameplay and after an area change. Offline fixtures cover ownership, cleanup acknowledgements, replacement ordering and idle behavior. BSL uses the same embedded modules but has not received equivalent gameplay validation for this checkpoint. Native helper results that cannot be acknowledged retain ownership and are never replayed.

A solid cabinet collider remains unfinished. Native weapon audio and HUD transitions are still under live review. No account unlocks or saved loadout choices are changed.

## Build

Run `py -3 compat/lll-0.1.14/verify.py`, then `py -3 compat/lll-0.1.14/build.py --output dist/releases/terminal-review --native-receipt native/weapon-menu-receipt.json` from this source folder. The immutable native DLL and receipt must match. Local distribution builders use explicitly supplied BSL/menu/MCM dependency archives; players of the self-contained test ZIP do not need those tools.
