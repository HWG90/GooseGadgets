# Native ADS Camera Test

Version 0.1.27-test keeps the native first-person rig during ordinary movement, sprinting, diving and prone whenever the game permits its camera. Animation-layer numbers no longer force a head-camera handoff. The native camera keeps its normal movement; arms and weapon move together. Normal aiming blends a quarter of the placement back toward the native pose and adds a clear pull toward the camera and center. It also blends in a subtle 1.05x scene magnification over 120 ms. Hip-fire uses the game's live TPV FOV setting across weapons; full ADS keeps the native weapon/optic zoom and original sight alignment.

- **F11:** toggle first person on/off.
- **F8:** open/close the placement editor. Opening it enables first person if needed.
- **Hold left mouse and drag outside the panel:** move arms and weapon sideways/up/down.
- **Mouse wheel:** move forward/back. **Shift:** fine adjustment.
- **Arrow keys / PgUp / PgDn:** keyboard placement and depth.
- **Enter / Save:** save placement and close the editor.
- **Esc / Cancel / F8:** discard unsaved changes and close the editor.

Closing the editor leaves first person enabled. Turn it off with F11 or **DBF-MCM > Native ADS Camera Test > Turn first person off**. Both hotkeys are rebindable there. Close Epic LUT before opening placement; the editor checks its separate capture helper and the gameplay mouse baseline. Start with a firearm equipped and aim released. The mod loads idle; there is no automatic start on load.

First person has no countdown. Manual enabled intent survives weapon changes, temporary action cameras and player replacement. The old weapon camera is released before inventory ownership changes; a fresh firearm lease is prepared only after the game returns to a safe, released camera. A separate camera helper covers supported normal-camera gaps with body-relative head damping. View pitch does not orbit that fallback camera into the helmet. The observed vault state now uses this guarded fallback instead of pulling into third person. Native ADS owns its own camera and zoom. Cinematic, swimming, seated and retired-player states yield to the game; a fresh safe player can resume without another toggle. No old weapon lease is carried into a new inventory.

The local head, torso, hip and shoulder customization meshes are hidden from the camera while first person is enabled. The two separately identified shoulder pads on the supported native first-person rig are hidden too; arms, elbow pads, hands, legs and weapons stay visible. Hidden pieces retain shadow casting, including pieces the native camera had already hidden. Cleanup restores only the visibility bits this mod still owns. The native rig's chest cloth shares a mesh with sleeves and wrists, so that combined mesh remains visible. Unsupported rig layouts are left alone. Holding S requests focused backward locomotion, without enabling aim; releasing S restores the captured movement flag.

While FPV owns the view, depth of field is disabled through the renderer's existing setting, including during full ADS. Turning FPV off restores the captured setting after the renderer acknowledges it; an already-disabled setting remains disabled. Photo Mode's active view is left alone. The owned weapon camera also suppresses its three near/far blur maxima for zoom weapons.

Weapon movement uses actual character travel and camera turns. Sprinting blends the muzzle down and left, then returns smoothly on release. Normal aim pulls the rig 4 cm left and 6 cm toward the camera for a visible aiming stance; full ADS clears that shift for native sight alignment. The aim stance stays active when optional weapon movement is disabled. Extra bob and turn inertia fade out during sprint so they do not compete with its native animation. Saved placement remains separate; editing pauses added movement. DBF-MCM exposes Weapon movement and its strength. The movement clock uses a high-resolution timer, and repeated timestamps preserve the current pose instead of snapping to zero.

Version 0.1.27 doubles the optional walking bob distance and halves its cycle rate per distance travelled. The MCM status changes on lifecycle events instead of rebuilding the live diagnostic counters every frame. Explicit console diagnostics remain available. Native pose and camera display statistics no longer wait for their render-policy locks; ownership, health checks and timed cleanup remain active.

Normal aim follows the game's accepted aiming state, including native hold/toggle behavior and rebound controls. Version 0.1.22 corrects the earlier presentation signal, which could stay off during normal aim. The native first-person controller flag keeps its separate camera-lifecycle role.

