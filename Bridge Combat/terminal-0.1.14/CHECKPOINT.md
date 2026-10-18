# Armory checkpoint — 2026-10-18

This is the tested terminal line, preserved separately from the existing 0.2 actor-route prototype.

Includes the fixed cabinet terminal, 7 × 5 gold/charcoal icon layout, native action exit, virtual cursor, framed camera, Weapons Free toggle, direct support inventory delivery and matching backpacks, native HUD/animations and session reinitialization.

This checkpoint adds the shared external weapon FX dependencies and mission UI audio bank identified by comparing a working mission with the bridge. Recoilless visual effects and area return, zoom audio, chat and hidden name/XP were confirmed live. Replacement deletes the old support gear before creating the next weapon; current inventory readback confirmed the retired rifle/backpack absent and the new selection equipped.

Focused Lua/native package contracts pass. The persistent native helper has 117 isolated lifetime cases in its accepted receipt. The BSL startup parses and both archive variants pass payload/round-trip checks. BSL gameplay remains unverified for this checkpoint. Solid cabinet collision remains unfinished.

The source and release archives contain no user settings, gameplay captures, game assets or private diagnostic files. Local checkpoint backups preserve settings separately. FX loading and dependency checks run during initialization or invalidation, then remain idle. Replacement checks exist only while a requested transition is pending.
