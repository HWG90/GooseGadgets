# Height Over Bore 0.1.3 Experimental — BSL

Experimental projectile ADS aiming mod by Goose. Requires **Bingus Shared Loader v15+ / API 1** and the original **Mod Options Menu API 1**.

Import `HOB-0.1.3-experimental-BSL.zip` through Arsenal or your mod manager, enable the addon and restart the game normally. Open **Options → Mod Options → Height Over Bore**, switch **Enabled** On and **Apply**. New installs start Off.

Use one HoB loader variant at a time. Disable the old 0.1.0 HoB addon before enabling this update. Existing ADS prototype users retain the same discovery and settings IDs. This package does not bundle loaders or menus. It has no DBF-MCM requirement.

During validated projectile ADS, normal positive target correction is limited to 0.5 degrees. Smaller corrections pass through. Tighter native limits, raw-direction weapons and native special-targeting routes stay native. Hip fire, third-person aiming and continuous beams retain native behavior. Off, ADS exit, swap and cleanup request exact restoration; unreadable cleanup retries and other edits are preserved.

Adjudicator and secondary close/far comparisons passed qualitatively through LLL. The BSL adapter has offline fixture coverage only. The 0.5-degree setting is experimental, not a recovered historical value. It is an angular rule, not a distance switch. Broader weapon coverage, movement, recoil, same-shot transitions and complete historical parity remain unproved.

Supports Windows x64 and `game.dll` timestamp **6AB3B43F**. Unsupported layouts refuse activation. Log: `%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/HeightOverBoreADSPrototype.log`.

Source, builders and tests: [GooseGadgets / Height Over Bore](https://github.com/HWG90/GooseGadgets/tree/main/Height%20Over%20Bore/ads-prototype).

Equipment caching avoids repeated definition searches during unchanged updates. A small read-only watcher still detects ADS exit and equip changes; copies and restoration retain full fresh validation. The shared implementation passed live LLL performance and rapid ADS/swap checks; BSL itself has offline adapter coverage only. Settled checks are bounded to 60 per second, so mode detection can lag by about 16.7 ms plus loader scheduling. Pending cleanup and shutdown bypass this bound.