Saved XYZ placement is stored by LLL only when you save. Reset previews the initial (+0.15, 0, -0.12) metre offset without saving it. Placement is limited to 50 cm per axis. This translates the existing arm animation rather than replacing it.

The console API also supports bounded diagnostics:

```lua
NativeADSCameraTest.toggle()
NativeADSCameraTest.start()             -- manual lifetime, same as start_pose(0)
NativeADSCameraTest.edit_placement()
NativeADSCameraTest.placement()         -- copy of current XYZ
NativeADSCameraTest.stop()
NativeADSCameraTest.status()            -- status and result table
NativeADSCameraTest.depth_stats()       -- lazy depth-test diagnostics while active
NativeADSCameraTest.start_pose(30)      -- optional 30-second diagnostic
NativeADSCameraTest.start_native(30)    -- original camera-only comparison
NativeADSCameraTest.preflight()         -- read-only readiness check while idle
```

`start_camera_only` remains a compatibility alias for the arms/weapon mode. The MCM native-camera comparison remains a 30-second diagnostic.

The test helper leases four writable UnitAPI dispatch pointers, preserving executable bytes and page protections. Guards check the supported binary build, exact callsite/input pointer, current request ownership, entity generations and the verified rig graph. Cleanup restores the verified native baseline and owned dispatch pointers. Retired callbacks remain process-pinned and forward normally. The editor uses DBF-MCM's public cursor ownership API and releases its input/view on close or focus loss.

Version 0.1.15 extends the visibility filter to torso/hips to reduce action and vault clipping; it leaves the native camera policy unchanged.

The shared-branch placement in 0.1.7 received visual acceptance. Version 0.1.11 received live acceptance for TPV hip FOV, normal ADS zoom and visible weapons. Version 0.1.14 fixes the action-state feedback loop introduced by the head-camera candidate, adds helmet-only visibility and focused backward movement, and softens fallback head bob. These changes require live assessment. Firing alignment and all weapon/animation transitions still need in-game assessment.

Build and verify outside the game:

```powershell
py -3 native/build_editor.py
py -3 native/build_fov.py
py -3 native/build_camera.py
py -3 native/build_blur.py
py -3 tests/run_tests.py
py -3 tests/editor_binary.py
py -3 tests/fov_binary.py
py -3 tests/camera_binary.py
py -3 tests/blur_binary.py
py -3 tools/build.py
```

The explicit allowlist produces `dist/releases/native-ads-camera-0.1.27-test`. The pose helper uses `_0_1_27.dll`, FOV uses `_0_1_23.dll`, and head fallback uses `_0_1_27.dll` and blur retains `_0_1_16.dll`; the older alignment helper remains for the preserved internal diagnostic. Research, recordings, game files and saved settings are excluded. Building does not install or publish.


Photo Mode owns its view while active. FPV keeps waiting intent and releases its native helpers until Photo Mode closes. Current Photo Mode exposes a local camera ownership flag. FPV observes that flag and resumes when Photo releases it; having ActionCam loaded alone does not block this route. Older Photo releases retain the existing owned callback chain, which preserves its prior reader and restores only its own callback. FPV never closes Photo Mode, acquires its lease, or changes mouse focus.

A labeled sprint trace reproduced repeated motion resets caused by the old timer. This iteration addresses those resets. Look-around jitter also occurs with stock placement, added motion disabled and in the base game's full ADS, according to the live comparison; general native animation smoothing remains separate from this sprint fix.

FPV reuses successful immutable binary checks only within a single update, invalidates mesh discovery when its identities change, and skips unowned backward-movement work when S is released. Native helper health is read every frame; expanded display counters refresh at staggered 10 Hz. DoF has no renderer-setting subscription, so its owned acknowledgement/readback is bounded to 2 Hz with immediate view-ownership checks. Unchanged settings are never reapplied.


