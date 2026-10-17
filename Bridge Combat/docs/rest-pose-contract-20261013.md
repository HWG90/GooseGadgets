# Authored rest pose and native layer findings

Status: offline source/evidence review, October 13, 2026. No animation test,
native call, deployment, or installed-file change was performed for this review.
Bridge Combat remains unfinished. These findings belong to Bridge Combat and
are not release inputs for GooseGadgets.

## Actual rest-pose source

The maintained Photo Mode decoder provides authored local transforms for the
same avatar resource `4D1C334D294DFA97`. Disabling animation by itself preserves
the last sampled pose; it does not establish a T/A pose. Applying the resource's
rest transforms is a concrete route to the authored rest pose. Its visual shape
has not been tested here, so do not promise a particular T versus A silhouette.

Source: `DBF_PhotoMode/tools/subject_pose_decoder.lua`, `rig()` at lines 186–235.
It reads the unit scene-graph offset at byte 52, bounds the node count, decodes
each local rotation/position/scale, validates parent indices and the named-bone
mapping, and exposes `nodes[i].rest`. The decoded rig has 107 scene nodes and
90 named bones. `tools/build_subject_pose_frames.py` already consumes these
matrices and decomposes them through `Clip.pose()`.

Verified cache directory:
`C:/Users/david/OneDrive/Documents/GitHub/DBF_PhotoMode/dist/review/all-emotes-096/cache`.

| Resource | Bytes | SHA-256 |
| --- | ---: | --- |
| `4d1c334d294dfa97.e0a48d0be9a7453f.bin` (unit) | 21504 | `cb7273778c6b5d8771376c75b5fb021eda233062eca5773a539adfdf21de67bd` |
| `4d1c334d294dfa97.18dead01056b72e9.bin` (bones) | 1484 | `36441822f5420de9a38683b95438a80f9e47fc78b7a8245f156e91e9ae716081` |

These files were verified offline. Matching a live actor still requires resource,
node-count, parent, and named-bone validation. Do not redistribute extracted
game resource files with a mod; a source-only extractor can consume the user's
matching local resources.

## Existing normal API application contract

`Toolkit/scripts/photo_paused_pose_install.lua`, adapter lines 284–339, supplies
an existing ownership-checked pose adapter. The SDK node-count name is
`Unit.num_scene_graph_items`, not `num_nodes`. Required APIs are:

- `Unit.num_scene_graph_items`, `scene_graph_parent`, `has_node`, `node`.
- `Unit.local_pose`, `set_local_pose`, `animation_bone_mode`,
  `set_animation_bone_mode`.
- `Matrix4x4Box`, `Matrix4x4.from_quaternion_position`,
  `Quaternion.axis_angle`, and `World.update_unit`.

The adapter validates all 107 parent relationships and named-bone indices,
captures original local matrices and bone mode, then sets bone mode `ignore`,
applies local matrices to nodes 9–92, and calls `World.update_unit`. It preserves
nodes 1–8 (placement/root/boss), collision nodes and unnamed gameplay anchors.
Restore applies the captured matrices and original bone mode only to the same
owned unit. Use authored `node.rest` for a rest-pose candidate, not an emote frame
or another actor's live matrices.

This pose override does not initialize mission HUD, health, Dispatches, player
actions, or the mission lifecycle. The existing adapter also requires a paused
local subject; adapting it to a different lifecycle requires its own ownership
and update contract.

Current saved SDK bodies in Toolkit: `bridge-bind-api-*.hex` for
`set_local_pose` (`EXE+406960`), `local_pose` (`406220`),
`disable_animation_state_machine` (`40D720`), and `stop_simple_animation`
(`40C270`). SDK `initial_local_pose`, `initial_local_position`,
`initial_local_rotation`, and `num_nodes` were absent in the queried table.
Disable queues World command `0x11`; its command-consumer completion must be
acknowledged before claiming the graph was removed. Bone mode `ignore` prevents
animation transfer while the graph can remain allocated.

## Toolkit player helpers

`Toolkit/scripts/hd2_addresses.lua` supplies build validation, active-avatar
resolution (`H.avatar`), `transform`, `facing`, `type_of`, and an `in_mission`
predicate. It is not a PlayerControl or mission initializer.
`scripts/hd2_actions.lua` is a read-only action watcher: ability-manager entity
map at `+24`, rows pointer `+56`, stride 224, action id `+0`, progress float `+8`,
active DWORD `+16`. The inspected helper set contains no general player-state
reset or complete mission-initialization wrapper.

