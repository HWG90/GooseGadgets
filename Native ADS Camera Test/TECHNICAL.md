# Native first-person shared-rig offset

## Current candidate: 0.1.16-test

Preserve the native movement accepted in the original camera-only test. Offset the shared arms-and-weapon branch rather than the entire camera carrier or the gun alone. The initial translation is (+0.15, 0, -0.12) in its parent coordinates, blended over 150 ms to zero during actual aiming. No gameplay aim bit or input is written.

### Guarded build and attachment graph

Game.dll timestamp `0x6AB3B43F`, image size `0x4744000`; helldivers2.exe timestamp `0x6AB382E4`, image size `0x39E8000`.

Native entry `+0x127DDB0` calls constructor `+0x127DE20` and evaluator `+0x1286330`. Entry attaches the camera unit to the FP model camera node at `+0x127E574`, attaches the weapon at `+0x127E647`, and initializes weapon root-local position to zero at `+0x127E666`.

A read-only live audit resolved the generation-validated FP unit through EXE registry `+0x1A100F0`. The virtual scene-graph getter at unit-object vtable `+0xE8` is EXE `+0x2BD870`, bytes `48 8D 41 60 C3`, returning the embedded graph at object `+0x60`. Graph count is u32 `+0x10`, packed parent links pointer `+0x38`, ID32 hash array pointer `+0x40`. A valid parent link has low16=1 and parent index in high16. The count was 63.

The verified hierarchy is:

| Node | ID32 / decoded name | Parent |
| --- | --- | --- |
| 4 | `BCCF81E5` / root | 3 |
| 5 | `9B115563` / shared offset branch | 4 |
| 7 | `6F3BD021` | 5 |
| 8 | `4FDD3337` / weapon attachment | 7 |
| 10 | `03752C98` / l_shoulder | 7 |
| 12 | `1CA2CD66` / l_elbow | 10 |
| 13 | `5C0C68D3` / l_hand | 12 |
| 30 | `1620B2CE` / r_shoulder | 7 |
| 32 | `31E34DAC` / r_elbow | 30 |
| 34 | `248004F5` / r_hand | 32 |
| 50 | `60ED8C39` / camera | 4 |

Thus both arms and weapon descend from node 5; the camera does not. Node 5 and camera 50 share parent 4. The rig helper binds this exact graph and rejects changes instead of assuming an arbitrary node index.

The local-pose getter EXE `+0x1FC520` indexes 64-byte records through graph `+0x20`; position is at record `+0x24`, scale at `+0x30`, and its first 36 bytes hold the local rotation matrix. Read-only samples of node 4 and camera 50 had identity orientation in normal camera kind 4; camera translation was (0,0,0.146794). This supports the starting local-axis offset in that sampled pose, rather than proving every animation's screen-space orientation.

### Narrow modification and native feedback

The target is UnitAPI `+0x38` call `game.dll+0x1288420`, return `+0x1288424`, on the leased FP unit/node 5 with the vector pointer exactly `request+0x48`. The helper copies the native vector, adds weighted XYZ displacement and forwards it once. It leaves request memory, W bits and all other calls unchanged. It does not submit a weapon-root offset.

The final carrier root-position and root-rotation calls at `+0x12887C9/+0x12887E9` always forward their exact original arguments. Their role includes tracking the camera rig, which explains why suppressing them in 0.1.5 froze the viewpoint.

The native solver's relevant inputs remain independent of this parent translation:

- Sight helper `+0x173EE00` subtracts sight-unit root world position and applies inverse root orientation for a nonzero selected node. Moving a shared ancestor translates root and sight equally. The node-zero fallback has different math, so the candidate retains its nonzero sight-node guard.
- FP weapon attachment local-pose reads at `+0x1287361/+0x1287490` read node 8 relative to node 7, unchanged by moving ancestor 5.
- Camera local-position read at `+0x1287A41` reads sibling node 50, outside branch 5.
- Weapon world-pose use at `+0x1287925..+0x1287954` consumes orientation basis, not translation.

These are the separation evidence for the candidate, not universal proof of unchanged firing behavior. Moving the attached weapon changes its world muzzle nodes; inspected native beam code consumes muzzle world positions. Some kind-6 origin paths use a camera shortcut instead. Full firing-path and network consequences are not established by this test and must not be described as purely cosmetic.

### Ownership, blend and cleanup

The new DLL filename is `native_ads_editor_0_1_8.dll`, using unique `NADSE_*` exports and ABI 2 with 104-byte Config and 80-byte Stats layouts. Config includes XYZ placement. The historical `weapon_updates` field counts shared-branch offset calls; `zero_restores` counts native-baseline restorations.

Begin requires the supported binary/API/callsite contract, a released safe normal camera, exact avatar and weapon descriptors, current registry generations, and the verified graph. It uses owned atomic compare/exchange of writable dispatch slots. Begin=0 owns no lease; Begin=1 arms; Begin=2 owns partial cleanup and skips camera entry. A nonzero generation token is published before any slot is acquired; edits, stats and End validate it. Lua preserves the token as opaque uint64 cdata. Stale tokens cannot alter a later session.

Config duration_ms=0 explicitly selects manual lifetime. Positive values 1..30500 use an independent monotonic deadline. SetPlacement accepts finite XYZ within +/-0.5 metres for the exact live generation after rechecking ownership, rig, API and sight guards. It commits absolute placement under the same policy lock used by callbacks, without invoking the engine or extending a bounded deadline.

Real gameplay aim or native controller activity selects offset target zero while a valid kind-6 request survives. Other blocked/seated/retired states remain invalid. The scalar blend uses 150 ms smoothstep and fresh native vectors, avoiding accumulated offsets.

Cleanup never substitutes zero for the animated node position. A native baseline can be restored only while the same owned kind-6 request, graph and generations still validate; changed owners/graphs are not written. Owned dispatch restoration preserves foreign replacements and retains cleanup reservation when its own slots cannot yet be restored. Callbacks remain process-pinned and forward after disarm.

The primary Lua session has no timeout and records the user's enabled intent separately from its current weapon lease. A weapon swap retires the old weapon camera before the inventory changes, waits through the observed mask-2 inhibition, then prepares a fresh camera lease. Enabled intent persists through the third-person interval. It never carries a weapon lease across identities. Explicit stop clears enabled intent even while waiting or cleaning up. Player/context changes and unsafe snapshots stop the session. Native aim is left to the game; reacquisition waits for its release. Bounded diagnostics retain one original deadline of at most 30 seconds and their six-reacquisition limit.

