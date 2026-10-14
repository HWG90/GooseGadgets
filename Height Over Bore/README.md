# Height Over Bore

An experimental Helldivers 2 mod by Goose that restores muzzle-based aiming. At close range, the muzzle sits below the sight, so shots can land below the reticle. The mod keeps the game's normal muzzle, ballistics and weapon effects.

The saved Enabled preference follows weapon changes, death, respawn, mission/ship transitions and game restarts. The runtime discovers the current primary, sidearm and support inventory again as actors and weapons change; it never saves memory addresses.

## Choose your loader

Download one ZIP from [GooseGadgets Releases](https://github.com/HWG90/GooseGadgets/releases). Install only one Height Over Bore variant at a time. Every variant defaults to **Off**.

| Package | Requirements | Settings |
| --- | --- | --- |
| `HOB-0.1.0-experimental-BSL.zip` | Bingus Shared Loader v15+ / API 1 and original Mod Options Menu API 1 | Options → Mod Options → Height Over Bore → Enabled, then Apply |
| `HOB-0.1.0-experimental-LLL.zip` | Live Lua Loader and DBF-MCM | MCM → Height Over Bore → Enabled |
| `HOB-0.1.0-experimental-MDL.zip` | MDL API 2 and DBF-MCM for MDL | MCM → Height Over Bore → Enabled |

**BSL:** import the ZIP through Arsenal or your mod manager, enable its addon, and restart normally. See [BSL instructions](BSL-README.md).

**LLL:** extract the complete `goose_hob` folder into `%LOCALAPPDATA%/LLL/Helldivers2/Mods`, refresh discovery, and enable it in LLL. Turn the feature On in MCM.

**MDL:** extract the complete `goose_hob` folder into `%LOCALAPPDATA%/MDL/Helldivers2/Mods`, refresh discovery, and enable it in MDL. Turn the feature On in MCM. See [MDL instructions](MDL-README.md).

## Behavior and current limits

The backend changes each entity-owned projectile or beam aiming-definition angle to zero. The engine then derives the direction from its normal muzzle basis. When needed, the game's empty-modifier routine creates a private definition; shared base definitions remain read-only.

Turning Enabled Off restores the exact original bytes of still-live definitions owned by this instance. Retired records are discarded without writing to their old addresses. Foreign changes are preserved. Failed restoration remains pending and retries; provider replacement waits for owned restoration before reactivation.

This release supports Windows x64 and the `game.dll` build timestamp **`6AB3B43F`**. Layout, code fingerprints and ownership are checked before writes or native calls. Unsupported builds refuse activation. No extra native DLL or development toolkit is required.

Coverage uses both native aiming-component families, without a list of weapon names. The original projectile fix was visually confirmed on the Adjudicator, and the LLL version's owned writes and restoration were observed in game. Beam weapons, shotguns, support weapons, multiple muzzles and special guidance still need their own visual checks. BSL and MDL adapters, persistence and lifecycle behavior have offline fixture coverage; this first release does not claim live acceptance of those adapters or every weapon and transition. See [technical notes](https://github.com/HWG90/GooseGadgets/blob/main/Height%20Over%20Bore/TECHNICAL.md).

## Build from source

Run these commands inside the repository's `Height Over Bore` folder using Python 3.10+ on Windows:

```powershell
py -3 tools/build.py
py -3 tools/build_bsl.py
py -3 tools/build_mdl.py
```

Allowlisted, standalone ZIPs and SHA-256 receipts are written under `dist/releases`. The builders do not install or publish anything. BSL embeds its modules in one Lua archive entry; LLL and MDL include their own modules.

```powershell
py -3 tests/run_tests.py
py -3 tests/run_bsl.py
py -3 tests/run_mdl.py
```

The test runners use an isolated LuaJIT state through the installed game's `bin/lua51.dll`, with fixture memory and native calls. They do not attach to the game. For another Steam library location, pass `--dll 'D:/SteamLibrary/steamapps/common/Helldivers 2/bin/lua51.dll'`. Build BSL before its adapter tests so the generated embedded entry exists.

MIT licensed. This folder owns the shared backend, the three loader adapters, builders, tests and documentation.
