# Native provider integration status

## Verified now

- Native lifecycle core and native interception DLL compile with MSVC /W4 /WX.
- Fourteen separate-process scenarios pass native interception, bootstrap,
  swaps, retirement, shutdown, foreign callback preservation, thread/reentrancy
  refusal, partial application and explicit cleanup retry.
- All 18 queue STORE bindings are integrated. The production path does not
  register an ADS-entry observer. Tests cover forced replacement, first-person
  fallback on head-only removal, malformed queues and body replacement.
- Across 1,000 unchanged first-person commits, there are no extra notices,
  discovery or setup. Unrelated actors' equips skip local discovery while a
  local binding is live.
- Component creation, retirement and plugin shutdown use their registered
  functions' entry points. Callback-table rewrites cannot detach them. This
  avoids losing shutdown when get_plugin_api(0) repopulates its table.
- A retirement-time commit cannot rebind the retiring avatar. A genuine creation
  event permits the same entity to establish a fresh generation.
- Commit thunks preserve carry/XMM state and execute original STOREs once. Five
  register forms, seven unwind boundaries each, a chained parent, direct near
  interception and native Windows stack walks pass.
- The fixture measured about 106 ns added per commit in one 200,000-event run.
  This excludes game witness checks and the HoB consumer; it is not live proof.
- All 71 guarded code spans (30,303 bytes) matched the running module in a
  one-shot protected read/SHA-256 capture, with no hooks installed.
- The actual C++ admission functions also pass on a non-executable saved image:
  module/lifecycle identity, foreign callback rejection, 71 code hashes, 18
  native unwind entries and altered-code/metadata rejection. No game code runs.
- Admission pins native continuation/unwind lifetimes. Control calls refuse
  concurrent/reentrant admission. Build receipts reject source changes during
  compilation or verification instead of reporting stale success.
- Production activation is closed. The installed Lua prototype is unchanged.

## Required next work

The native HoB consumer is implemented and its standalone guarded-memory fixture
passes. It prepares only the selected weapon on equip, caches negative eligibility,
applies the accepted 0.5-degree projectile cap on ADS entry, and restores the exact
native value on exit. Native continuous beams and direction overrides remain native.
It uses private writable storage and compare/exchange, preserves foreign edits,
retains failed restoration intent, and resolves relocated rows by identity.
Duplicate ADS notices do not repeat setup or writes. This is prototype behavioral
parity, not new proof of exact historical Arrowhead geometry.

The provider now exposes native OpenHoB, SetEnabled and ReadHoBStats controls;
no Lua callback or frame-delivery path is involved. Production activation remains
closed. The combined STORE/provider/consumer fixture is part of build_provider.py;
its generated receipt, rather than this document, establishes the latest result.

1. The separate lll/ adapter connects loader startup, MCM on_change and explicit
   cleanup directly to the C ABI. It has no on_update or on_cleanup_poll.
   Offline LuaJIT tests pass startup/settings, duplicate idleness, rejected and
   partial admission, failed cleanup retention/retry, actual entry wiring and
   the production FFI ABI. MCM must already be enabled; missing MCM fails
   startup rather than polling for it. Native rearm reuses retained thunks and
   trampolines, requires successful cleanup on the owner thread, and checks
   original bytes and the exact hook/commit layout before subscribing again.
   The linked fixture verifies repeated close/reopen transitions.
2. Offline consumer and linked-provider verification passes: guarded memory,
   foreign/failed writes, row relocation, 1,000 unchanged commits, forced exit,
   toggles, unwield, retirement/recreation and shutdown. Restoration is asserted
   inside native teardown bodies. Keep activation closed pending loader and live
   verification.
3. Separately authorize helper deployment, then verify actual transitions,
   thread identities, before-firing order, unchanged-state idleness, deployed
   overhead and introduced spikes. Offline tests and matching source bytes do
   not establish these live facts.

The objective remains the complete event-driven HoB path. These are intermediate
artifacts, not a partial fix to install or publish.

## Authorized live review: 2026-10-18

Review .1/.2 payloads were installed after explicit authorization; installed bytes
matched their review receipts. The loader identifier is live/goose_hob_native_review.
The existing prototype was disabled cleanly through live/goose_hob_ads_prototype.

Native activation failed at the first enabled hook, game.dll+0x127E9D0 (explicit
camera exit): diagnostic stage 8, index 1, MinHook 10 MH_ERROR_MEMORY_PROTECT,
Windows 5 ERROR_ACCESS_DENIED. Code/lifecycle admission and thunk construction
had passed. The rejecting component is not established by this error alone.
No transitions were captured; the consumer remained disabled, unowned, with zero
applications. This is not a successful live integration or performance result.

Explicit close acknowledged 1. A post-cleanup read matched all 71 source guards
(30,303 bytes). The review has no active loader record. The previous prototype
and its prior MCM enabled setting were restored. No game restart occurred.
The loaded review libraries remain retained as designed; installed review files
are inactive. Detailed receipts are under ignored dist/releases/.

The native interception route remains blocked by executable-page protection.
Do not weaken admission checks, bypass GameGuard or retry the same denied patch.
Remaining progress needs a supported native transition subscription supplied by
the game/loader, or an authorized environment where this hook route is allowed.
No polling substitute satisfies the objective.

## Subscription recheck after denial

Read-only live batches 12153/12155/12156 confirm the installed public events API
exposes weapon_changed, weapon_equipped and weapon_unequipped, with no aim/ADS/
camera event in its catalog. The live events module's weapons source still has
interval 0.1 and a poll function. Extracted event_sources.lua shows the same
held-weapon comparison implementation. It is not an alternative native producer.
No subscriptions or writes were made during this recheck. Live readback confirms
the review is inactive and the restored prototype MCM setting is enabled.

Completion remains unproven: offline transition/consumer/loader fixtures pass,
but actual callback coverage, thread affinity, before-firing delivery and deployed
performance are missing because native hook activation is denied. There is no
verified supported replacement source in the current loader/runtime interfaces.