The captured weapon-swap sequence sets controller mask u32=2 before changing the wielded weapon, then clears it. Version 0.1.9 preserves enabled intent during this exact inhibition only (supported kind 4/6, no seating, guard byte zero). The snapshot remains unsafe for native entry and offset work; it authorizes only retirement and waiting. Unknown masks and other unsafe states retain the stop behavior.

The rejected 0.1.10 candidate retained camera kind 6 through the inhibition and attempted old-request exit after the inventory changed. Although it validated old weapon generations, the native exit also calls +0x826450 before resolving the request weapon. That path updates current inventory slots via +0x9A9FC0, while later attachment cleanup still targets the old request weapon. This crosses presentation ownership. The user observed janky swaps and an invisible weapon that persisted after stopping and a natural ADS round trip; respawning restored it. The late-exit branch was removed from maintained runtime and preserved under ignored dist/research/rejected-retained-0.1.10. Do not infer whole native cleanup safety from request/weapon validity alone.

### Live TPV FOV

The authoritative live vertical_fov setting is f32(*(game+0x3326340)+0xAC408). The settings loader at +0x102CC89 names vertical_fov, reads it at +0x102CC98 and stores settingsStruct+0x2C at +0x102CCC6; initialization copies that struct to the live settings block at +0xAC3DC. Native camera code converts degrees with the pi/180 constant at +0x23C6660. A live read found TPV=90 degrees while the hip kind-6 request held 45 degrees, confirming the weapon-specific narrowing.

The independent FOV helper leases CameraAPI+0x80, reached through *(*(game+0x3326308)+0x20). The captured setter is EXE+0x30D990, prefix f30f114934c7415000000000e90f211c00. Native application calls it at game+0x127A11A (return +0x127A120), passing the camera pointer and blended FOV radians. The setter stores the lens value at camera+0x34. The helper filters that exact caller and owned camera/request, verifies stable avatar/body ownership, and substitutes the live TPV degrees converted to radians only while un-aimed. It forwards real ADS values unchanged. The source setting and request FOV field are never written.

This lease is independent of the weapon-pose helper. It persists across camera retirement and reacquisition, without relying on the old weapon's unit generation; normal kind-4 rendering forwards unchanged. Unknown unsafe states and unmatched calls forward. A fresh known request is bound after camera reacquisition, with an immediate guarded lens application so the new weapon cannot show its narrower hip FOV for the first frame. Callback pinning, generation tokens, owned slot restoration and independent cleanup retries preserve the dispatch lifetime contract.

### Placement editor and input

F8 opens/closes placement; F11 toggles FPV. DBF-MCM stores both rebindable virtual-key controls. Polling is edge-triggered and respects focus, menu key capture and foreign input ownership. The editor closes MCM before acquiring its public camera_input API, rechecks ownership immediately before acquisition, and consumes menu_sample once per frame. It never releases a foreign capture. Partial acquisition or view cleanup retains retry state.

Epic LUT uses a separate native capture helper. Its retained frontend at package.loaded['dbf.epic_lut.frontend.v1'] exposes menu visibility and capture state; shared MCM/LLL input status alone cannot detect it. Placement refuses entry while that frontend owns input, checks for the normal mouse-focus/cursor baseline before capture, and closes its own editor if the LUT frontend becomes active.

Dragging changes X/Z and the wheel changes Y. Shift applies fine movement. Enter commits through LLL mod.set only after its settings write succeeds. Cancel restores the original placement without ending FPV. Save, cancel and focus loss release the editor cursor/view; mod disable separately stops native camera work. The input route was probed in the live normal camera without changing the native controller bytes; kind-6/editor visuals remain a separate acceptance check.

### Evidence and packaging

Version 0.1.5 logs proved both root calls were skipped; its video showed wrong camera tracking. Version 0.1.6 logs proved all root calls forwarded and the gun offset ran; the user reported it mostly worked, and their screenshot showed the gun displaced from the hands. This candidate changes only the presentation offset target to the shared branch and keeps the previous movement and ADS blend design.

Ignored `dist/research/weapon-pose/arms-rig` contains captured graph arrays, getter excerpts, bone-name matches, local-pose samples, screenshot identity and read-only transcripts. These are excluded from packaging. Earlier 0.1.6 native sources are preserved under `dist/research/native-pose-0.1.6-preserved`.

Offline fixtures test transform forwarding, shared-branch filtering, source preservation, blend/lifetime, hierarchy drift and cleanup. They do not prove visual fit, camera comfort, animation quality, firing alignment or every live transition. Build, package identity, installed bytes, loader acknowledgement, helper observations and visual acceptance are recorded separately. Build scripts allowlist runtime files; never package research, captures, game files or settings.


### 0.1.12 head-camera and motion candidate

The independent NADSC ABI1 helper (Config88/Stats80) leases CameraAPI+0x20. The final native camera application caller is game+0x127A135, target EXE+0x30DEB0. Normal-camera proof matched Camera+0x18 to the camera Unit graph, Camera+0x20 to node zero, no parent at UnitObject+0x1D0, and local XYZ to world XYZ. Native kind6 inputs always forward exactly; their local coordinate space is never used as a world position.

Body UnitRef generations and the exact avatar descriptor authorize each callback. World-pose wrapper EXE+0x1FD220 proves graph+0x28, 64-byte records, translation at +0x30. The head is resolved by hash 8C5570C9 and checked against the neck parent. Fallback requires the captured body animation resource 4D1C334D294DFA97, 31 layers and positive on-foot layer14 state36. Only controller masks0/2 are supported initially. Unknown, swimming, seated and non-gameplay states forward. These are positive scope gates, not a general death-state detector.

Fresh root movement is never smoothed. The head-to-root offset is damped with lag capped at6cm, with horizontal view-forward clearance and world-up eye offset. Version0.1.14 filters the offset in body-root-local axes, applying the fresh root translation and rotation immediately. A direct native6-to-eligible4 transition uses the head on its first frame, avoiding an intervening third-person pullback. Unrelated state changes/time gaps clear that transition shortcut. Native6 return is exact forwarding; visual continuity still needs live assessment. End drains adjusted calls and restores only its dispatch pointer; it never replays a cached camera pose. The camera helper writes no body scale, gameplay aim or rotation. Head visibility is a separate mesh-only manager described below.

