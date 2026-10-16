# Changelog

## 0.1.1-ads-prototype.4 (unreleased)

- Separate LLL and BSL candidate source under `ads-prototype`, with deterministic builders and offline fixtures.
- Limit normal projectile ADS correction to 0.5 degrees, retaining per-weapon baselines and exact restoration. Hip fire, third-person aiming and continuous beams keep native settings.
- Batch adjacent fingerprint reads and flatten the read journal while retaining each comparison and ownership check.
- Adjudicator and secondary close/far comparisons passed qualitatively through LLL. The experimental limit is not a recovered historical value; final live validation, broader weapon coverage and BSL live validation remain pending.
- Correct the 0.1.0 documentation to identify its reported hip-fire/laser issue and the limits of earlier acceptance evidence.

## 0.1.0-experimental

- First standalone Height Over Bore release for BSL, LLL and MDL.
- BSL uses the original Mod Options Menu. LLL and MDL use DBF-MCM.
- Enabled defaults to Off and the menu provider saves the preference.
- Shared backend discovers projectile and beam aiming components across current inventory, new weapons, player retirement and world changes.
- Uses guarded, entity-owned definitions and exact restoration, with cleanup retry and foreign-edit preservation.
- Standalone packages, deterministic builds, SHA-256 receipts and isolated lifecycle/backend fixtures.

The Adjudicator projectile effect has prior visual confirmation. BSL/MDL live integration and broader weapon-family visual acceptance remain pending.
