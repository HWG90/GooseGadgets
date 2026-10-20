# Owned native dispatch-pointer helper

Build and run the isolated fixture with `py -3 native/build.py`. Outputs go to ignored `dist/native`. The fixture uses synthetic images, descriptors, registry and callsites allocated only in its own process.

Version 0.1.5 exchanges two naturally aligned Unit API function pointers in existing committed read-write image data. It makes no executable instruction writes, permission changes, cache flushes or thread suspensions, and links no MinHook code. Native setter instructions must match captured prefixes and remain unchanged. Version 0.1.4 source/build evidence is retained under ignored `dist/research/native-alignment-0.1.4-preserved`.

ABI 1 remains 72-byte config/stats. Validate checks normal-camera ownership, binary/API contracts, alignment and committed image PAGE_READWRITE slots without mutation. Begin returns 1 only after both compare/exchanges are owned and final ownership passes. It returns 0 for rejection with no owned lease, or 2 when a partial installation needs owned cleanup. Lua must retain that handle and call End for result 2. BUSY result 0 must not release another owner.

Original setters are stored before callbacks are published. Callbacks forward unchanged until armed, and skip only the two expected callers, leased viewmodel and node 0 with current native owner/request/descriptor/controller/unit-generation guards. TTL expiration or native ADS disables skipping but reserves the lease until End. Counters reset per successful Begin; the deadline is at most 10,500 milliseconds.

End disarms, synchronizes with policy readers, and compare/exchanges only its own callback pointers back to originals. Foreign replacements are preserved. Unreadable or non-writable owned slots retain the reservation and return failure for cleanup retry. Callbacks stay process-pinned so cached or in-flight pointers can forward after restoration. Successful End reports installed=0 after both pointers restore or positively retire.

This helper supplies no camera transforms, animation events or visibility changes. Synthetic success proves its dispatch contract; the visual effect is a separate live test.