The new pose helper keeps ABI2 Config104/Stats80 and adds generation-guarded SetMotion separately from saved placement. Translation is bounded to15cm per axis and composed with the existing hip/ADS blend. Lua samples the owned character root plus camera/parent4 world bases, derives travel-driven bob and turn inertia, and converts camera-local displacement to the actual parent coordinates. Editor, missing data, ownership changes, time gaps and teleports neutralize/reset the added motion. Rotation output remains advisory and is not submitted to a native setter.

Manual controller intent now yields through unsupported actions and player loss. It must finish old cleanup before rebasing to a new safe complete player snapshot. Every native pose entry calls the independent head-camera prearm gate before acquiring its weapon helper. Explicit stop/shutdown clears intent and independently attempts editor, native pose, lens and head-camera cleanup. Version0.1.11 remains the accepted fallback baseline until the new candidate is tested.


The read-only action module reproduces the current animation-state getter with registry/owner/graph checks. The resource-guarded on-foot layer14 state36 remains a life-state eligibility check. Layer1/3 animation indices are diagnostic/motion hints, not camera eligibility gates. The0.1.12/13 layer3 whitelist self-latched after exit: normal4 states44/45 were rejected before native6 could produce states66/67/69/70. Version0.1.14 removes that layer3/sprint gate; native controller masks, player/weapon generations, seated checks and the weapon-allowed predicate remain authoritative. Historical sprint states L1=78/79 or L3=71 are resource-guarded hypotheses pending a labeled live sprint. They only select procedural weapon-motion hints; they never force fallback. No custom across-body rotation has been authored. Initial F11 during an action can enable waiting intent without a native weapon lease; bounded diagnostics remain strict.


### 0.1.13 camera-provider handoff

The first0.1.12 live probe counted629 valid head substitutions and restored the original camera/FOV setters on stop. Its back-buffer image was owned by active Photo Mode; it is not visual proof of the head fallback. The probe confirmed Photo.active=true and the existing ActionCam compatibility bridge held=true. Version0.1.13 yields all native helpers while that foreign camera owns the view and preserves manual waiting intent.

The compatibility adapter only chains the public set_input_blocked reader, preserving its previous callback and conservative failure semantics. Callback ownership is inspected before restore; foreign replacements are preserved. It never acquires/releases Photo Mode's shared bool lease, edits Photo state, or closes its view. Native weapon entry requires a prepared sharing route before head-camera prearm. Visual motion and action handoffs remain pending a gameplay test with Photo Mode closed.

### 0.1.14 rig retention, head visibility and backward locomotion

Sprinting, diving and prone no longer voluntarily release the weapon camera based on layer1/3 animation indices. The positive on-foot life-state check remains; death/vehicle/unknown resources yield. A backend-retired pose lease has an explicit retirement marker, so a recovered snapshot cannot turn its already-disarmed helper into a false fatal error. Real stable helper failures still stop the mode. No stale weapon request is retained or exited after equipment ownership changes.

The head visibility manager resolves only local avatar customization slot0 UnitRefs at +0xDC/+0x104/+0x12C (owner +0x546A70, avatar stride0x1B8). Real World.units handles, current world, exact Unit generations/objects/parent ownership, current mesh objects and the supported SDK setter/layout authorize writes. Only captured full visibility masks255 are changed to0; existing0 remains untouched and partial masks are refused. Restoration applies only to the same live mesh still holding the owned0 mask, supports array reordering, preserves foreign masks and retains unreadable records for cleanup retry. Weapon/body render state is outside this manager.

Holding S uses the game's separate focused-locomotion byte, not an aiming bit. The current local avatar descriptor must match the locomotion pool descriptor; pool index/row, exact binary anchors and writable data memory are checked. Only0-to1 is owned. Key release, editor input, foreign camera, disable or lost gameplay ownership releases that contribution, preserving foreign values and retrying uncertain restoration.

Read-only live probes for these bindings and current helmet/focus ownership are under dist/research/immersive-0.1.14. Build/fixture success and installed identity remain separate from gameplay acceptance.

### 0.1.15 selective torso/hip hiding

The visibility manager also resolves torso/hip slots2/3 through all three customization layers (stride0x28). It never selects legs4/5 or arms6..9, and rejects a selected UnitRef shared with those preserved slots. Head0, torso2 and hips3 stay separate diagnostic groups, while the legacy hidden counter remains the total. Every mesh retains the same generation/world/parent/mesh-object and conditional restoration checks. Foreign partial masks are preserved and skipped per mesh instead of disabling visibility management for all parts.

A fresh read-only current-player probe found31 full-visible torso/hip meshes across6Units, distinct from all arm/leg Units. The head had five foreign masks1 after the game changed its native visibility; those values must not be restored as255. Native pose/camera/FOV helpers and their transitions are unchanged in this iteration.

### 0.1.16 vault fallback, aim split and scoped blur

A recorded100-second action trace had1387 native6 rows and84 normal4 rows. The28 normal4/controller-mask0x20 samples retained on-foot L14=36 but the old fallback forwarded a camera2.684–3.503m from the head with a flat replacement counter. The camera helper now accepts this exact mask during an already-owned normal4 callback, with all existing player/graph/space/life-state checks. Begin/Validate and native firearm entry still reject it; the head/torso display manager accepts the annotation only behind its confirmed fallback callback and fresh life-state proof.

Native editor policy separates hip (placement weight1), shoulder aim (avatar aim bit48 only, weight.75) and full ADS (native controller byte4 active, weight0). Full ADS wins when both flags are set. FOV uses live TPV degrees for hip/shoulder and forwards native zoom only for full ADS. Neither helper changes input or aim flags.

NativeFPV evaluator writes the scoped weapon's DoF maxima through game100A950→100A720→setter dispatch return100A80E. The parameter API at EXE310140 jumps62A0C0 and adds a5BD1E995 mixing step after raw Murmur64upper32. Verified property keys are near A7990477, far F07FC12E and close-far209F72CF. The secondary weapon postprocess row resolves an effect entity whose concrete DoF component class isF7A3101F; the provider's component arrays are bounded by+B8 high-water/+BC capacity, not+C4 (which overlaps a backing pointer).

