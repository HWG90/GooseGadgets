# Bridge Combat - independent BSL package

Requires an existing compatible Bingus Shared Loader installation. No loader, MCM, Mod Options or Mod Bindings framework is bundled or required by the terminal.

Enable this package and disable other Bridge Combat variants. The fixed Armory terminal loads on the solo bridge. Interact opens it and frames the display; Interact again or Escape releases it. Native action mappings follow your Interact binding. The flat arrow stays inside the screen, with raw mouse movement and native wheel scrolling through the 7x5 weapon grid.

WEAPONS FREE toggles combat. Equipping a support weapon enables combat first, replaces the previous delivered support gear and includes its matching backpack. Refill and floor cleanup remain on the terminal. Turning combat off removes delivered gear and restores the normal carried loadout.

Bridge Combat owns its input capture and restores the game window, cursor, and camera on release, loss of focus, cleanup or area change. Settings are stored under LocalAppData/Goose/BridgeCombat/settings.cfg; placement stays in wall-terminal.txt. MCM can optionally expose settings, and an existing Mod Bindings Menu can optionally expose the combat hotkey.

This is an experimental build. Source tests and package integrity do not establish live acceptance. Cabinet collision and emote weapon holstering remain unfinished.
