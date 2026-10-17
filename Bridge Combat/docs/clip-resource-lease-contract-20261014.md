# Existing resident clip references, 2026-10-14

Static analysis of saved loaded EXE `6AB382E4` and game `6AB3B43F`.
The parent captured the new function bodies in Toolkit batches 567--571.
This audit made no game commands, native calls, package operations, memory
writes, deployments, or maintained runtime changes. The contract below is
ready for an isolated helper and synthetic tests; it is not live validation.

## Result and scope

The ordinary ResourceManager request adds a separate reference to an existing
exact clip. Its completion counter and subsequent literal type/name release
do not require loading or unloading the borrowed SDK package group. Limit
the helper to the already resident animation type `931e336d7646cc26`, a
generation-validated current Unit and its ResourceManager, and the exact
participating clip list selected by the current graph. Require successful
restoration before relinquishing the helper's references.

The loaded core child `18235e0c9ec0e636` with game aggregate refs zero is a
borrowed resource owner. Neither loaded state4, package-pair coverage, a Lua
userdata reference, nor stable actor/graph pointers prove its boot lifetime.
No owning boot field or unload-exclusion contract was found. It must not be
reported as a weapon counted lease, or passed to SDK load/unload as an extra
retain. A private per-clip reference is the narrower established route.

## Native request and arguments

```cpp
void __fastcall request(             // EXE+5F4A90
    void* resource_manager,           // RCX
    uint64_t diagnostic_package_name, // RDX, value, not hash pointer
    const uint64_t* exact_type,       // R8
    const uint64_t* exact_name,       // R9
    void* package_context,           // stack argument 5
    uint32_t* completion_counter);   // stack argument 6

void __fastcall wait_complete(       // EXE+5F83B0
    void* resource_manager,
    uint32_t* completion_counter);

void __fastcall finalize(            // EXE+5F8590
    void* resource_manager,
    const ResourcePair16* pairs,
    uint32_t pair_count);

void __fastcall release(             // EXE+5F5730
    void* resource_manager,
    const uint64_t* exact_type,
    const uint64_t* exact_name,
    void* package_context);
```

`ResourcePair16` is `{uint64_t type, uint64_t name}`. The normal caller at
`671AE8..671B15` supplies child+8, the child+10 package-name **value**, pointers
to literal pair+0/+8, child+B8, and child+28. Its branch beginning `6717CA`
explicitly supports child+B8==0. The private helper may reproduce that null
context branch with independently owned counter/argument storage; it must
not borrow child+28 or a native context belonging to the core package.

`5F4A90` copies the hash values into a private 0x78-byte queued request at
+38/+40. Argument6 is retained there at +68; operation kind1 is +60. The
existing exact record path of `5F5340` increments Record+8 while holding the
ResourceManager+2D8 lock (`5F54D3..54D8`) and sets queued request+74 to1. It
then atomically increments the caller's counter at `5F54F7..54FC` and enqueues
the request. This is a normal queued load/reference operation, not a raw
counter write or a retain-only machine-code fragment.

First24 fingerprints, to recheck before every newly bound native route:

| RVA | Saved bytes |
| --- | --- |
| 5F4A90 | `48895c241848896c242056415441564881ecb0000000448b` |
| 5F83B0 | `48895c2410574881eca00000008b02488bfa488bd985c074` |
| 5F8590 | `4585c00f84090200005541564883ec3848895c24504c8bf2` |

The release fingerprint and exact resident getter `5F34E0` are in the
existing same-build release/getter evidence. Also check both module stamps
and current Unit/context/manager identity. A matching timestamp alone is
insufficient when a saved code body differs from installed disk code.

## Completion and finalization

The normal no-context package caller allocates eight bytes, zeros its first
u32, and retains that storage at child+28 (`6717E2..671805`). In the completed
request consumer `5F64A0`, operation1 with request+74==1 enters
`5F741F..7476`: it checks the literal type/name through `5F3210`, disposes its
own task storage, and performs **no second resource-reference increment**.
The common completion path atomically decrements the supplied counter at
`5F73F9..7407`.

`5F83B0(manager,counter)` processes completed jobs through `5F64A0` and pumps
ordinary ResourceManager synchronization until the counter reaches zero.
It has no timeout and does not free the counter. The normal caller frees its
owned counter only after it returns (`60CC35..60CC55`). A private helper must
retain its counter through completion, including any dispatch exception,
unknown readback, cancellation, or actor replacement. It may poll an owned
counter while ordinary engine synchronization completes the jobs; a positive
counter is pending, not readiness. Do not repeatedly dispatch to resolve an
ambiguous acknowledgement.