A separate generation-owned blur helper filters only these three float Variant(tag2,+8) writes for the exact current weapon/request/player/provider/component. It preserves the other Variant bytes and forwards through the original setter with zero maxima. It leaves motion-blur and vignette components alone. Ordinary weapons without this component are a clean unavailable capability. Old leases end before any new weapon profile is acquired; dispatch ownership and cleanup are independent of pose/FOV/head and never require executable byte or protection changes. Global DoF remains enabled.

The look-around jitter remains reproduced with stock placement and added motion both zero. This rules out those two additions in that live comparison; it does not yet identify or repair the native rig/camera timing issue.


### 0.1.17 sprint pose and motion timing

The labeled live sequence recorded1,985 samples without reader errors. Both sprint intervals held L3=71, with L1=75 on entry and78 while running; there was no intermediate sprint-signal chatter. The motion diagnostics nevertheless showed63 invalid-dt resets in1,154 running rows, including14 during sprint. GetTickCount64 can return the same timestamp across successive render updates. The shared Lua clock now uses QueryPerformanceCounter/Frequency, and same-time motion updates keep the prior contribution rather than resetting the model. Backward time and ownership changes still reset it.

Sprint presentation blends a bounded down-left rotation and small left/down translation. Extra travel bob and look inertia fade away as sprint settles, with a short release hold and a slower return to avoid state-edge snapping. The rotation is converted from the current camera axes to the verified branch-parent axes, independently of saved placement. Normal aim fades sprint rotation back to the native pose; full ADS forwards the native rotation immediately.

The fresh native branch quaternion is supplied by the postpass at game12890DB (return12890DF) to UnitAPI+40, target EXE1FC7A0. The wrapper converts that quaternion to the node's local rotation while preserving local position and scale. This is a separate dispatch slot from the existing queued root-rotation setter+48. The new pose DLL leases+40 along with+38/+48, applies only to branch5 of the owned rig, and forwards root0/camera50 and all other callers unchanged. Config104/Stats80 ABI2 remain unchanged; the generation-owned SetTransform export updates translation and quaternion together.

Rotation requires a single active ring record matching the owned request, and request+98 exactly zero. All1,985 captured samples met the latter condition. The evaluator consumes the weapon world-orientation basis only on the nonzero+98 path, so that unsupported path forwards native rotation rather than risking a feedback loop. Each accepted rotation composes with the fresh callback quaternion; it never reads the previous modified graph rotation as a new baseline. Cleanup remains conditional on exact ownership, generation, graph and still-owned local pose. These guards and offline tests establish implementation scope; sprint appearance still requires live acceptance.


### 0.1.18 current Photo ownership compatibility

Current Photo Mode publishes DBF_PHOTO_CAMERA_OWNERSHIP instead of the retired DBF_PHOTO_ACTIONCAM_COMPAT bridge. The old FPV adapter mistook a truthy package.loaded ActionCam entry for camera ownership and latched a conflict even when the new Photo lease was available and held=false. Prefer the current local lease when present: validate available/held/disabled, yield while held=true, and otherwise permit the existing native FPV path. Do not acquire, release, dispose, wrap, or edit Photo's local owner. Malformed/disposed owners remain blocked. Legacy reader-chain behavior and conditional cleanup remain for earlier Photo versions. Switching providers cannot discard an owned legacy callback before cleanup.

The local ownership API exposes no event or subscription, so immediate handoff uses bounded constant-time field reads in the existing frame callback. It performs no upvalue scans, callback rewrites, allocations, or foreign API calls on the unchanged modern path. The actual lease is reacquired from the global each observation so replacement/removal is visible without a stale cached ownership result. No new timer, scan, background observer, or native hook is installed by this fix. Native camera/pose/FOV/blur DLLs and weapon movement are unchanged.


### 0.1.19 measured FPV CPU work

The deployed0.1.18 callback averaged6.625ms after its first30frames (median6.426ms,p9911.872ms). Its new compatibility observer averaged0.00506ms. A separate60-frame instrumented breakdown found2,135 backend reads per frame,13game binary validations and14executable validations; head visibility, controller snapshots and motion dominated. These inclusive sub-call timings overlap and are not additive. FPV was stopped after this bounded profile while preparing the candidate.

The candidate reuses only successfully validated immutable binary contracts within one explicit Lua update. Every lookup still resolves the current module base. Native invocation invalidates the scoped contract before its final fingerprint guard; mutable player, world, weapon, request, aim, animation and generation observations remain fresh. The scope is ended on normal return, early return and exception without allocating a new per-frame closure. There is no cross-frame positive ownership cache.

Visibility invalidates resolved handles and mesh metadata on player/body/world, appearance references, generation, object/renderer or mesh-array changes. Existing exact mesh-mask restoration remains independent. Focused backward movement checks the actual S input before expensive native eligibility work when it has no owned contribution. No key-up frame needs an unowned snapshot or animation scan. Native editor exact-forwards an unchanged quaternion before its mutation-only guards and batches the verified63-node metadata reads; modification and cached-restore guards remain intact. Sprint easing settles to an exact identity at a sub-visible threshold, allowing this neutral fast path.

There is no authoritative runtime subscription for these native memory-backed ownership fields, so unchanged lifecycle validation remains bounded by the existing single update callback; full mesh discovery is driven by explicit metadata invalidation. No periodic World.units scan is required in steady state. Cold initialization, ordinary active frames and action/Photo transitions require separate deployed measurements; source and fixture read-count reductions alone are not runtime speed proof.

### 0.1.20 helper diagnostics and scoped renderer DoF

Native helper ReadStats and returned ABI/installed/armed/error checks remain fresh every update. The reusable FFI buffer avoids allocation; only diagnostic counters and sample values expand at staggered 10 Hz. Invalid clocks, errors, handle changes and lifecycle operations force a complete diagnostic conversion. Each manager returns independent result copies. The deployed 300-frame sample measured a 2.902 ms steady mean, 2.983 ms median and 5.674 ms p99, compared with 6.625 ms mean on 0.1.18. These are bounded mod callback CPU measurements with uncontrolled player activity, not whole-game FPS comparisons.

A separate 90-second sample covered sprint, weapon swaps and native ADS transitions: 8,635 ordinary frames averaged 2.747 ms; 241 transition-window frames averaged 2.756 ms. Its 11.796 ms maximum coincided with a fresh native camera lease after ADS retirement. The additional guards and helper initialization on that reacquisition remain a cold transition cost, separate from unchanged-state work. All helpers remained healthy and the temporary timing wrapper restored itself. Photo Mode was not entered during that trace; earlier 0.1.18 Photo handoff received user acceptance.

