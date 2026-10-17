# Bridge Combat 0.2.0-experimental

This candidate is held after failed live pose and Armory tests. Leave MCM Enabled Off. The initial animation reconstruction briefly corrected the rifle pose, but an Eruptor to Crossbow change left an incorrect pose and a later Adjudicator selection crashed in the engine's resource-release ownership check. Guarded tests with stable drawn-weapon initialization now run, but the player body and weapon hands still need a verified animation correction. Full native mission HUD, health/damage and stable Armory replacement remain pending.

Temporary diagnostic drivers additionally protect existing weapon packages through the normal counted request/release APIs. Two current packages acknowledged acquisition and balanced nonfinal release in the guarded tests. A same-primary native attachment refresh also acknowledged unchanged inventory selection; its visual result is unconfirmed. These drivers are separate from the packaged controller, and this limited evidence does not establish safe final package retirement or a stable Armory lifecycle.

Requires **Live Lua Loader R31 or later**, **DBF-MCM**, validated `game.dll` build `6AB3B43F` and executable build `6AB382E4`. The versioned native helper DLL and its license are bundled. Link's Link to Memory, command files and chat relay are not required.

The review ZIP is not ready for installation. The installed 0.1 mod remains separate from this source candidate. Its MCM toggle defaults to Off and saves through MCM. Temporary prototypes must stop before a future validated mod is enabled; overlapping ownership is refused.

The actor route initializes the current player's animation graph through the normal engine API and applies owned movement profiles and combat controls. Armory polling requests cleanup before restoring Lua controls, and requests resume after the Armory closes. This polling provides no guaranteed barrier before native weapon selection or unloading. Nested Armory menus keep the candidate paused; unknown ownership or unfinished cleanup prevents reactivation.

Turning Enabled off restores changes the mod still owns. Disabling or reloading through LLL retains the old instance and its MCM registration until cleanup acknowledges completion. Check MCM status or the LLL log. Unsupported builds and missing native APIs refuse activation. A fully restored disabled mod performs no game-memory polling.

This package uses the explicit production actor entry. The full game-mode route remains disabled pending its native completion and authored-level contracts. The helper stays loaded for the process lifetime; its versioned filename supports later generations without unloading code still referenced by the game. No account fields or permanent game assets are changed.

Build the production helper and review package from the component checkout:

```powershell
py -3 bridge-combat/tools/build_native.py --output dist/releases/bridge-combat-0.2-native-review/actor-build
py -3 bridge-combat/tools/build.py --native-dll dist/releases/bridge-combat-0.2-native-review/actor-build/BridgeCombatNative.dll
py -3 bridge-combat/tests/test_adapter.py
```

The package builder requires an explicit production DLL, checks its AMD64 headers and APIs without loading it, rejects test-only exports and external C/C++ runtime dependencies, and bundles a native SHA-256 receipt. It uses a file allowlist and writes the unpacked mod, ZIP and checksums to `DBF/dist/releases/bridge-combat-0.2.0-experimental-review`. It does not install or publish anything.

## BSL variant

A standalone Bingus Shared Loader package uses the original Mod Options Menu for **Enabled** and optional Mod Bindings Menu v3 for a **Toggle Bridge Combat** hotkey. It embeds the same backend, controller and production helper. See [BSL-README.md](BSL-README.md) for installation and limits.

```powershell
py -3 tools/build_bsl.py --native-dll dist/releases/bridge-combat-0.2-native-review/actor-build/BridgeCombatNative.dll
py -3 tests/test_bsl_package.py
```

The builder applies the same native checks, embeds the helper under a content-hashed file name, and writes a deterministic ZIP, its extracted startup script and receipts to `dist/releases/bridge-combat-0.2.0-experimental-bsl-review`. It does not install or publish anything.
