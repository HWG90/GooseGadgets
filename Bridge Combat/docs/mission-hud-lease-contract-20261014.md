# Independent Mission HUD lease: source review, October 14

The Bridge Combat source still has no active HUD route. `core.cpp` does not call
`hud::prepare/start/tick/stop`, and `tools/build_native.py` builds core, mode and
actor only. The seven-hook selector projection in `native/hud.cpp` remains
dormant. The correction below does not enable it or supply a runtime candidate.

## Corrected empty GUI-stack preflight

The saved normal mission baseline
`DBF/dist/bridge-combat-continue-20261013/baselines/mission-hud-actor-634-ref-12585381-20261013-225118-deployed-continue.txt`
records `guiContextDepth=4294967295`, the signed empty depth `-1`. Its old
`guiContextBoundsKnown=false` diagnostic was based on an incomplete range; it
does not establish an invalid native stack.

The audited common UI constructor sign-extends the old depth at `0x12F0974`,
increments/stores the depth at `0x12F097B/7E`, and writes context 5 at
`GUI+0x2C5B9+oldDepth` at `0x12F0985`. Its native pop at `0x12F13D8` decrements
the depth. The scope surrounding the Ship/Mission initializer calls pops at
`0x12F0C50`; `0x12F13D8` closes a later construction scope.

| Old signed depth | New depth | Written slot | Result |
| --- | --- | --- | --- |
| -1 | 0 | GUI+0x2C5B8 | Valid empty-stack push |
| 0 | 1 | GUI+0x2C5B9 | Valid |
| 1 | 2 | GUI+0x2C5BA | Valid |
| 2 | 3 | GUI+0x2C5BB | Valid last slot |
| 3 | 4 | GUI+0x2C5BC | Overlaps the depth DWORD; refuse |

The dormant preflight now accepts `-1..2` and refuses values below `-1` or above
`2` before any native teardown, context update, or selector write. The original
common UI constructor already owns its construction scope; wrapping that legacy
call in another context push would double-push it.

`tests/native_hud_tests.cpp` now starts with depth `-1`, models the audited native
context-5 push/pop in its constructor stub, checks `-1/0/1/2` acceptance without
side effects, and checks `-2/3` refusal with an unchanged depth. Its lifecycle
test verifies that the native constructor selected slot 0 and returned to depth
`-1`, then runs full start/stop construction at depths `0/1/2` to check the last
slot adjacent to the depth DWORD. The isolated MSVC `/W4` fixture passed. Its EXE, build log and result are in
`DBF/dist/releases/bridge-combat-source-hud-contract-20261014`; no DLL was built,
installed or loaded.

## Bounded direct route to implement after lifecycle closure

The proposed lease independently replaces the ship HUD presentation on the
existing common UI roots. It does not require common UI selector patching. The
normal direct entrypoints were checked against
`C:\Users\david\AppData\Local\LinksLinkToMemory\ship-input-gate-ui-native-contracts.json`,
the matching `ship-input-gate-ui-<RVA>.asm.txt` captures, and the normal callers
in the captured common UI constructor/ticks:

| Operation | game.dll RVA | Object/known argument |
| --- | --- | --- |
| Ship HUD destroy | 0x137D500 | UI+0x46D900 |
| Mission HUD initialize | 0x12E96D0 | M=UI+0x24E340; roots UI+0x820, UI+0x930, UI+0xB50 |
| Mission HUD active | 0x12EB1B0 | M and active boolean |
| Mission HUD visibility | 0x12EB670 | M, float dt in XMM1, bool allowed in R8B |
| Mission HUD data | 0x12EBC50 | M, float dt in XMM1, uint32 PlayerManager entity ID in R8D |
| Mission HUD resize | 0x12EC800 | M, float scaleX in XMM1, float scaleY in XMM2 |
| Mission HUD teardown | 0x12EA5B0 | M |
| Ship HUD initialize | 0x137C9B0 | S=UI+0x46D900; roots UI+0x820, UI+0x930, UI+0xA40 |
| Ship HUD resize | 0x137EC60 | S, float scale in XMM1 |

The recorded direct functions return void. Their x64 call shapes are
`void(void*,void*,void*,void*)` for both initializers; `void(void*,bool)` for
Mission active; `void(void*,float,bool)` for visibility;
`void(void*,float,uint32_t)` for data; `void(void*,float,float)` for Mission
resize; `void(void*,float)` for Ship resize; and `void(void*)` for teardown.
The common constructor passes all four ordinary Mission initializer arguments
even though the initializer overwrites incoming R8. The normal UI tick passes
Mission resize values from UI+0x24E324/+0x24E328 and Ship scale from UI+0x24E324.

The matching bridge baseline
`C:\Users\david\AppData\Local\LinksLinkToMemory\bridge-hud-actor-4194537-ref-20974700-20261013-230526-returned-continue.txt`
has scene 3, one live PlayerManager row at physical row 0, role 3 off, Ship HUD
initialized, Mission HUD inactive/uninitialized, and signed GUI depth `-1`.
This establishes that the proposed initial gate matches that capture. It does
not prove the same gate will remain valid during transitions.