The DoF manager uses Application.render_setting/set_render_setting for the verified dof_enabled Boolean flag. The setter receives serialized string values. It reserves asynchronous commands until renderer readback acknowledges them, avoids unchanged writes, and bounds acknowledgement/readback to 2 Hz because the API has no setting subscription. The view gate remains immediate and constant-time. Existing false and foreign true settings are preserved; pending restoration blocks new starts and retains the cleanup API. Photo-held views receive no DoF setting reads or writes, with restoration deferred until release. The reservation is process-global and survives avatar turnover. Live readback confirmed true before FPV, false while active, and true after an acknowledged stop; the user's FPV intent was then resumed.

### 0.1.21 shoulder aim presentation

Normal aiming adds 4 cm left and 6 cm toward the camera in the verified camera-local basis. This aiming stance is separate from optional weapon bob/sway strength. Editor input still freezes it; full ADS clears it for native sight alignment. The native FOV policy blends a 1.05x focal magnification from the live TPV lens over 120 ms and returns on release. Full ADS immediately forwards native weapon zoom. Selected-weapon zoom also feeds earlier native rig offsets; consistent viewmodel presentation across those zoom selections is a separate investigation.

### 0.1.22 accepted normal-aim signal

The 0.1.21 presentation incorrectly treated native controller flag48 as normal aiming. A bounded read-only trace recorded684rows with no reader errors. Ten native6/running samples had accepted gameplay bits82/125 both true while48 and controller+4 were false; another21running samples had all four false. Native full ADS had48/controller+4 true as well as82/125. The accepted pair persisted after physical RMB release under native toggle behavior, so physical button state would be an incorrect production substitute. Native game+A40B50 reads bit82 directly; the existing HUD aiming reader corroborates82 with125.

Add snapshot.shoulder_aim from the agreeing82/125 pair in the already-read24-byte flags block, with controller+4 taking priority. Leave snapshot.aiming as legacy48 for the existing entry, release and camera lifecycle checks. Lua motion sampling, its motion-disabled idle gate, native placement weighting and native shoulder zoom use only the separate accepted signal for presentation. Mismatched gameplay flags fall back to hip presentation. The native pose entry veto retains exactly its previous48/fullADS meaning; normal aim alone does not introduce a new Start refused condition. This correction adds no polling, memory read, input interception or mutable-state cache.

### 0.1.23 depth compensation test and performance

The game computes a separate presentation distance from selected optic zoom even outside native ADS. A read-only same-request capture at a fixed90degreehip scene lens measured0.056525864m at1x,0.173968717m at2.5x and0.247649044m at3.5x. Inverting the native tangent/coefficient calculation produces the same authored1x reference within0.0000016m across those selections. The test uses the existing owned node5 input-copy hook to compensate this depth contribution while preserving fresh native animation. Native request fields and executable instructions remain unchanged. FullADS retains its native lens and depth. Detailed source evidence and live trace inputs are retained in dist/research/viewmodel-zoom.

Review rejected reading targetFOV from caller+5C at the late setter: native1287F41 overwrites that location with orientation scratch first. A separately owned UnitAPI+0 local-position getter observer at1287A41/return1287A44 captures the supported early state before that overwrite, forwards the original arguments and pointer, and binds the observation to the current request, thread and invocation. The later node5 setter consumes only that observation. Fresh readback confirmed the getter slot targets EXE1FC450 with the expected wrapper bytes. The helper leases/restores this fourth data pointer alongside its prior three setters; unrelated getter calls forward without native ownership scans. Unsupported or unprovable observations leave depth native. The original104/80Config/Stats ABI is unchanged; a separate104byte diagnostic export is queried only on explicit depth_stats calls.

The0.1.22 on/off/on comparison measured mean Lua callback work3.036/0.058/2.561ms and mean frame callback intervals9.225/8.365/8.653ms after discarding each window's first30frames. Those intervals include the whole game and scene differences between FPV and TPV; Lua timings do not include native hooks later in the engine frame. The available Profiler.render_stats call returnednil, so no CPU/GPU field attribution is claimed.

Runtime motion coalesces only an exact7-value transform with the same lease, phase and ADS mode. Changed outputs and all first submissions still validate normally; resets, errors, editor and lease changes invalidate the signature. Tiny optional translation tails settle at10micrometers so idle eventually stops submitting. This skips redundant writes and their validation, not controller health or native callback ownership checks. Header batching retains the same compared values and final generation/object rereads; immutable fingerprint hex decoding is reused. Pose uses one FFI stats buffer; ABI/installed/armed/expired/error and blend values stay fresh on every native poll, while diagnostic counters expand at staggered10Hz.

An allocation-free DoF query permits releasing the scoped blur helper only while FPV owns an acknowledged, uncancelled disabled renderer setting. Unownedfalse, pending commands, SDK drift, foreign ownership and closing states retain the native fallback policy. Existing update ordering and independent cleanup remain unchanged. The same-FPV-camera blur-on/suppressed/restored windows measured mean Lua3.029/2.814/3.351ms and frame intervals9.381/9.184/9.967ms; activity variability limits attribution. Three expensive native blur-property events per rendered frame were not observed: the selected override count stayed at3 during long steady samples. Source read-count estimates for those events must not be presented as per-frame runtime cost.

### 0.1.24 FOV diagnostic contention

The first installed23 candidate reduced sampled Lua update means to1.900–2.143ms, but FOV remained the largest measured manager at786microseconds. Its nativeReadStats alone measured666microseconds mean over1200calls; an unarmed separate-process sample averaged2.65microseconds. These short samples support investigating active policy-lock contention and do not establish GPU time or FPS gain.

FOV helper23 publishes a diagnostic lens tuple independently of the camera-policy lock. ReadStats makes one bounded snapshot attempt, retaining the last complete display tuple when publication overlaps. It keeps the lifecycle control lock for generation validation and reads installed/armed/error and counters freshly from atomics. The native setter, original engine call, ADS lens path and Begin/Bind/End ownership guards are unchanged. New owned generations reset their diagnostic state. Reporting a display tuple never waits for the camera callback to finish. Deployed measurements and their limits are retained separately in dist/research/performance-0.1.23.

### 0.1.25 camera carrier and steady DoF monitoring

The labelled live zoom cycle kept body position within8micrometers while camera-relative forward moved from+0.07698m at1x to-0.03940m at2.5x and-0.11371m at3.5x. The change matches the negative of the native presentation-distance change; right/up stayed approximately constant. Thus node5-only correction stabilizes viewmodel scale while leaving a physical camera shift.

