# Height Over Bore

Experimental Helldivers 2 aiming mod by Goose. **0.1.1 Experimental** changes projectile aiming in ADS while keeping hip fire, third-person aiming and continuous beams native.

In the Adjudicator and secondary LLL comparisons, close ADS shots landed below the sight while distant shots stayed around the aim point. The mod uses an experimental 0.5-degree correction limit; it is not a verified restoration of every historical Arrowhead value or weapon.

## Install

Download one ZIP from [GooseGadgets Releases](https://github.com/HWG90/GooseGadgets/releases). Disable the old 0.1.0 HoB mod before enabling this update. Use one loader variant at a time. New installs start **Off**.

| Package | Requirements | Install and enable |
| --- | --- | --- |
| `HOB-0.1.1-experimental-LLL.zip` | Live Lua Loader and DBF-MCM | Extract the complete `goose_hob_ads_prototype` folder under `%LOCALAPPDATA%/LLL/Helldivers2/Mods`, refresh LLL discovery and enable it. Use MCM → Height Over Bore → Enabled. |
| `HOB-0.1.1-experimental-BSL.zip` | Bingus Shared Loader v15+ / API 1 and original Mod Options Menu API 1 | Import through Arsenal or your mod manager, enable the addon and restart normally. Use Mod Options → Height Over Bore → Enabled, then Apply. |

Existing ADS prototype users can update their existing package; its discovery and settings IDs are retained. The folder ID remains `goose_hob_ads_prototype`. There is no 0.1.1 MDL package. See [BSL instructions](BSL-README.md) or the [full ADS source documentation](ads-prototype/README.md).

## Behavior and limits

During validated projectile ADS, normal target correction is limited to 0.5 degrees. Smaller native corrections pass through. Existing tighter limits, raw-direction weapons and special targeting stay native. Velocity, gravity, drag, muzzle pose and authored definitions are unchanged. Disabling the option, leaving ADS or changing weapons requests exact restoration of the owned value; unreadable cleanup retries and other edits are preserved.

Supports Windows x64 and `game.dll` timestamp **6AB3B43F**. Unsupported builds refuse activation.

The release passes **111 isolated contracts plus 14 parameter cases** and deterministic LLL/BSL package checks. Earlier LLL builds with the same projectile policy passed qualitative Adjudicator and secondary close/far comparisons. BSL has offline adapter coverage only. This release's performance changes, same-shot ADS transitions, movement, recoil and broader weapon coverage still need live checks. Continuous beams retain their native targeting; no beam offset is promised.

## Source and builds

The current ADS release source, builders and tests are in [`ads-prototype`](ads-prototype/README.md). From that directory, run `py -3 tools/test_prototype.py`. It builds and checks both packages under ignored `dist/releases`, without accessing a game process or installing anything.

The original 0.1.0 all-mode source remains in this parent folder for reference. It forces zero aiming angles and has a reported hip-fire/laser misalignment; it is not the 0.1.1 implementation. Its earlier visual evidence did not establish historical fidelity across modes. See the [historical technical notes](TECHNICAL.md).

MIT licensed.
