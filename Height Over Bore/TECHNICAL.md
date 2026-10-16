# Height Over Bore 0.1.0 runtime contract (historical)

The 0.1.1 ADS release uses the separate [`ads-prototype`](ads-prototype/README.md) source. Its experimental correction cap does not modify the authored definitions described below. These notes document the older 0.1.0 implementation.

Previous experiment: owned definition angle `180 → 0`, naturally derived runtime direction flag `0 → 1`; seventeen sampled shots; user confirmed “THAT works”; on/off/on and exact restoration verified. Direct late writes to the runtime flag did not produce the requested result. This was a scoped current-build experiment, not a comparison against the original game in every aiming mode.

Subsequent comparison against captured 1.000.305 code and authored tables found that the Adjudicator originally uses target convergence from the muzzle origin. Its original Boolean policy maps to the current 180-degree policy, rather than zero. Full historical restoration also requires coherent runtime angle caches and original target/origin handling. The released universal zero-angle implementation is therefore not an exact restoration; the reported hip-fire/laser issue and complete replacement remain unresolved. Private offline candidates are not release or live-acceptance evidence.

Projectile manager, relative to the global pointer at `game.dll+33266D8`: runtime map `+50`, descriptor array `+68`, runtime array `+78`, entity-to-definition map `+90`, inverse map `+B0`, live definition count `+C8`, definition array `+D0`, stride `268`, aiming angle `+30`. Dynamic row addresses can move on removal, so every write resolves the entity again and checks both maps, descriptor identity and a preserved definition prefix.

`742550` derives the default direction flag from the definition angle; `515100` chooses the private definition or a shared fallback; `612800` assigns the runtime flag. Native materialization `61AF10` copies the matching base definition into owned storage and applies the modifier list. A modifier row `{0x141,0,0}` returns from `515540` before patch-pool access. Capacity and exact type resolution are checked first. Unsupported builds or layouts refuse writes.

Beam manager global `3326A20`: runtime map `+40`, descriptors `+58`, entity-to-definition map `+70`, inverse map `+90`, count `+A8`, capacity `+24`, definitions `+B0`, stride `78`, angle `+C`. `841AF0` materializes with modifier row `{0x10E,0,0}`; `50ECC0` resolves definitions; `83F750` assigns the runtime flag. Beam firing `83ECDE` selects the unchanged muzzle-node basis when that flag is true. Its preserved prefix excludes the modified angle.

Base-definition tables and ECS descriptors use exposed World global `346BF98`. Manager ownership uses implementation global `346BFC8` plus `F0B3B8` (projectile) or `EB6758` (beam); those two World pointers are distinct. A zero-patch clone must read back as the full original definition before the angle write. Restoring the angle leaves the engine-owned private row for normal component teardown.

There is no proved monotonic manager reset epoch. Entity/unit identity, live forward/inverse maps and preserved definition bytes provide conservative continuity checks; identical reuse of all those values is not independently distinguishable. No memory address or weapon value is saved to disk.

The controller journals each owned edit before mutation. Cleanup verifies current ownership and exact bytes before restoration, skips retired records and foreign edits, and retains unreadable records for retry. LLL uses its cleanup-poll callback. BSL retains its cooperative update wrapper until cleanup acknowledges. MDL uses its normal lifecycle callbacks and retains a cleanup-only update wrapper if disabled updates stop before restoration completes.

The backend has fixture coverage for both component families, failed reads/writes, code mismatches, private materialization, capacity, map movement and lifecycle restoration. Controller and adapter fixtures exercise menu persistence, player retirement, world changes, provider replacement and cleanup retries. These checks are separate from observed in-game visual behavior.