The same evaluator's root0 setter at12887C9 receives the fresh position at callerRSP+240, immediately after the native root quaternion at+230. Native math contributes -D_effective*rotate(q,+Y) to that root. A one-shot continuation of the paired node5 decision therefore applies -node5_delta*rotate(q,+Y) to a copy of this exact root input. It does not read last frame's camera basis or change native quaternion inputs. Full ADS, unmatched invocations, unsupported branches and foreign writes remain native. Native orientation solving can itself depend on depth; this test cancels the proven direct translation and does not claim complete orientation decoupling.

DoF's31 unchanged-setting polls measured1.812ms mean/3.719ms maximum;1769 nonpoll frames averaged10.6microseconds. The SDK getter queues command16 and waits for outstanding renderer work before returning the Boolean. The string setter queues command17; its consumer updates the sorted Variant table at EXE1A102B8, with type4 and Boolean byte+8. The backend observes that consumed row only after the SDK has acknowledged our disabled setting, verifying the executable/bindings, current table identity, key, type and Boolean before and after each read. It caches a lookup location only. Acquisition, command acknowledgement and cleanup retain SDK synchronization; unsupported observations fall back to the original getter. Monitoring remains bounded2Hz because no setting-change notification was identified. The retained command-consumer disassembly is in dist/research/performance-0.1.23/dof-render-setting-consumer-proof.txt.

### 0.1.26 combat-enabled bridge

Bridge Combat removes role mask4 and adds combat role mask2 at avatar_owner+53D8B0+avatar_index*1238+FD0, the first word of FPV's existing24-byte avatar flag capture. The observed bridge has scene3, role mask2, known body resource4D1C334D294DFA97/31layers and L14=3. Requiring mission L14=36 blocked that valid combat actor. The additional permission requires exactly the observed bridge state, actual combat role and fresh scene3; a Lua mod-enabled flag alone does not grant access. The existing mission state36 path and ownership/generation/controller/camera checks are retained. Native fallback and the Lua camera/body/movement gates use the same eligibility. FPV never changes combat role flags itself.

### 0.1.27 display diagnostics, bob and visibility passes

The pose and camera helpers publish display-only statistics independently of their render-policy locks. Readers make one bounded snapshot attempt with the last complete display tuple as fallback. Fresh atomic installed/armed/error/counter values and control-generation checks remain; pose timed expiry still takes the policy lock, rechecks the deadline and restores through the original guarded path. Pose copies the immutable lease deadline under its control lock. Camera publishes only from the armed/owned branch while holding its policy lock, so a delayed retired callback cannot overwrite a newer generation's diagnostic tuple. Native evaluator math, setter calls and mutation guards are unchanged. These changes target the measured active ReadStats wait and require deployed timing before claiming a runtime gain.

The controller emits a status notification only when its lifecycle label changes. MCM stores a dirty flag and checks registration, phase, enabled/cleanup and editor state before touching controls; an unchanged frame performs no status formatting or control walk. The listener is released after successful menu unregister. Explicit status() retains technical counters. The existing single frame update and safety observations remain; removing the menu counter feed does not remove camera or ownership validation. Walking bob amplitudes are doubled and its phase advance per distance travelled is halved; aim, sprint stance and turn sway coefficients are unchanged.

Visibility uses the supported SDK contexts default and shadow_caster rather than the omitted-context all-pass mask. Live binding bytes and context hashes establish default=1 and shadow=2 at mesh+DC. The desired hidden-piece mask clears bit1 and sets bit2, retaining every unrelated pass. Each changed bit has its own captured baseline and ownership check; complete native visibility on exit supersedes the old lease. The main body receives only a shadow contribution. Native request/ADS epochs permit a bounded reassertion after a proven visibility reset, at most once per bit/mesh/epoch within250ms. Unchanged frames make no SDK visibility calls.

World customization slots0/2/3/8/9 cover head, torso, hips and shoulders. For the observed native rig resourceD0CF4D493CA08BED, SDK mesh names g_l_shoulderpad/44E19D12 and g_r_shoulderpad/CB0E1712, nodes57/58 and the singleton m_armor_standard material identify the two separate shoulder pads. Mesh ordinal alone never grants permission. Current resource, registry generation, parent/world, layout/mesh mapping and kept arm/leg aliases are verified before mutation; appearance/layout changes invalidate discovery. The rig's g_undergarment contains sleeves and wrists as well as chest cloth, so no chest-only rig removal is claimed. The shoulder/shadow policy requires visual verification across armor changes and action transitions.

The SDK exposes no visibility-write ownership token. After a throwing partial cleanup, an identical native FF publication can be indistinguishable from our own intermediate FF restoration. Ordinary native exits and exact partial-restore retries are covered by fixtures; that overlapping failure case remains a limitation.


## 0.1.28 per-weapon placement
Profiles use the validated weapon Unit resource bytes at +0x358, not transient entity IDs. The existing pose-acquisition path resolves the profile once. No new timer, world scan, or steady-state native read is added. Editor sessions bind to the weapon resource and lease identity; save verifies a fresh ownership snapshot, and weapon changes cancel the draft. Legacy placement remains the fallback. Native binaries remain unchanged from 0.1.27. Hips visibility restoration from the previous investigation is retained; shoulder experiments are shelved.


## 0.1.29 shared placement option
Save all atomically replaces weapon_placements with one __all fallback; individual saves preserve that fallback. Existing legacy placement remains readable. No native changes or new runtime callbacks.


## 0.1.30 action placement
Pure action_placement policy resolves per-weapon then shared action profiles and legacy idle fallback. Save-all clears overrides only for its selected action in one config write. Motion runtime reuses its existing action sample, caches action/profile/lease identity, blends placement targets, and stops native placement calls at exact settled endpoints. ADS placement is a new guarded export on the existing helper; all pointer, lifecycle, graph, generation and finite checks are unchanged. Default zero preserves stock sight pose and zoom. No new dispatch installation sites or timers. Crouch/prone/slide/dive require a labelled resource-specific mapping; unmatched resources and states use idle. Editor previews only placement and never changes character action flags.