Version 0.1.23 adds a guarded viewmodel-depth compensation test. The helper compensates for the optic's zoom-dependent presentation depth in hip fire and normal aim. The helper adjusts a copy of the existing weapon-branch input, keeping its fresh animation and saved placement separate. Native ADS keeps the original lens and depth. Unsupported animation/coupling modes forward their native depth; they do not acquire a replacement camera or modify request fields. F11 still controls the lifetime manually. Camera and ADS handoffs require visual assessment with this test.

Version 0.1.24 retains that depth test and removes the FOV statistics query's wait for camera-policy display values. Native ownership and error state remain fresh. The helper's camera update and native ADS path are unchanged.

Version 0.1.25 additionally compensates the matching camera-carrier translation using the same native update's quaternion. It preserves native rotation solving and full ADS. Unchanged DoF monitoring reads the guarded, consumed setting value; setting changes and restoration still use the SDK's renderer acknowledgement.

Version 0.1.26 permits the verified bridge body state while the game's actual combat-control role is enabled. Normal ship controls continue to wait. Bridge Combat remains responsible for enabling and restoring combat controls.

Unchanged motion transforms are no longer resubmitted. Tiny invisible motion tails settle to zero; changed motion and ownership checks remain fresh. Pose display counters refresh at 10 Hz while native health and blend values stay current each poll. When the global renderer DoF setting is positively acknowledged off under FPV ownership, the separate scoped-blur filter is released; it remains a fallback when global suppression is unavailable. No extra steady renderer polling is added.


### Per-weapon placement (0.1.28)
F8 edits the equipped firearm. Drag to move, wheel for depth, Enter saves for that weapon resource; Esc cancels. Saved profiles load on weapon acquisition and survive restarts. Weapons without a profile use your existing shared placement. Switching weapons closes an unsaved editor without applying its draft to the next weapon. Hips remain visible.


0.1.29: Placement editor **Save weapon** / Enter saves only this firearm. **Save all** makes the current placement the shared default and clears all individual weapon overrides in one settings write. You can then create individual overrides again.


### Action placement editor (0.1.30)
Use the < / > selector in F8 to edit Idle, Normal aim, ADS, Sprinting, Crouching, Prone, Sliding or Diving placement. Switching actions discards unsaved changes for the previous selection. Save weapon / Enter saves this weapon and selected action; Save all replaces only that action across weapons. Other actions remain intact. Preview changes placement; it does not force character animations. ADS offsets default to zero (original native sights); custom offsets move the sights while preserving zoom.

Idle, normal aim, ADS and sprint auto-select from existing verified signals. Additional actions display a preset-only notice until a labelled, resource-specific live state mapping is recorded. No stance is inferred from arbitrary key presses. Existing shared and weapon placements remain fallbacks.


0.1.31 maps the labelled current-build crouch, prone, slide and dive sequence. All eight editor actions now auto-select on the verified character resource. Slide and dive flags take precedence over aim; ADS wins. Unmatched resources/states retain idle placement. The selector previews placement without forcing an animation.


### Mouse yaw/pitch (0.1.32)
In F8, left-drag translates and right-drag rotates yaw/pitch. Wheel changes depth; Shift provides fine control. Save weapon / Save all stores position and angles for the selected action. Reset clears angles. Existing presets default to zero rotation. Each axis is limited to30degrees; the combined rotation including sprint motion is clamped to the existing35degree rig limit. Authored ADS rotation applies only when the native sight coupling is zero; coupled sights retain native orientation.


0.1.33 raises mouse yaw/pitch to±90degrees per axis (120degree combined quaternion bound) and removes the procedural sprint translation and down-left rotation. Sprint action presets now solely define placement/orientation; sprint bob suppression remains to avoid stacking sway over native animation.


### DEV: FirdPerson (0.1.38)
Enable normal FPV with F11, release ADS, then select **DEV: FirdPerson (capture current FPV)** in MCM. It captures FPS shoulder placement, returns to the native TPV animation rig and mounts the camera at the head. It stays off until you select it. F11 stops it.

