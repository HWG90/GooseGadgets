ADS performance source

Promoted deliberately from the preserved ads-native-beams-20261015/prototype candidate in this owning repository. All installed runtime modules matched that preserved source before this change. The maintained all-mode HoB source remains separate. This change batches adjacent code fingerprint reads (at most 1024 bytes each), retains every byte comparison on every context call, and preserves all ownership, ADS, native-beam, write acknowledgement and cleanup checks.

The tracked-read journal now uses one flat array instead of allocating a table for each address read. Stability comparisons, order and retry/write behavior are unchanged.