## 0.1.31 labelled stance selection
Evidence: dist/research/action-mapping-0.1.30/trace.csv, 331 samples over36.1s. Resource4D1C334D294DFA97, verified31-layer graph. Crouch L1=15/16 L3=4 with byte10 posture20; slide shares16/4 but byte11 bit02 is present. Prone enters47/60 and settles48/56 with posture40. Dive45/37→45/56→48/56 adds byte13 bit20, then settles prone after clearing. Pose transitions such as70/64 remain unmatched idle. Guards require verified resource, exact24-byte copied flags, posture plus compatible animation pair. No additional reader/timer/native calls. Native helper remains0.1.30.


## 0.1.32 authored yaw/pitch
Optional finite yaw/pitch fields in degrees persist with each action/weapon profile; older XYZ remains valid. MCM-owned input.down(2) captures right drag without changing MCM or acquiring a second helper. Editor rotation previews reuse existing validated sampler/basis conversion and the coalesced motion submission; positional drafts still use their existing path. Action changes interpolate angles with placement; composed output retains the35degree quaternion clamp. Explicit NADSE_SetAuthoredTransform extends the existing atomic transform setter with an authored-ADS flag. Ordinary SetTransform clears that flag and retains native full-ADS passthrough. No new hook site or timer. Ownership, sole request, zero sight coupling, generation, graph and quaternion guards remain unchanged.


## 0.1.33 rotation range / sprint
All editor, saved-profile, controller, backend, adapter, basis-conversion and native quaternion limits consistently accept90degree yaw/pitch and120degree combined rotation. Finite/unit/generation/ownership/coupling guards remain. Removed procedural sprint -.025X/-.035Z and -20pitch/+15yaw; state detection and bob suppression remain. Native editor helper uses a new immutable0.1.33 filename.


## 0.1.34 FirdPerson dev prototype
Read-only live inventory: TPV107 nodes / FPS63. Hash-verified semantic l_shoulder03752C98 maps FPS10→TPV44 under TPV l_clavicle42; r_shoulder1620B2CE maps FPS30→TPV67 under r_clavicle65 (native zero-based indices). Supported SDK uses one-based indices. Capture copies each FPS shoulder world point into current camera-local space. Runtime transforms these targets through the current head-mounted normal camera into each TPV clavicle parent space, changing only shoulder local positions. Native rotations, graph parentage, attachment indices, skin weights, fingers and weapon are never rewritten. Only two joints animate; unchanged positions coalesce. One bounded World.units inventory at explicit capture, no repeated world scans or new native hook sites.

Generation/selfref/world/player checks precede writes. Semantic hash/parent/pointer checks precede writes and restoration. Native animation updates refresh the exact rollback baseline; foreign current positions are never overwritten during cleanup. ADS/actions/foreign camera restore owned shoulder positions. Cleanup independently drains camera/head/movement/DoF owners and retains pending state on failure. FirdPerson is explicit and does not auto-enable.


0.1.35 FirdPerson coordinate-frame fix: capture shoulder positions relative to the hash-verified FPS camera bone51 (native50), not the camera Unit world transform. Playback uses the verified TPV head bone91 plus the existing head-camera forward/up offsets and current controller basis. This removes dependence on stale TPV camera-orbit matrices. The2m guard and exact restoration remain.


## 0.1.36 FirdPerson shared editor
A dynamic editor controller routes only placement operations to the enabled rig; FirdPerson never starts the FPS controller to edit. Weapon snapshot identity resolves the stable weapon resource once per change. Action settings re-resolve only on action/key/revision changes, and position/angles blend to settled endpoints. Editor drafts preview directly, cancel without writing settings, and bind to exact weapon identity. Shared config writes are unchanged. Calibrated pose/reference positions prevent double application. Two TPV shoulder rotations receive camera-to-parent authored quaternion deltas over fresh native animation rotations, with copied exact owned-baseline rollback. Full native ADS remains an explicit native-camera handoff. No new timers/world scans/native hook sites.


## 0.1.37 body-to-render pose propagation
Single-frame SDK trace (dist/research/fird-person/body-to-arm-publish-trace.txt): local shoulder +.1X changes neither world pose immediately. World.update_unit(body) changes body shoulder world pose, while attached arm remains stale. World.update_unit(arm) brings the externally mapped arm shoulder to exactly the new body pose. The held weapon root has an external body-bone84 mapping and owned body parent. Fix publishes body first, then current attached render arms and weapon after each changed batch, also on restoration.

Head visibility exposes its immutable already-read120byte appearance signature; FirdPerson reuses this instead of adding another appearance poll. One World.units inventory on signature/weapon invalidation only. Each cached render handle retains generation/object/selfref/parent/world checks. Weapon snapshot reused within current backend frame only. No bone-mode changes, extra timer or native hooks. Scene-graph propagation evidence is stronger than setter readback but visible arms/weapon still require acceptance.


## 0.1.38 linked render skeleton placement

Supersedes the failed 0.1.34–0.1.37 body shoulder writes. FirdPerson no longer writes or republishes the animated body. Native mesh skin bindings (mesh+0x80, map offset at binding+8) select child render-graph nodes. FK links are followed to unique external roots; external parent indices retain their existing body animation sources. Each root receives the authored world displacement/rotation converted into its current parent frame. Internal FK descendants and the weapon animation blender remain untouched.

Read-only native tracing identified palette construction at RVA 0x512B80 and its matrix builder at 0x5B2990. The constructor converts mapped bone transforms and inverse bind/mesh matrices into current/previous palettes. This is static native evidence, not a live GPU-buffer capture. Controlled rendered TPV comparisons establish that the selected linked nodes affect visible arms and the rifle. No new executable writes, hooks or native call sites were added.

Discovery validates graph ownership, generations, external parent storage, skin binding limits and semantic links once per appearance/weapon identity change. Apply/restore retain per-row link/hash and local-writer checks. Restore only touches still-owned values. Shared body-parent matrices are computed once per frame; unchanged local transforms avoid setters and renderer publication. These animated memory-backed poses have no available lifecycle event for every animation sample, so bounded application remains in the existing active update callback; no new timer or periodic world inventory is added. Inactive mode is idle.

Stationary ship trial: 73 unique mapped roots including rifle; 700 frames with a 45-degree rotation plus 0.8 m lift. Maximum world-space readback error was 9.8 micrometers, 18,023 parent-rotation changes were observed, and cleanup succeeded. Exclusive placement CPU mean 0.446 ms, p99 1.020 ms, maximum 1.754 ms. Discovery bridge batch took 4 ms (includes preparation/inventory). These measurements are for the bounded ordinary-TPV adapter trial, not total FirdPerson cost or an FPS benchmark. Captures and logs are local research artifacts excluded from the package. Full FirdPerson editor/gameplay acceptance remains separate.


