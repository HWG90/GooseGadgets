# Height Over Bore for MDL

Experimental mod by Goose. Requires MDL API 2, the **MDL edition of DBF-MCM**, and Windows x64. Install DBF-MCM for MDL before enabling this mod. Supported game.dll timestamp: `6AB3B43F`.

**0.1.0 has a reported hip-fire/laser misalignment.** Its universal zero-angle policy does not match every original weapon policy captured from Arrowhead's 1.000.305 build. A complete restoration across aiming modes remains unfinished and unreleased.

Extract the complete `goose_hob` folder under `%LOCALAPPDATA%/MDL/Helldivers2/Mods`, refresh MDL discovery and enable Height Over Bore. The installed entry must be `%LOCALAPPDATA%/MDL/Helldivers2/Mods/goose_hob/mod.lua`. Open **MCM → Height Over Bore → Enabled** to turn the feature on. The setting defaults to Off and MCM saves your preference. Install one Height Over Bore loader variant at a time.

The shared runtime follows equipped weapons, weapon changes, death, respawn and session changes. It changes only entity-owned projectile or beam aiming definitions; shared base definitions remain read only. Missing players or unsupported layouts suspend activation. An earlier Adjudicator experiment was visually accepted; that did not establish original behavior in every aiming mode. Other weapon families still need visual acceptance.

Turning the setting off or disabling/reloading the mod restores each still-live owned value to its exact original bytes. Other edits are preserved. If restoration is pending when MDL stops delivering this mod's updates, the adapter retains its cleanup owner and retries through a cooperative game-update hook. It forwards existing arguments and results, runs cleanup only, and removes only its own hook. A later wrapper remains intact. A replacement instance cannot activate until the previous cleanup acknowledges completion. If game update delivery itself stops, cleanup stays pending; re-enable retries restoration before activation. A normal game exit retires the process memory.

The package is self-contained. It requires no LLL, Bingus, chat relay, development toolkit, Bridge Combat or separate native helper. MDL and LLL variants use MCM; the BSL variant uses Mod Options.

Build a review package with `py -3 tools/build_mdl.py`. Run focused adapter and package checks with `py -3 tests/run_mdl.py`. Build outputs are review candidates; neither command installs, enables or publishes the mod.

The MDL adapter has passed isolated lifecycle and packaging checks. This variant has not been installed, enabled or visually tested in a live game.
