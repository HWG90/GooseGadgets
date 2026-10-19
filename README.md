# GooseGadgets

Standalone Helldivers 2 mods by Goose. Each gadget has its own source, instructions and release packages.

| Gadget | What it does | Current downloads |
| --- | --- | --- |
| [Bridge Combat](Bridge%20Combat/README.md) | An integrated ship Armory with a 7 × 5 weapon-icon grid, direct support weapon/backpack delivery, native combat controls/HUD/effects, and ship-entry asset preloading with a loading bar. | [0.1.16 Experimental: LLL and self-contained BSL](https://github.com/HWG90/GooseGadgets/releases/tag/bridge-combat-0.1.14-standalone-20261018) |
| [Height Over Bore](Height%20Over%20Bore/README.md) | Limits projectile ADS target correction to an experimental 0.5 degrees, preserving native hip fire, third-person aiming and continuous beams. Tracks supported weapon and ADS transitions. | [0.1.3 Experimental: LLL and BSL](https://github.com/HWG90/GooseGadgets/releases/tag/hob-v0.1.3-experimental) |

## Bridge Combat

Press Interact at the fixed Armory cabinet to use a charcoal/gold screen with stratagem icons, wrapped weapon labels and mousewheel scrolling. The cursor stays in the display and game window, while the camera frames the screen. Interact again or Escape restores gameplay.

WEAPONS FREE toggles combat and reflects its state in red. Request support weapons with their normal attachments and matching backpack, replace old terminal gear, refill ammo or clear loose support weapons. Combat uses native health/stamina, crosshair, quick actions, chat, animations and weapon effects; turning it off restores ship behavior and carried loadout weapons.

LLL and BSL downloads include Bridge Combat's own terminal dependencies. **MCM is optional and no loader is bundled**; install your chosen loader separately. Assets preload on normal ship entry without switching combat on. Independent providers queue together, and completion checks stop when ready. The current fresh LLL test verified UI in 1.11 seconds and FX/audio in 1.64 seconds. Cabinet collision and emote weapon holstering remain unfinished. [Installation, validation and limits](Bridge%20Combat/README.md).

## Height Over Bore

An experimental ADS projectile correction policy for closer muzzle-based aiming. Smaller native corrections, special targeting and continuous beams remain native; projectile velocity, gravity, drag and authored muzzle pose are unchanged. Disable the option or leave the supported ADS state to restore the owned value.

Choose the LLL package with DBF-MCM, or BSL with the original Mod Options Menu. New installs start Off. The published 0.1.3 packages are LLL/BSL; there is no 0.1.3 MDL download. Qualitative Adjudicator and secondary comparisons passed, while broader weapon fidelity remains experimental. [Installation, performance and limits](Height%20Over%20Bore/README.md).

Download packaged mods from [Releases](https://github.com/HWG90/GooseGadgets/releases). Use one loader variant per gadget, disable duplicate old copies, and read each gadget's requirements. Source builds and experimental limits are documented alongside the code.
