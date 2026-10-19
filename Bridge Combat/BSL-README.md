# Bridge Combat 0.1.17 — self-contained BSL

Download `BridgeCombat-0.1.17-BSL-Standalone.zip` from the [current experimental release](https://github.com/HWG90/GooseGadgets/releases/tag/bridge-combat-0.1.14-standalone-20261018). Import it through Arsenal or your mod manager, enable the addon, and launch normally.

An existing **Bingus Shared Loader / API 1** installation is required. Bridge Combat includes its own input capture, cursor confinement, scrolling, camera, render dispatch, settings and native helpers. It requires no MCM or Mod Options Menu, and bundles no loader. MCM and Mod Bindings Menu remain optional.

Disable other Bridge Combat variants before using this package, including LLL Bridge Combat and older self-contained test bundles. Do not enable duplicate copies of loader/menu packages from those historical bundles. Preserve unrelated mods.

At the fixed Armory cabinet, press the game's Interact action. WEAPONS FREE toggles combat; requesting a support weapon enables combat before delivery. Interact again or Escape releases focus and restores the camera. Mousewheel scrolls the weapon grid. See [all features and limits](README.md).

New installs start with the terminal enabled and combat off. Normal ship entry preloads shared assets and displays a stage-based loading bar without enabling combat. Independent providers queue together; completion checks stop at readiness. Returning from another area reinitializes the bridge owners.

BSL settings live at `%LOCALAPPDATA%/Goose/BridgeCombat/settings.cfg`; validated terminal placement is stored separately in `wall-terminal.txt`. Updating the addon should not remove these files. Content-hashed native helpers are extracted and reused only when their bytes match; no loaded helper is overwritten.

The no-MCM terminal, cursor, scrolling, combat toggle, support request and camera/input restoration were confirmed in BSL gameplay. Later shared performance/preloading changes have focused offline and startup/package coverage; final loading measurements were made under LLL. A fitted cabinet collision box and emote weapon holstering remain unfinished. Supported Windows x64 fingerprints: game `6AB3B43F`, executable `6AB382E4`.

The superseded 0.2 actor-route prototype is documented separately in [historical notes](docs/LEGACY-0.2-ACTOR-ROUTE.md).