## Partial-layer and shared-curve contract

The captured body graph has 31 layers. Current ship SDK layers 4/21/22 are
76/1/1; their declared defaults are 67/10/6, matching the historical mission
capture. The supported partial setter `EXE+554440` skips `-1` entries and applies
selected native layer indices in ascending order through normal `54B490` entry
and `54ADB0` exit handling. A candidate array has 22 entries with SDK4=67,
SDK21=10, SDK22=6 and all others `-1`; it has not been executed in this review.

Old layers 21 and 22 both override curve index 4 with float 0; both defaults have
no curve overrides. Exit resolves the highest remaining layer's override, or
native fallback target 0/owner 0. It does not restore a saved scalar in LIFO
order. Ascending 4→21→22 activation and restore match the native partial setter.
Do not require curve target 1 as a cleanup acknowledgement.

Per-layer override records: `ptr(Animator+1B8)`, count `u32(Animator+1B0)==31`,
stride `0x18`, `{count+0, cap+4, ptr+8, allocator+10}`. Property rows:
`ptr(Blender+380) + curveIndex*0x58`; relevant fields are target float `+38`,
flag `+40`, exit blend time `+44`, owner native-layer index `+48`. A declared
property-buffer count field is unproved. Stable pointer/readable-row checks are
accessibility and identity checks, not a fabricated array bound.

Animation clips in state definitions are `u32 count+C`, `u32 relativeOffset+10`,
then 8-byte hashes; `+50/+54` are not clip-array fields. Targets 21/22 require
eight resident clips of type `931E336D7646CC26`. Layer4 state67 additionally
requires its registration14 active-node guard. The exact loaded-resource query
`EXE+5F34E0` is a read-only resolver returning the matching resource data pointer
or zero; `Application.has_data` instead concerns script data. Resource-query
and ownership guards are documented by the separate resource audit.

Saved evidence: `ship-native-layer-cleanup.hex`, `ship-native-layer-switch.hex`,
`bridge-layer-{21,22}-state-*-{transitions,extra}.hex`, and
`ship-input-gate-animation-state-contract.md` in Toolkit. No single normal event
has been proved to reset all three layers together. Existing one-layer tests
and same-primary weapon rebind did not establish the intended body-arm pose.

## Prepared reversible candidate

`tools/live_rest_pose.lua` now supplies `new(authoredData, injectedIO optional)`,
`capture()`, `apply(snapshot)`, `restore()`, and `status()`. Import and constructor
perform no game access. It uses the normal SDK bone-mode/local-pose APIs and
never calls an animation state setter, graph constructor/destructor, inventory
selector, or resource-package API. It does not pause the game or change MCM.
The caller must arrange sole pose ownership (including no active Photo Mode
pose writer) and retain the object until restoration succeeds.