The only interception needed for the proposed route is two synchronous entry
hooks: common UI destroy `0x12F1540` and common UI initialize `0x12F0920`. When
either is about to operate on the leased UI, retire the independently owned
Mission HUD at `0x12EA5B0` first, then forward the game's original lifecycle
call. This ordering prevents Mission HUD observers or views from surviving
destruction/replacement of their common UI roots. It must be verified in the
entry hooks; a later Lua/update poll cannot guarantee the ordering. Foreign UI
objects pass through immediately. Both hooks are staged disabled until the
whole lease's preparation succeeds. That dormant staging is a requirement for
the future direct route, not a claim that current core enables HUD hooks.

Start must finish all read-only checks before Ship HUD teardown:

1. Match the supported module build and exact function fingerprints, current
   common UI identity, owning game thread, live local descriptor and local
   PlayerControl. Require the existing initialized ship presentation and no
   initialized Mission HUD.
2. Require the local PlayerManager to have exactly one live physical row and
   for the owning local descriptor to be row 0. Resolve its PlayerManager entity
   ID separately from the avatar ID. Capture the owner's role mask with role 3
   initially off. Recheck those identities before every context-changing call.
3. Check the existing common UI root parents, required client services, all
   four observer-list capacities, and a GUI depth in `-1..2`. Require the next
   context slot and the depth DWORD to be readable and writable.
4. Journal Ship HUD active state, successful Ship HUD teardown, the independent
   Mission HUD constructor return and readback, activation, owned role-3 change,
   and all pending restoration. A failed readback after a returned native call
   remains a returned phase and is retried without replaying that native call.

After the ship-only teardown, the independent constructor must run in one
short-lived GUI context-5 scope. Snapshot the old signed depth and next slot;
use `newDepth=oldDepth+1`, with slot address `GUI+0x2C5B8+newDepth`. Verify both
writes and restore the owned scope before returning, including failed
constructor/readback paths. The ordinary initializer is called inside the
context-5 scope that ends at `0x12F0C50`. Do not retain that context across frames
or alter
common UI root initialization flags to emulate a full game-mode constructor.
The partial-construction cleanup contract still needs to be recorded before a
runtime route is added.

Require Mission HUD inactive (`active(M,false)`) during startup and initial
population. The initializer sets the initialized flag and visibility fields but
does not set active+0x58. The active API compares +0x58 with the requested boolean
and returns without a context call if they match; a change adds/removes mask 8
globally through `0xAA0D60/0xAA0E50`. Inactive startup therefore must be performed
under the sole-local-row and initial-role-off gates rather than assuming an old
active byte is clear. Only an acknowledged initialized presentation may then
activate.
Native active/teardown calls can change role 3 through global context helpers;
the lease must journal and restore only the role-3 state it acquired for the
verified sole local PlayerManager row. Do not install the legacy global-remove
hook or substitute its local context behavior into the independent design.
The initialized Mission destructor clears initialized+0x21F5B0, removes mask 8
globally at `0x12EACB0`, and then unsubscribes its observer pointer at
`0x12EACB8`. These effects occur even when the active byte was already false.

Tick/resize should call the direct Mission HUD functions from the owning game
thread with their normal caller arguments. The data call must receive the
PlayerManager entity ID. It must not fabricate wrapper render arguments, patch
scene selectors, or route through the legacy common UI frame hook. A change in
UI, actor, thread or sole-player identity retires the lease according to its
proved teardown contract.

On a game-owned UI lifecycle transition, teardown acknowledges Mission HUD
retirement before forwarding the original common UI call; the game then owns
construction of the next presentation. On an explicit Bridge Combat stop while
the same ship UI remains, teardown must restore the ship-only presentation and
the journaled role state without rebuilding the common roots. Hook removal is
allowed only after those restorations have acknowledged completion.

## Blocking evidence before integration

The direct entrypoint ABIs above are recorded. The remaining lifecycle evidence
needed for a reviewable runtime implementation is:

- A partial-construction/returned-call journal with acknowledged widget,
  observer and initialized-state postconditions for both direct initializers
  and teardown. A void return plus the initialized byte alone does not prove
  recoverable cleanup of a constructor interrupted before it set that byte.
- The synchronous teardown rule when the PlayerManager ceases to be the sole
  local row. A global role removal must not change another player's state.
  Required local restoration or transition ordering must be proved; a saved
  single-player baseline alone cannot establish that lifecycle contract.
- How the two hook originals are staged, enabled and retired in the currently
  held core lifecycle, including safe handling if owned Mission HUD cleanup is
  pending before common-root destruction. The legacy seven-hook preparation is
  not an acceptable fallback.

The already known first-24-byte fingerprints are recorded in the Toolkit JSON;
they must be preserved in any implementation's ABI guards.

Until those contracts are closed, the bounded work consists of the signed-depth
fix, isolated fixture and this integration plan. None proves renderer behavior,
health/damage initialization, a live Mission HUD on the bridge, or deployment.
