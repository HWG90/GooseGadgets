# Bridge Combat live status, October 13

The installed 0.1 control-only mod and held 0.2 native candidate remain separate. No new production native candidate was installed or published during this investigation.

## Confirmed results and remaining gaps

- The user confirmed weapons and prone work on the bridge, but the visible body arms remain in an incorrect pose. The screenshot shows a disconnected weapon grip and hanging body arm.
- The first successful animation test, batch362, still had scene3, MissionHUD0 and ShipHUD1. It never established full deployment, mission HUD or health/damage.
- Guarded batch444 acquired two existing resident weapon packages through normal native counted requests. Batch445 read both aggregate counts as2. Cleanup batch446 restored native animation/control ownership and released both additional references back to1.
- Batch449 acknowledged the same primary attachment with notify0 and unchanged inventory selection. The requested visual confirmation remains pending. Its five-minute test ended at20:35:31 with native/control/package cleanup acknowledged. Batch452 confirmed MCMOff and no native test task.
- A clean mission visibility capture was subsequently collected in batch459: actor4195204, body reference25171318, first-person reference25171169, 27 current linked units. The diagnostic performs no SDK Unit setters or native calls and saves only after rechecking the actor and all captured relationships. The matching bridge capture is pending.
- Batch462 extended that same actor's snapshot with both AnimationBlenders. Their bone transfer mode is3 (position_and_rotation). The body/FP Blender field is separate from the animator; it must be compared on the bridge after a guarded reconstruction.
- Full mission HUD, health/damage, stable Armory replacement and lifecycle recovery remain required. Weapon effects also need visual verification.

## Evidence that rules out unsupported fixes

- Ship and mission use the same body animation graph and54 variable hashes. Current graph values alone do not prove missing initialization.
- The index28 cache exists at PlayerControl+890; its producer computes a current orientation value. Mission floats and action state43 must not be transplanted as constants.
- Mission rolemask8 is owned by the active MissionHUD context. A body/IK dependency has not been established.
- SDK enable_animation_state_machine resolves Unit vtable+1C8. It preserves an existing Unit+178 animator and constructs one only when absent. Current reconstructed animators are already nonzero.
- First-person visibility and body/gear rendering have separate owners. The normal visibility API queues a world command; immediate return is insufficient acknowledgement.
- Repeating the full player constructor would create another first-person child. No reversible existing-actor reinitialization contract has been established.

## Source review corrections

The MissionHUD preflight now validates all four observer list capacities, including the previously omitted+2D68 list, and refuses a GUI context depth whose next native push would overlap the depth field. Its data tick receives the PlayerManager entity ID, which differs from the avatar entity ID. The isolated native HUD fixture passed after these corrections. The held full game-mode route remains disabled, and these corrections have not been deployed live. Independent MissionHUD teardown still needs to precede the ship's shared-root destruction and own its role3 changes.
