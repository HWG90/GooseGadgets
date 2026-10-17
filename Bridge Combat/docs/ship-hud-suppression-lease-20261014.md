# Independent Ship HUD suppression lease: source review, October 14

`native/ship_hud.cpp` and `.h` implement a separate native Ship HUD lease. It is
not connected to Core, MCM or the normal native build. Validation below uses an
isolated fixture EXE. A standalone DLL review build is a separate candidate;
building it does not establish loaded bytes or in-game UI behavior. This source
and fixture work changed no installed file.

The lease uses the ordinary Ship HUD object lifecycle to suppress native ship
prompt/input/data routes. The normal outer UI tick may still change the Ship
active byte, but Ship ticks independently require initialized+0x89778. An
acknowledged native Ship destructor leaves that initialized flag zero. This
does not establish a way to close an already open Dispatches modal, which has a
separate menu owner; the source calls no popup or modal API.

## Exact scope and direct contracts

| Operation | game.dll RVA | Ordinary x64 call |
| --- | --- | --- |
| Ship destroy | 0x137D500 | void(UI+0x46D900) |
| Ship initialize | 0x137C9B0 | void(UI+0x46D900, UI+0x820, UI+0x930, UI+0xA40) |
| Ship resize | 0x137EC60 | void(UI+0x46D900, float scale in XMM1) |
| Pre-common-UI initialize hook | 0x12F0920 | void(UI) |
| Pre-common-UI destroy hook | 0x12F1540 | void(UI) |

Direct Ship fingerprints and signatures come from Toolkit
`ship-input-gate-ui-native-contracts.json` and the matching ASM captures in
`C:\Users\david\AppData\Local\LinksLinkToMemory`. The two hook fingerprints also
match the current module read recorded in
`bridge-common-ui-hook-fingerprints-20261014.txt`. Every address must match its
embedded bytes on the supported PE timestamp `0x6AB3B43F` before hooks are staged.

Preparation validates the current global UI pointer, owning thread, initialized
common UI and Ship HUD, the three common-root parent links, the ordinary resize
scale at UI+0x24E324, and the GUI construction scope. It also requires the three
direct main Ship registrations to belong exclusively to this Ship HUD: Observer
Manager counts+0x27A8/+0x3890/+0x38A8 each equal 1; their inline row-0 entries at
+0x27B0/+0x3898/+0x38B0 each hold object UI+0x46D900 and callback ID 0x118 at
entry+8. These are inline 16-byte entries, not pointers to an entry array. This
conservative ownership requirement does not guess maximum layout capacities.
Destruction must acknowledge all three counts zero. Rebuilding requires the
same Observer Manager with those freed rows still available, then acknowledges
the owned registrations again. A foreign refill refuses reconstruction.

Preparation creates exactly two disabled MinHook entries. Suppression rechecks the presentation and direct
function guards, enables both hooks, and then invokes only the Ship destructor.
Returned-call state is retained until initialized=0 and observer removal can be
read back. Failure
to stage/enable a hook performs no Ship destruction; retained hook state remains
available for explicit release.

Ordinary stop rebuilds only Ship HUD through the direct initializer and then
resizes it with the current UI+0x24E324 scale. It leaves activation to normal
ship update. The constructor runs inside a short-lived context-5 scope:
signed old depth `-1..2`, new depth `old+1`, next slot `GUI+0x2C5B8+newDepth`.
Both the overwritten slot and depth are journaled and restored. Values below
`-1` and above `2` are refused; the next push from old depth 3 would overlap the
depth DWORD. A changed GUI owner/context/depth keeps restoration pending and
does not overwrite foreign state. No constructor is replayed to resolve a
returned-call readback failure.

Before either common UI original runs on the owned UI, its synchronous entry
hook retires the suppressed presentation. If an owned Ship rebuild already
returned but awaits acknowledgement, the hook acknowledges and destroys that
rebuild once before forwarding, preventing overlap with the game's initializer.
The game then owns the shared-root lifecycle and next presentation. Foreign UI
objects pass through. Normal stop after acknowledged retirement performs no
reconstruction of an old UI. Hook release removes only these two targets and
never calls `MH_ALL_HOOKS` or uninitializes a potentially shared MinHook library.

No Mission HUD entrypoint, selector projection, scene assignment, player role,
actor/control API or MCM setting participates in this lease.

## Pending native construction and lifecycle failure

The native functions return void. Successful return plus initialized readback
are normal-path acknowledgements; an interrupted constructor is not a proved
cleanup contract. Interrupted destruction, construction or resize therefore
retains the owned phase. It does not guess a destructor, repeat construction,
remove hooks or claim restoration succeeded.

When pending/uncertain ownership prevents safe retirement in an entry hook, the
hook retains ownership and a visible lifecycle fault and does not forward the
common UI original. This deliberate failure behavior can hold an ordinary UI
transition. It is an unresolved runtime recovery limitation, not evidence of a
successfully handled transition. A partial-construction rollback contract is
still needed before treating this as a production feature.

## Isolated validation and test API

`tests/native_ship_hud_tests.cpp` uses synthetic module/UI/GUI memory, simulated
widgets/observer ownership and a fake MinHook backend. It checks module and root
identity refusal, disabled staging, partial hook-staging cleanup, enable rollback,
exclusive Ship destruction and observer row removal/reconstruction, refusal of
foreign/refilled observer rows, idempotence, all four allowed GUI depths and exact
scope restoration, foreign UI pass-through, thread refusal, changed UI-owner
refusal, returned destruction/construction readback retries, foreign context
restoration pending, and synchronous retirement before shared-root lifecycle.
An interrupted constructor must retain ownership, refuse replay/removal, and
block original shared-root calls. Scene, role and Mission fields are unchanged
sentinels. This validates module contracts with stubs; it does not prove native
widget appearance, Dispatches behavior or in-game restoration.

The test-only exports are guarded by `BC_NATIVE_TEST_API`:

- `BC_ship_hud_prepare` captures the current game module/UI and game-call thread
  and stages disabled hooks.
- `BC_ship_hud_suppress`, `BC_ship_hud_restore`, `BC_ship_hud_release` return 1
  only when the requested phase acknowledges completion.
- `BC_ship_hud_phase` reports the `Phase` enum from the header.
- `BC_ship_hud_flags` reports prepared=1, hooks enabled=2, owned=4, GUI restore
  pending=8, native lifecycle retired=16, blocked common UI lifecycle=32.
- `BC_ship_hud_error` includes an entry-hook lifecycle fault when present.

The fixture compiled with MSVC x64 `/W4` and the test export guard, and passed.
Outputs are under `DBF/dist/releases/bridge-combat-source-ship-hud-20261014`.

For a later standalone DLL review, compile only `native/ship_hud.cpp` and
MinHook's `src/buffer.c`, `src/hook.c`, `src/trampoline.c`, `src/hde/hde64.c` with
the x64 toolchain and `/LD /MT /O2 /EHsc /std:c++17 /W4 /DBC_NATIVE_TEST_API`.
Use an explicitly named output folder and `BridgeCombatShipHudReview.dll`.
`core.h` supplies inline guarded reads; `core.cpp`, mode, actor and legacy HUD
sources must not be linked into this separate review artifact. Loading or using
it still requires a separately authorized, bounded runtime test. DLL unload must
wait for acknowledged native ownership retirement/restoration and hook removal.
