# Native transition provider: offline, production activation closed

This directory builds a lifecycle core, an experimental native provider DLL,
and separate-process fixtures. The provider binds native first-person request,
explicit exit, wield/unwield, component retirement and plugin shutdown paths.
Its production admission remains closed pending loader integration and live
verification. All 18 commit sites are wired through generated,
guarded thunks. Production also intercepts explicit exit, native wield/unwield
and the registered creation/retirement/shutdown functions. It does not install
an ADS-entry observer or rely on mutable callback slots: a plugin-API query can
rewrite the shutdown table. The native fixture verifies that table refreshes
cannot detach the lifecycle interception. Nothing here replaces the installed
mod. Builders never install, load a helper into the game or publish.

The core has no update method, timer, worker, memory scanner, message queue or
polling consumer. It does nothing between explicit native lifecycle deliveries.
Delivery is synchronous, on the constructing thread. Wrong-thread and reentrant
deliveries are refused. The sink is a non-throwing native C++ callback; it must
not be a LuaJIT FFI closure called from inside a native game routine. Subscribers
must not invoke engine functions reentrantly. Control entry points reject
concurrent/reentrant admission instead of waiting on a control lock.

The intended adapter contract is:

1. Deliver world begin with a verified avatar identity and monotonic generation.
2. Deliver pre-unequip before the old native record can retire. The consumer must
   restore ADS ownership and acknowledge release synchronously.
3. Deliver equip only after the native held weapon is accepted. Preparing the
   weapon happens once here. A different weapon cannot replace an unreleased one.
4. Deliver ADS entry after the weapon's first-person view is accepted, before
   targeting consumes the changed state. Input intent is insufficient.
5. Deliver exit before presentation/weapon cleanup, including forced camera
   replacement, death and weapon change. Duplicate notifications do no work.
6. Deliver world end before the native object lifetime ends. It orders ADS exit,
   unequip and invalidation. Invalidation is still sent after a consumer failure.
   Disable uses the same sequence. A failure prevents further application.

An entry acknowledgement can fail after a partial apply, so the core claims ADS
ownership before calling the consumer. It retains recovery intent. Failed
restoration is reported, never described as successful cleanup. On world end,
the consumer must invalidate its retired handles even if restoration failed.

The contract is not yet proven for all game paths. Current source evidence
identifies 18 camera queue commit sites in 17 parent functions. The parents have
71 code spans (30,303 bytes), no AVX instructions and no image relocations in
those spans. A one-shot read-only capture matched every span against the running
game. This proves source identity, not callback delivery, thread affinity,
complete forced-exit coverage or deployed performance.

The commit mechanism targets the actual STORE branches. It does not wrap the
frame evaluator. Thunks preserve volatile registers, flags and floating-point
state, execute the original store once, and deliver synchronous pre/post
callbacks. Windows unwind entries cover the native-frame prefix, synthetic
return, saved callback frame, temporary flags and return boundary. The local
MinHook fork jumps directly to near thunks; its change is documented in
vendor/minhook/HOB-CHANGES.md. Thunks, trampolines and unwind records are retained
for the process lifetime so cached native IPs are never reclaimed on detach.
Production admission also pins the original game module for those retained
continuations and unwind chains.

Run these from the Height Over Bore directory with local MSVC x64 available:

- `py -3 native-transition/build.py`: lifecycle core and contracts.
- `py -3 native-transition/build_provider.py`: provider DLL and fifteen native
  interception scenarios, including failed restoration followed by explicit
  cleanup retry. A linked consumer fixture also drives real guarded-memory
  layouts through native STORE hooks. The fixture-only injection export is
  absent from production. Failed restoration retains recovery intent without
  retrying on 1,000 subsequent commits; explicit cleanup can retry.
  Commit coverage includes forced replacement, head-only removal, fallback
  restoration, unchanged-mode idleness, same-entity recreation, bad queue/body
  witnesses and callback-table rewrites. There is no entry observer in that path.
- `py -3 native-transition/build_commit_fixture.py`: real commit interception,
  native register/flag preservation, seven unwind boundaries for five register
  forms, a chained parent and dynamic-table-aware native stack walks.
- `py -3 native-transition/build_guard_fixture.py <saved-image>`: production
  module/lifecycle guards, foreign callback rejection, 71 code digests and 18
  original unwind entries, with code/metadata mutation rejection. The explicitly
  supplied, authenticated snapshot is loaded as non-executable data only.

All outputs and receipts stay under ignored `dist/releases/` subdirectories.

The fixture verifies event ordering, duplicate suppression, explicit pre-unequip,
forced exits, stale generations, reentrancy, wrong-thread rejection, failed
partial apply and failed restoration followed by teardown invalidation. It does
not establish actual game callback coverage, live timing or deployed performance.
The commit fixture additionally measures thunk overhead against its unhooked
private function. It excludes game witness checks and the HoB consumer. On this
Windows host, CaptureStackBackTrace stops at private executable memory; explicit
RtlLookupFunctionEntry/RtlVirtualUnwind walks correctly through the native parent.

## Loader lifecycle adapter

The separate `lll/` source uses loader enable/disable, MCM setting callbacks and
an explicit cleanup button. It exports no update or cleanup-poll callback and
never registers a Lua callback with the native game hooks. MCM must be enabled
before HoB; missing MCM rejects startup instead of waiting in a frame loop.
The helper reference stays in loader scope while native continuations survive.
Failed startup or shutdown retains explicit cleanup intent.

Run `py -3 native-transition/test_loader.py <LuaJIT-DLL>` to verify the Lua
lifecycle with an explicitly supplied local runtime. The test also loads the
production FFI ABI offline and confirms its activation gate rejects admission.

Native rearm requires successful cleanup, the original owner thread, unchanged
original instructions and the identical hook/commit layout. It reuses the
retained thunks and trampolines. No native allocation, registration or setup is
repeated merely because the mode remains unchanged. Deployment and live proof
remain separate gates; the adapter is source-only and has not been installed.
