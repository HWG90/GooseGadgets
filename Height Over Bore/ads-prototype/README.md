# HoB ADS Prototype 0.1.1-ads-prototype.4

Experimental projectile ADS comparison, without a weapon-name allowlist. Native beam
targeting, hip fire and third-person aiming are preserved. New installs start Off.

## Behavior

During validated ADS, this candidate reduces the held projectile weapon's normal
positive runtime correction limit to 0.5 degrees. Native corrections within the
limit pass through unchanged; larger corrections are limited. Each weapon keeps
its own original value for exact restoration. Existing tighter limits, authored
raw-direction weapons and native special-targeting routes stay unchanged.

Adjudicator and secondary-weapon tests through LLL reported the desired qualitative pattern:
close ADS impacts below the sight and distant impacts around the aim point.
The cap is an angular rule, not a distance switch; large corrections can be
limited at any distance. The 0.5-degree setting is experimental, not a recovered
historical Arrowhead value. Other weapons, movement and recoil need live checks.

## Beam targeting

Continuous beams keep their native convergence. Historical build 1.000.305 has
this sustained retargeting path, and the exact Scythe resource's saved base
setting selected it. All 10 beam resources common to the old/current saved
catalogs retain equivalent default selection; 13 newer resources lack old values.
This supports preserving native beams. It does not prove every historical entity
override, target input or old-game impact position.

Prototype.3 changed a beam cache, but the later sustained updater ignored that
cache. Scythe Off/On shots stayed around the aim point. This revision removes the
unnecessary beam intervention rather than forcing a raw or fixed beam direction.
Beam definitions, runtime caps/modes and active emitted records remain untouched.

## LLL use

Requires current LLL and DBF-MCM. Install one loader copy and disable original HoB
and camera override tests. This updates the same ADS prototype ID. Use **HoB ADS
Prototype > Enabled**. Off restores exact owned projectile-cache bytes.

Compare stationary single projectile ADS shots at the same close ledge and
distant mark, Off versus On. Check ADS exit, hip fire, third-person aim and weapon
swap. A restoration-pending or conflict status means cleanup has not passed.
Scythe beams should retain native aiming with the option either Off or On.

## Ownership

Only game.dll build 6AB3B43F with exact fingerprints is accepted. Fresh local
owner, held weapon and native ADS camera/controller ownership are checked every
update, including zero-delta updates. Only a selected projectile lane's four-byte
runtime cap is written. Authored definitions, targeting mode, muzzle pose,
velocity, gravity and drag remain unchanged. New ownership requires an exact
native baseline derived from that weapon's authored angle. Existing edits are
preserved. ADS exit, swap, native-mode change, disable and loader cleanup request
exact restoration; failed access retains cleanup ownership.

No native helper, executable patch, forced native call or GameGuard change is
included. This is an unreleased test candidate. Same-shot transition timing,
every-weapon impact alignment and complete historical restoration remain unproved.

## Build and test

From this `ads-prototype` folder, using Python 3.10+ on Windows:

```powershell
py -3 tools/test_prototype.py
```

This builds both allowlisted LLL and BSL ZIPs, checks deterministic package bytes,
and runs 106 isolated contracts plus 14 parameter cases. Outputs and receipts stay
under ignored `dist/releases`. No game process is accessed or installation changed.
The tests load an isolated LuaJIT state from the installed game's `bin/lua51.dll`.
For a different Steam library, pass `--dll 'D:/SteamLibrary/steamapps/common/Helldivers 2/bin/lua51.dll'`.

BSL has offline adapter coverage only. The reported weapon comparisons used LLL;
neither those observations nor the fixtures prove full historical equivalence.
