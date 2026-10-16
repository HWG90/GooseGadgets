# ADS source origin

The `ads-prototype` source was promoted from the preserved `ads-native-beams-20261015/prototype` candidate in this owning repository. The original 0.1.0 all-mode implementation remains in the parent directory.

Later performance work batches adjacent backend code-fingerprint reads into spans of at most 1024 bytes and uses a flat tracked-read journal. Every backend fingerprint comparison and ownership stability check is retained. Negative-only controller/camera screening can reject inactive observation before inventory discovery; full ADS and inventory ownership proofs remain mandatory before acquiring a writable lease. Existing cleanup is still processed after inactive observation.

The release retains the same experimental 0.5-degree projectile ADS policy. These performance changes are covered by isolated fixtures, including immediate restoration on inactive mode transition; they are not new live weapon-acceptance evidence.