F8 edits the visible linked arm and weapon render skeletons: left-drag position, right-drag yaw/pitch, wheel depth, Shift fine control. The same per-weapon/per-action profiles and Save weapon / Save all apply. Native body animation and internal weapon animation remain untouched; full ADS yields to the original camera. Attachment discovery runs on appearance/weapon invalidation, and each changed renderer publishes once.

The previous body-joint write/publication chain was removed after failed visible tests and flickering. Bounded stationary TPV captures now show both arm/weapon translation and rotation, with automatic restoration. This proves the render control path; full FirdPerson editor, reload and weapon-swap visual acceptance remains to be tested.

0.1.42 adds a left-only support constraint using each weapon's captured native FPS grip. Reload and unsupported actions retain native movement; the right-hand/weapon transform is unchanged. Grip references refresh during full ADS, so use full ADS once after changing to a weapon not yet captured. Visual acceptance is pending.


0.1.43: Shift+F8 edits the FirdPerson head camera (left-drag side/height; wheel depth), saved separately from weapon/action placements. The default camera is 18 cm farther back. Reset all clears the corresponding camera or weapon placements. Built-in normal-aim translation is disabled by default; authored aim presets and native full ADS remain active. Camera offsets update only on edits, with native ownership and generation checks.


0.1.44 free-aim experiment: enable native FPV, then choose DEV: Free aim (30 seconds). The camera holds a 5-degree horizontal / 3-degree vertical dead zone, tightened over 120 ms to 22 percent during normal aim. Full native ADS bypasses it immediately and rebases on release. FirdPerson is shelved and refuses entry. F11 stops FPV and the test. No weapon, muzzle, firing direction, aim target or projectile transforms are written.

The existing camera-position callback validates the captured adjacent camera-rotation call and changes only its current-thread stack quaternion scratch at position+64. The camera's current local 3x3 and world matrix recover its animated parent before the world-space dead-zone result is converted back to local space. No additional callback, executable patch, input capture, timer or frame-loop Lua diagnostic is introduced. Generation ownership and native ADS are checked in the existing callback; unsupported matrices or stack layout pass through. Optional timing stops with the 30-second test. Barrel/impact alignment and handling remain gameplay checks, separate from synthetic fixtures.


0.1.45 replaces the inferred parent (cached camera world times inverse local) with the current generation-owned FPS rig camera bone50 world pose, checked against hash60ED8C39/link40001 and the external pose binding. A deliberately stale-camera regression fixture covers the former frame-stage assumption. An explicit 3-second read-only observation compares both parent estimates; it does not enable free aim, does no camera writes and expires independently. Live acceptance is pending.


0.1.46: posture presets use verified native crouch/prone/dive/slide flags rather than exact locomotion blend indices. Sprint additionally accepts labelled bridge L1=75/78,L3=68 only with the verified bridge lifecycle; the existing L3=71 path remains. Camera kick uses rising edges of the native flag102 shot pulse observed during labelled single/burst firing. It adds 0.35 degrees upward per pulse, caps at 1 degree, and recovers with a 75 ms decay after the free-aim zone. Full ADS bypasses added kick; native gun/projectile transforms are unchanged. The kick is idle at rest and does no continuous timing or transform sampling after settling. Disable via camera_kick_enabled=false in the mod configuration. Weapon coverage and dry-fire behavior remain unverified.


0.1.47 candidate: F8 middle-drag adds roll (Shift for fine adjustment), persisted per weapon/action. MCM > Bob and sway exposes independent weapon/camera strength and speed plus sprint movement. Settings are cached until an MCM change event; unchanged camera motion coalesces without native updates. Sprint defaults now add a lowered/canted pose and stronger gait motion; user presets remain the base.

Camera continuity records the displayed native-FPV world pose and blends a 6/4 handoff, ADS release or weapon request change over 150 ms. The correction decays against the current target so settled mouse look has no added smoothing delay. Full ADS retains original arguments; player-generation loss and jumps over 2 metres invalidate continuity. Camera motion is bounded to 3 cm / 0.03 radians. A 400-callback profiling command is explicit and stops automatically. Native and Lua fixtures are separate from pending live transition/performance acceptance. TPV support-hand pose retargeting is not included yet.
