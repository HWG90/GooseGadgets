# Height Over Bore 0.1.1 Experimental

Projectile ADS comparison without a weapon-name allowlist. Native hip fire, third-person aiming and continuous beam targeting are preserved. New installs start **Off**.

## Install

Disable the old 0.1.0 HoB mod before enabling this update. Install one loader variant at a time. Existing ADS prototype users retain their discovery and settings IDs.

**LLL:** requires Live Lua Loader and DBF-MCM. Extract the complete `goose_hob_ads_prototype` folder into `%LOCALAPPDATA%/LLL/Helldivers2/Mods`, refresh discovery and enable it in LLL. Use **MCM → Height Over Bore → Enabled**.

**BSL:** requires Bingus Shared Loader v15+ / API 1 and the original Mod Options Menu. Import the ZIP through Arsenal or your mod manager, enable the addon and restart normally. Use **Mod Options → Height Over Bore → Enabled**, then Apply. See [BSL instructions](https://github.com/HWG90/GooseGadgets/blob/hob-v0.1.1-experimental/Height%20Over%20Bore/ads-prototype/BSL-README.md).

There is no 0.1.1 MDL package. Camera override experiments that control ADS should be disabled during comparison.

## Behavior

During validated ADS, this release reduces the held projectile weapon's normal positive runtime correction limit to 0.5 degrees. Native corrections within the limit pass through unchanged; larger corrections are limited. Each weapon keeps its own original value for exact restoration. Existing tighter limits, authored raw-direction weapons and native special-targeting routes stay unchanged.

Earlier Adjudicator and secondary-weapon tests through LLL reported close ADS impacts below the sight and distant impacts around the aim point. The cap is an angular rule, not a distance switch; large corrections can be limited at any distance. The 0.5-degree setting is experimental, not a recovered historical Arrowhead value.

Continuous beams keep their native convergence. Historical build 1.000.305 has the sustained retargeting path selected by the saved Scythe base setting. All 10 beam resources common to the saved old/current catalogs retain equivalent default selection; 13 newer resources lack historical values. This supports preserving beams but does not prove historical entity overrides, target inputs or impact positions.

Prototype.3 changed a beam cache that the later sustained updater ignored. Scythe Off/On shots stayed around the aim point. This release removes that intervention. Beam definitions, runtime caps/modes and active emitted records remain untouched.

## Ownership and compatibility

Only Windows x64 `game.dll` build **6AB3B43F** with exact fingerprints is accepted. Fresh local owner, held weapon and native ADS camera/controller ownership are checked before acquisition. Early inactive screening can only reject acquisition; it cannot authorize a write. Only a selected projectile lane's four-byte runtime cap is written. Authored definitions, targeting mode, muzzle pose, velocity, gravity and drag remain unchanged.

New ownership requires an exact native baseline derived from that weapon's authored angle. Existing edits are preserved. ADS exit, swap, native-mode change, disable and loader cleanup request exact restoration; failed access retains cleanup ownership.

## Validation and remaining checks

**111 isolated contracts plus 14 parameter cases pass**, including exact restoration, ADS exit, ownership changes, partial reads/writes, native beam preservation and both adapters. Both allowlisted packages build deterministically and pass archive integrity checks.

The live projectile comparisons used earlier LLL candidates with the same correction policy. This release also includes performance changes; no fresh live comparison of those changes is claimed. BSL has offline adapter coverage only. Same-shot transitions, movement, recoil, broader weapon alignment and complete historical equivalence remain unproved.

For a live comparison, use stationary single projectile ADS shots at the same close ledge and distant mark, Off versus On. Check ADS exit, hip fire, third-person aim and weapon swap. Restoration-pending or conflict status means cleanup has not passed. Scythe beams should retain native aiming with the option Off or On.

## Build and test

From this directory, using Python 3.10+ on Windows:

```powershell
py -3 tools/test_prototype.py
```

This builds both allowlisted LLL and BSL ZIPs, checks deterministic package bytes and runs the isolated fixture suite. Outputs and receipts stay under ignored `dist/releases`. No game process is accessed or installation changed. The tests load an isolated LuaJIT state from the installed game's `bin/lua51.dll`. For a different Steam library, pass `--dll 'D:/SteamLibrary/steamapps/common/Helldivers 2/bin/lua51.dll'`.