Default capture requires the exact game/EXE stamps, Scene3, current local actor,
player/world/descriptor/Unit-generation continuity, and stable body Blender,
Animator and graph. It obtains an actual SDK Unit handle through `World.units`,
validates all 107 parents/named bones, and checks the bone-component getter and
bone-mode SDK binding addresses. Matrix construction must round-trip to the
same 12 affine float components. `Matrix4x4.from_elements` is required; numeric
extraction accepts `to_elements` or the existing right/forward/up/translation
and Vector3.x/y/z APIs. Absent methods refuse capture before mutation.
These matrix APIs are documented in the
[official Stingray reference](https://help.autodesk.com/cloudhelp/2019/ENU/Max-Interactive-Help/lua_ref/obj_stingray_Matrix4x4.html);
their availability in the running SDK is checked by the candidate.

The object snapshots exact boxed local matrices for nodes 9–92 and the original
bone mode, journals each attempt before calling a setter, verifies the resulting
float image, and reads back the complete changed set. Cleanup accepts only its
original or target node images and original or owned `ignore` mode. It validates
the entire attempted set before restoring any node. Exceptions, unknown reads,
foreign changes, or actor/world replacement retain cleanup; a new activation is
refused while that journal exists. The candidate never sets nodes 1–8 or 93–107,
nor any weapon Unit's pose. Attached equipment still inherits normal skeleton
transforms through `World.update_unit`.

`tools/build_rest_pose.py` extends the pinned decoder's lexical scope to export
`node.rest` directly; it does not duplicate the binary decoder. Default output:
`DBF/dist/releases/bridge-rest-pose-review/authored_rest_pose.lua`, SHA-256
`b6a68ce8989e85772b441988e47329a53a107177a80ab890fbe3334da87223bb`.
The adjacent JSON records input/source provenance. No extracted binary resource
files are copied to the review output or runtime package.

Offline checks:

```powershell
py -3 bridge-combat/tools/build_rest_pose.py
py -3 bridge-combat/tests/run_controller.py --lua bridge-combat/tests/rest_pose_fixture.lua
```

The 20 focused fake-SDK contracts passed, including exact apply/restore,
preserved placement/collision nodes, API/rig/roundtrip refusal, stale capture,
actor/world replacement, partial setter and restore exceptions, foreign node
and mode changes, update/readback failure, and the actual generated data.
This is an offline-ready candidate. No live test or installation was performed.

### Current matrix binding and Unit-token audit

Parent's read-only batch497 captured the current EXE wrappers in
`Toolkit/bridge-matrix-from_elements.hex` and `bridge-matrix-to_elements.hex`.
The SDK constructor is `EXE+44ACC0`; it reads numeric Lua arguments 1 through
12, with `MOV EDX,0xC` at `44AE01`. The getter is `EXE+44B480`; it emits xyz from
four affine rows, omits homogeneous components, and returns 12 (`MOV EAX,0xC`
at `44B5B7`, return at `44B5D2`). This agrees with the official 12-component
API. The 16 storage floats of a homogeneous matrix must not be confused with
the constructor's 12 arguments. Generated authored data remains unchanged.

Default capture now validates both current C-wrapper addresses, their first
24 bytes, and these input/output arity sites before any matrix construction or
extraction call. The source fingerprints are checked against the saved captures
offline. Batch499 supplied `bridge-matrix-from_elements-tail.hex` at `44AE30`;
its overlapping bytes match the first capture. The constructor fills xyz of
four rows from those 12 inputs, stores homogeneous column 0/0/0/1 internally
(`44AE87`, `44AE9C`, `44AEB1`, `44AEC7`), and sets return count 1 at `44AEE6`.
Default preflight also fingerprints the zero source and all four homogeneous
stores. No 16-argument constructor call or data expansion is needed. No Unit
mutation is authorized by type presence.

SDK Unit arguments are actual `World.units` handles. Saved `local_pose` code at
`EXE+40627E` executes `SHR EBX,2`; the maintained adapter similarly decodes
`floor(uintptr(handle)/4)`. The prototype now discards both tag bits instead of
using unrounded division. The added contract verifies all four tags preserve
the current body reference `1040202639`. The World handle path follows the
maintained adapter: read the native pointer at `uintptr(Application.main_world())`
and require equality with the registered Unit's `+18` World pointer. No Unit or
World handle is fabricated from an integer reference.

### Engine temporary-object scopes

Toolkit `AGENTS.md` lines 143–144 documents the fixed temporary ring and the
current `Script.temp_count()` / `Script.set_temp_count(n)` one-integer contract.
The candidate now requires both APIs before the first matrix call. Each node's
capture/construction, each key extraction, and each setter/readback runs inside
a bounded scope. The scope restores and verifies the saved counter after success
or a Lua error. It returns only durable Matrix4x4Box records or copied binary
float keys; no temporary matrix/vector escapes the scope.

The fixture models invalidated/reused temporary slots, rejects dangling matrix
consumption, and checks that every existing failure case restores the counter.
It also verifies API refusal before allocation, bounded per-node capture (four
temporary matrices with the current `to_elements` path), cleanup after extraction
errors, and exact boxed snapshot reuse after a new frame/caller resets the ring.
All 20 contracts passed. Generated authored data and its input hashes are unchanged.

Batch503's live preflight refused before mutation because the SDK exposes
`Matrix4x4Box` as a callable table, rather than a function. The candidate now
accepts either a function or a table whose accessible metatable has a function
`__call`, matching the measured SDK and maintained Photo Mode constructor use.
The focused callable-table fixture verifies all 168 captured boxes and exact
apply/restore under the same temporary-lifetime checks. This correction does not
change matrix arity, pose ownership, or the temporary-counter contract.
