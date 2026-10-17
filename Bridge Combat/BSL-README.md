# Bridge Combat 0.2.0-experimental — BSL

Experimental mod by Goose for using your equipped loadout on the Super Destroyer bridge. This is a review candidate held after failed live pose and Armory tests; see the main [README](README.md) for the known limits. Leave **Enabled** Off unless you are testing.

Requires **Bingus Shared Loader v15+ / API 1** and the original **Mod Options Menu API 1**. **Mod Bindings Menu v3** is optional and adds a hotkey. DBF-MCM, Live Lua Loader, Link's Link to Memory and chat relay are not required.

## Install

Import `BridgeCombat-0.2.0-experimental-BSL.zip` through Arsenal or your mod manager, enable the addon and restart the game normally. Open **Options → Mod Options → Bridge Combat**, switch **Enabled** On and **Apply**. New installs start Off.

With Mod Bindings Menu installed, open **Options → Controls → MODS** and assign **Bridge Combat → Toggle Bridge Combat**. Each press flips and saves the same Enabled setting shown in Mod Options. Choose your own key: the shared native action may inherit an unrelated default. The hotkey is ignored while Mod Options is unavailable or DBF-MCM is open.

Use one Bridge Combat variant at a time. While the LLL Bridge Combat is registered with DBF-MCM, this addon stays Off and keeps its saved setting.

## Native helper

The production helper DLL is embedded in the addon. The first time Enabled is requested, it is written to `%LOCALAPPDATA%/Goose/BridgeCombat/runtime/BridgeCombatNative-<version>-<hash>.dll`. The hash in its name identifies its exact bytes, so an existing file is reused only when it matches. A different file at that path is never replaced and blocks activation. A disabled install writes only its log.

The helper stays loaded for the game session. Turning Enabled Off restores the changes the mod still owns. Cleanup that cannot finish yet is retried each frame before the addon releases the game callbacks.

Supports Windows x64 with `game.dll` build `6AB3B43F` and executable build `6AB382E4`. Unsupported builds refuse activation. Log: `%LOCALAPPDATA%/Goose/BridgeCombat/BridgeCombat.log`. MinHook's license is included as `MINHOOK-LICENSE.txt`.

The BSL adapter has offline contract coverage only; it has not been live-tested.
