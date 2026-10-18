# Changelog

## 0.1.2-experimental — 2026-10-18

- Cache weapon-definition discovery per equipped generation; reuse it across ADS exit/reentry.
- Replace repeated full observations and resolutions with a single-pass ADS transition observer and selected-row lease checks. Full admission/copy/restoration checks remain fresh.
- Invalidate on swaps, owner/World changes, moved runtime rows and unreadable or competing bytes. Authored metadata is revalidated on transitions instead of every frame. Pending and partial cleanup cannot skip work.
- Update MCM status controls only when their rendered state changes.
- Reuse ADS polling helpers instead of constructing functions every update; retain the same protected reads and closing checks.
- Cache validated protected-read arguments in a bounded pool. Each call still copies fresh bytes and requires an exact transferred count.
- 156 isolated contracts plus 14 parameter cases; combined real Gate + Backend fixture uses 16 protected reads per stable ADS update, down from 40 with zero full discovery or writes. Live timing is recorded separately.

- Bound settled polling to 60/s without catch-up bursts; disabled clean state stays idle. Pending cleanup and shutdown remain immediate. Transition detection may lag by about 16.7 ms plus scheduling.
- Matched live LLL ADS samples: prior installed version 7.30 ms/s, new 4.91 ms/s (33% lower overhead), same weapon and scene at about 115 updates/s. Rapid ADS exits/swaps passed qualitative testing; transition sample 7.00 ms/s, worst update 3.87 ms still under investigation. BSL live timing remains unmeasured.

## 0.1.1-experimental — 2026-10-16

- Separate LLL and BSL ADS source under `ads-prototype`, with deterministic builders and offline fixtures.
- Limit normal projectile ADS correction to 0.5 degrees, retaining per-weapon baselines and exact restoration. Hip fire, third-person aiming and continuous beams keep native settings.
- Batch adjacent fingerprint reads, flatten the read journal and reject inactive controller/camera states early while retaining all acquisition and cleanup proofs.
- Adjudicator and secondary close/far comparisons passed qualitatively through LLL. The experimental limit is not a recovered historical value; live checks of the performance changes, broader weapon coverage and BSL live validation remain pending. Offline coverage: 111 contracts plus 14 parameter cases.
- Correct the 0.1.0 documentation to identify its reported hip-fire/laser issue and the limits of earlier acceptance evidence.

## 0.1.0-experimental

- First standalone Height Over Bore release for BSL, LLL and MDL.
- BSL uses the original Mod Options Menu. LLL and MDL use DBF-MCM.
- Enabled defaults to Off and the menu provider saves the preference.
- Shared backend discovers projectile and beam aiming components across current inventory, new weapons, player retirement and world changes.
- Uses guarded, entity-owned definitions and exact restoration, with cleanup retry and foreign-edit preservation.
- Standalone packages, deterministic builds, SHA-256 receipts and isolated lifecycle/backend fixtures.

The Adjudicator projectile effect has prior visual confirmation. BSL/MDL live integration and broader weapon-family visual acceptance remain pending.
