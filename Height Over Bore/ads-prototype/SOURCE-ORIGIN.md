# ADS source origin

The `ads-prototype` source was promoted from the preserved `ads-native-beams-20261015/prototype` candidate in this owning repository. The original 0.1.0 all-mode implementation remains in the parent directory.

Later performance work batches adjacent backend code-fingerprint reads into spans of at most 1024 bytes and uses a flat tracked-read journal. Every backend fingerprint comparison and ownership stability check is retained. Negative-only controller/camera screening can reject inactive observation before inventory discovery; full ADS and inventory ownership proofs remain mandatory before acquiring a writable lease. Existing cleanup is still processed after inactive observation.

The release retains the same experimental 0.5-degree projectile ADS policy. These performance changes are covered by isolated fixtures, including immediate restoration on inactive mode transition; they are not new live weapon-acceptance evidence.

The 0.1.2 equipment-cache candidate retains admitted read-only definition guards and skips full controller work only after a settled observation. Its watcher cannot authorize copies. Every acquisition and restoration still resolves current identity and validates the code/layout before writing; failed or partial acknowledgements keep the existing cleanup journal.

Revision 2 moves polling helpers and the protected module-handle conversion into stable functions. This removes function construction from the settled update without reducing its protected reads or changing write authorization.

Revision 3 adds a bounded cache of validated protected-read arguments. Cached entries retain only address conversion, size and copy setup; every invocation performs a fresh protected copy and checks the exact byte count. Ownership and fingerprint comparisons remain unchanged.

Revision 4 replaces steady-state proof replay with a non-authorizing single-pass transition observer and selected runtime-row witnesses. Authored metadata is checked at transitions/equip; native mode and cap changes remain immediate. Full write-time fingerprints, ownership and restoration validation are unchanged. Fresh World/equipment/camera identity checks and protected copies remain in the observer.
