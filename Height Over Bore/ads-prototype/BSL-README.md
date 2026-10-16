# HoB ADS Prototype.4 - BSL

Experimental projectile ADS comparison, without a weapon-name allowlist. Requires
Bingus Shared Loader v15+ / API 1 and the original Mod Options Menu. Starts Off;
select **HoB ADS Prototype > Enabled**, then Apply. Use one loader copy and
disable original HoB/camera tests.

Validated projectile ADS reduces a normal positive correction limit to 0.5 degrees.
Smaller native target corrections pass unchanged; larger ones are limited.
Each original value is restored on ADS exit, swap, disable or cleanup. Tighter
native limits, authored raw-direction weapons and native overrides stay native.
Hip fire and third-person aiming keep their native settings.

Beam targeting stays entirely native. The historical Scythe base default and
sustained-beam source select convergence, matching its current native route.
Prototype.3's beam cache change did not control sustained targeting; it is removed
here. No beam cap, mode, definition or active record is changed.

Adjudicator and secondary close/far ADS comparisons passed qualitatively through
LLL. The BSL adapter has offline fixture coverage and has not been live-validated.
The 0.5-degree setting is experimental, not a recovered historical value, and is
an angular rule rather than a distance switch. Other weapons, moving/recoil
behavior, same-shot transition isolation and full historical parity need checks.

Use the standard mod-manager Addon merge. This updates the existing prototype
ID/discovery path. Only game.dll build 6AB3B43F with exact fingerprints is accepted.
No native helper, executable patch or GameGuard change is included.

Log: %LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/HeightOverBoreADSPrototype.log