0.1.39 guards the native FPS-to-TPV weapon reattachment window. A weapon still attached to the captured, generation-verified FPS rig waits up to 0.5 seconds in the existing active callback; attachment inventory and setters stay idle while pending. Any other foreign parent still refuses immediately. Normal reattachment resumes cached render placement; timeout stops and cleans up. Synthetic tests cover wait/resume and timeout. Full transition acceptance remains pending.

0.1.40 extends the guarded handoff to arm renderers. Bounded live trace 16214 confirms both slot6/7 renderers remain parented to the captured FPS Unit on the frame camera kind changes6→4, then reparent to the owned body on the next frame. The previous weapon-only wait was incomplete. All render attachments may now wait only on that exact generation-verified FPS parent; foreign parents still refuse.


0.1.41 applies the same averaged shoulder-center rigid transform to left, right and weapon renderers. Independent shoulder translations were changing the native grip relationship. Native ADS/foreign-camera handoffs now release the cached skin mapping/baselines; the TPV return discovers fresh attachment state once. Successful stop clears the adapter, and render validity closures capture their immutable body context rather than a nullable manager calibration. Top-level stop/shutdown drain ordinary FPV cleanup even if Fird cleanup fails. These fixes address observed native-writer stops and a repeated-stop nil-calibration exception. Visual grip acceptance remains pending; a temporary live shared-transform comparison improved alignment but was lost when native ADS rebuilt the rig.


## 0.1.42 left support-hand presentation constraint

The shared rigid transform preserved the right-hand grip but retained the TPV left wrist's different native weapon-relative position. Capture now saves the native FPS wrist14 relative to weapon attachment9, both guarded by semantic hashes (5C0C68D3 and4FDD3337). The TPV equivalents are48 and85. During a matching held-weapon action, only the left render group's target receives the authored-rotation-adjusted wrist-to-grip delta. The body animation, finger channels, right transform and weapon transform are untouched. A 0.5m error bound disables correction rather than moving an unsupported pose.

Labelled live key/state trace16236 correlated R edges at15.55s/20.77s with body animation layer11 states763/764, returning to585; firing used622. For the verified weapon-layer235/hold585 signature,622 retains support; reload and unknown states yield with25ms decay and70ms return blend. Layer10/11 are added to the existing snapshot sampler only during FirdPerson. There is no new update timer, input injection or recurring unit inventory. Native ADS refreshes a per-weapon reference once after three active frames; a newly encountered weapon without a reference receives no correction until native FPS capture. Snapshot resource, weapon-layer and hold-state signatures guard references. No state meaning is generalized to another graph.

Synthetic tests verify animated wrist movement maps to a stable grip under authored rotation, firing retains the constraint, reload returns exactly to the original common transform, and other resources/weapons/bounds cannot reuse a correction. Full visible validation and deployed overhead are pending. Temporary trial16238 safely made no changes because the equipped weapon had changed and had no matching captured reference.


0.1.43: Shift+F8 edits the FirdPerson head camera (left-drag side/height; wheel depth), saved separately from weapon/action placements. The default camera is 18 cm farther back. Reset all clears the corresponding camera or weapon placements. Built-in normal-aim translation is disabled by default; authored aim presets and native full ADS remain active. Camera offsets update only on edits, with native ownership and generation checks.


0.1.44 free-aim experiment: enable native FPV, then choose DEV: Free aim (30 seconds). The camera holds a 5-degree horizontal / 3-degree vertical dead zone, tightened over 120 ms to 22 percent during normal aim. Full native ADS bypasses it immediately and rebases on release. FirdPerson is shelved and refuses entry. F11 stops FPV and the test. No weapon, muzzle, firing direction, aim target or projectile transforms are written.

The existing camera-position callback validates the captured adjacent camera-rotation call and changes only its current-thread stack quaternion scratch at position+64. The camera's current local 3x3 and world matrix recover its animated parent before the world-space dead-zone result is converted back to local space. No additional callback, executable patch, input capture, timer or frame-loop Lua diagnostic is introduced. Generation ownership and native ADS are checked in the existing callback; unsupported matrices or stack layout pass through. Optional timing stops with the 30-second test. Barrel/impact alignment and handling remain gameplay checks, separate from synthetic fixtures.


0.1.45 replaces the inferred parent (cached camera world times inverse local) with the current generation-owned FPS rig camera bone50 world pose, checked against hash60ED8C39/link40001 and the external pose binding. A deliberately stale-camera regression fixture covers the former frame-stage assumption. An explicit 3-second read-only observation compares both parent estimates; it does not enable free aim, does no camera writes and expires independently. Live acceptance is pending.


0.1.46: posture presets use verified native crouch/prone/dive/slide flags rather than exact locomotion blend indices. Sprint additionally accepts labelled bridge L1=75/78,L3=68 only with the verified bridge lifecycle; the existing L3=71 path remains. Camera kick uses rising edges of the native flag102 shot pulse observed during labelled single/burst firing. It adds 0.35 degrees upward per pulse, caps at 1 degree, and recovers with a 75 ms decay after the free-aim zone. Full ADS bypasses added kick; native gun/projectile transforms are unchanged. The kick is idle at rest and does no continuous timing or transform sampling after settling. Disable via camera_kick_enabled=false in the mod configuration. Weapon coverage and dry-fire behavior remain unverified.


0.1.47 candidate: F8 middle-drag adds roll (Shift for fine adjustment), persisted per weapon/action. MCM > Bob and sway exposes independent weapon/camera strength and speed plus sprint movement. Settings are cached until an MCM change event; unchanged camera motion coalesces without native updates. Sprint defaults now add a lowered/canted pose and stronger gait motion; user presets remain the base.

Camera continuity records the displayed native-FPV world pose and blends a 6/4 handoff, ADS release or weapon request change over 150 ms. The correction decays against the current target so settled mouse look has no added smoothing delay. Full ADS retains original arguments; player-generation loss and jumps over 2 metres invalidate continuity. Camera motion is bounded to 3 cm / 0.03 radians. A 400-callback profiling command is explicit and stops automatically. Native and Lua fixtures are separate from pending live transition/performance acceptance. TPV support-hand pose retargeting is not included yet.