After completion, normal child finalization `671E60` calls
`5F8590(manager,pairs,count)` before storing loaded state4. The finalizer finds
the registered type callback row and skips pairs whose row+30 callback is
null (`5F8609..860E`). Otherwise it resolves the exact name in the type's name
map and calls that callback with `(row+8 context, resource_data, manager)` at
`5F8762..876C`. It does not decrement resource references. Mirror the normal
completion -> finalize -> exact resident getter sequence; counter zero alone
is not a substitute for that normal resource preparation step. Recheck that
each selected clip returns the same exact data and expected reference delta.

## The record slot bound now identified

The completed request consumer establishes a logical A0-record slot extent:

1. `5F672E..6736` obtains the TypeValue from ResourceManager's type map via
   `5FB200` and saves it; this accessor is native mutation evidence, not a
   proposed read-only lookup method.
2. `5F6A79..6AA0` reuses TypeValue+BC's free-slot index when available, taking
   the next free head from that record's +8.
3. Otherwise `5F6AA2..6ABA` asks `5F9FA0(TypeValue, u32(TypeValue+0)+1)` to grow
   the records, chooses `u32(TypeValue+0)-1`, and computes
   `ptr(TypeValue+8)+index*0xA0`.
4. It fills this record and installs that index in the exact name-map value at
   `5F6B63..6B70`.

Thus TypeValue+0 is the logical **slot extent**, including reused/free slots;
it is not the number of live resources. TypeValue+4 capacity is still not an
independently proved allocation-capacity field. A guard can now require
`0 <= exact_name_index < slot_extent`, the validated active exact-name row,
stable record-base/type/name-map headers, nonnull nonpoisoned Record+0, sane
positive Record+8, and equality with the exact native `5F34E0` data result.
Reject the known free/poison values and incoherent snapshots; do not accept a
slot merely because its pages are readable. Preserve the data pointer,
record address/index, extent and lookup identities around each operation.

TypeValue+B8 increments on both resource installation (`5F6B77`) and final
release (`5F5A8A`). Its earlier interpretation as a free-record count is not
supported; it may be used as an additional change detector, not as a bound
or ownership count. TypeValue+BC is the free-chain head, not a live count.

## Private journal, release guard, and tests

Record a journal entry and retain its argument/counter storage **before**
dispatch. Keep dispatching/unknown entries after native exceptions or
ambiguous readback. Only an acknowledged private +1 reference becomes held.
Do not infer that the pre-existing core package's reference belongs to the
helper. Deduplicate exact type/name keys and reject conflicting aliases or
changed record/data identities.

Cleanup starts only after the pose/state consumer has been restored and
acknowledged. Re-resolve the current exact record and require at least2
references before normally releasing the helper's one held reference. Check
the same record/data afterward and require exactly one decrement with at
least1 remaining. A sole private reference, missing normal owner, changed
manager/map/record, unreadable state, or ambiguous native result remains
pending; do not retry an unknown release or call final teardown. This floor
preflight is conservative and is **not an atomic conditional decrement**.
Keep execution within the coherent current main-thread actor/manager scope;
read-only snapshots do not exclude a concurrent foreign unload. On world or
actor replacement, stop consumer writes and preserve unresolved ownership.

Focused synthetic tests should cover six-argument order/value-vs-pointer
hashes, null context, a private counter retained while pending, counter-zero
completion before finalization, exact +1/-1 acknowledgements, no duplicate
dispatch after exceptions, slot extent/free-poison rejection, changed
manager/map/record refusal, release-at1 refusal, partial cleanup, and owned
storage retained on cancellation. Tests and source inspection cannot prove
the selected clips' live playback or make a native final release safe.

## Evidence files

Toolkit: `bridge-resource-5f3680.hex`,
`bridge-sdk-child-load-671400-20261014.hex`,
`bridge-sdk-child-request-6719da-20261014.hex`,
`bridge-sdk-child-complete-671e60-20261014.hex`,
`bridge-resource-wait-5f83b0-20261014.hex`,
`bridge-resource-finalize-5f8610-20261014.hex`,
`bridge-resource-completed-5f64a0-20261014.hex`, and
`ship-crash-analysis.asm.txt`. Decode the finalizer by joining the first
capture's `8590..8610` bytes with the remainder beginning8610; that remainder
starts in the middle of an instruction and must not be independently
disassembled as a function entry.

The SDK package labels also need care: `48CFF0` iterates the actual child
load `6716F0`; `48D080/48D050` call group flush `60CBE0`; `48D0E0` calls
group unload `60CE00`. SDK `has_loaded` at `48D150` calls `60CB20`, which can
advance load stages and invoke `671B90`. It is not a pure read-only guard.
`60CBB0` is the pure all-children-state4 checker. None of these group methods
adds an independent reference to the borrowed SDK object.
