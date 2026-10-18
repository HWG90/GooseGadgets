# Height Over Bore 0.1.3 Experimental

Projectile ADS comparison without a weapon-name allowlist. Native hip fire, third-person aiming and continuous beam targeting are preserved. New installs start **Off**.

## Install

Disable the old 0.1.0 HoB mod before enabling this update. Install one loader variant at a time. Existing ADS prototype users retain their discovery and settings IDs.

**LLL:** requires Live Lua Loader and DBF-MCM. Extract the complete `goose_hob_ads_prototype` folder into `%LOCALAPPDATA%/LLL/Helldivers2/Mods`, refresh discovery and enable it in LLL. Use **MCM → Height Over Bore → Enabled**.

**BSL:** requires Bingus Shared Loader v15+ / API 1 and the original Mod Options Menu. Import the ZIP through Arsenal or your mod manager, enable the addon and restart normally. Use **Mod Options → Height Over Bore → Enabled**, then Apply. See [BSL instructions](https://github.com/HWG90/GooseGadgets/blob/main/Height%20Over%20Bore/ads-prototype/BSL-README.md).

There is no 0.1.3 MDL package. Camera override experiments that control ADS should be disabled during comparison.

## Equipment cache

Weapon-definition discovery is performed once per equipped generation and reused across ADS exit and reentry. The steady observer reads current controller/camera state, local owner and equipment identity, selected runtime storage, native mode and the owned cap. It does not replay authored definitions, code fingerprints or full ownership maps each frame. Equipment/storage changes and unreadable or competing runtime bytes invalidate the observation.

Settled observations are capped at 60 per second, without catch-up bursts. Disabled clean state performs no backend work. Enable, shutdown and pending cleanup bypass this rate bound. This is bounded polling, not an event-driven implementation: a transition can remain unobserved for about 16.7 ms plus loader scheduling delay. Live LLL rapid ADS exit and primary/secondary swap testing passed qualitatively: aiming stayed normal and no hitch was noticed. Same-shot isolation remains unproved.

An unchanged ADS update uses **16 protected reads** in the combined real Gate + Backend fixture, down from 40; released control uses **3**. Unchanged updates perform no full observation, definition lookup, resolution or write. These are offline operation counts; live timing is recorded separately.

Acquisition, restoration and pending/partial cleanup still take the full fresh validation path. The transition observer cannot authorize a copy. Authored angle/flag changes and definition-table relocation are revalidated on the next aiming transition or equip rather than polled continuously. Changed runtime cap bytes or native modes invalidate the next sampled observation.

Validated address conversions and copy lengths use a bounded cache. Every read still executes the protected Windows copy and checks its exact transferred count. Permission failures, changed bytes and recovery are observed on the next read.

## Transition optimization in 0.1.3

Remove the duplicate preliminary weapon resolution before guarded writes. The write transaction still freshly checks ownership, identity, expected cap bytes, ADS admission and final stability.

Controlled old/new/new/old testing used the same projectile weapon in ADS, with 120 restore/reapply pairs per version at 4/s. Mean pair cost fell **2.41 → 1.85 ms (23% lower)**; P95 fell **4.40 → 3.22 ms (27% lower)**. Rapid ADS exits and swaps passed qualitative LLL testing with normal aiming and no noticeable hitch. These paired operations are not directly comparable to the original 3.87 ms single-update peak, whose full cause remains unresolved. BSL live performance remains unmeasured.

## Earlier 0.1.2 live performance

Matched LLL ADS comparison on the same projectile weapon and scene, old → new → new → old: two 25-second samples per version after five-second warm-ups, about 115 updates/s. The backed-up prior installed version averaged **7.30 ms/s**; this implementation averaged **4.91 ms/s**, a **33% reduction**. Each sample stayed ADS with no full observations, definition lookups or writes. This compares complete versions, not only the scheduler.

A separate rapid ADS-exit/weapon-swap sample averaged **7.00 ms/s**, with a **3.87 ms** worst update. The player reported normal aiming and no noticeable hitch. The transition peak remains unresolved; BSL live performance is unmeasured.

## Behavior

During validated ADS, this release reduces the held projectile weapon's normal positive runtime correction limit to 0.5 degrees. Native corrections within the limit pass through unchanged; larger corrections are limited. Each weapon keeps its own original value for exact restoration. Existing tighter limits, authored raw-direction weapons and native special-targeting routes stay unchanged.

Earlier Adjudicator and secondary-weapon tests through LLL reported close ADS impacts below the sight and distant impacts around the aim point. The cap is an angular rule, not a distance switch; large corrections can be limited at any distance. The 0.5-degree setting is experimental, not a recovered historical Arrowhead value.

Continuous beams keep their native convergence. Historical build 1.000.305 has the sustained retargeting path selected by the saved Scythe base setting. All 10 beam resources common to the saved old/current catalogs retain equivalent default selection; 13 newer resources lack historical values. This supports preserving beams but does not prove historical entity overrides, target inputs or impact positions.

Prototype.3 changed a beam cache that the later sustained updater ignored. Scythe Off/On shots stayed around the aim point. This release removes that intervention. Beam definitions, runtime caps/modes and active emitted records remain untouched.

## Ownership and compatibility

Only Windows x64 `game.dll` build **6AB3B43F** with exact fingerprints is accepted. Fresh local owner, held weapon and native ADS camera/controller ownership are checked before acquisition. Early inactive screening can only reject acquisition; it cannot authorize a write. Only a selected projectile lane's four-byte runtime cap is written. Authored definitions, targeting mode, muzzle pose, velocity, gravity and drag remain unchanged.

New ownership requires an exact native baseline derived from that weapon's authored angle. Existing edits are preserved. ADS exit, swap, native-mode change, disable and loader cleanup request exact restoration; failed access retains cleanup ownership.

## Validation and remaining checks

**157 isolated contracts plus 14 parameter cases pass**, including exact restoration, ADS exit, ownership changes, partial reads/writes, native beam preservation and both adapters. Both allowlisted packages build deterministically and pass archive integrity checks.

The live projectile comparisons used earlier LLL candidates with the same correction policy. The equipment-cache changes passed matched live LLL ADS timing and rapid exit/swap testing. BSL has offline adapter coverage only. Same-shot transitions, movement, recoil, broader weapon alignment and complete historical equivalence remain unproved.

For a live comparison, use stationary single projectile ADS shots at the same close ledge and distant mark, Off versus On. Check ADS exit, hip fire, third-person aim and weapon swap. Restoration-pending or conflict status means cleanup has not passed. Scythe beams should retain native aiming with the option Off or On.

## Build and test

From this directory, using Python 3.10+ on Windows:

```powershell
py -3 tools/test_prototype.py
```

This builds both allowlisted LLL and BSL ZIPs, checks deterministic package bytes and runs the isolated fixture suite. Outputs and receipts stay under ignored `dist/releases`. No game process is accessed or installation changed. The tests load an isolated LuaJIT state from the installed game's `bin/lua51.dll`. For a different Steam library, pass `--dll 'D:/SteamLibrary/steamapps/common/Helldivers 2/bin/lua51.dll'`.
