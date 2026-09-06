# Durable allocator-generation membership

`nakamageneration.Store` creates and reads immutable membership records for the
allocator-generation fence described in
[ADR 0002](../../docs/adr/0002-seal-zone-admission-secrets-before-readiness.md).
This package provides durable identity only. An `open` record alone never
authorizes allocation or clears a quarantined dispatch.

## API and identity

Construct a store with the authoritative Nakama runtime storage API:

```go
store, err := nakamageneration.NewStore(nakamaModule)
// Handle err before using store.
record, err := store.CreateOpen(ctx, generationID, allocatorPodUIDs)
// Retain the same generationID and membership when retrying an uncertain create.
record, err = store.Load(ctx, generationID)
```

Generation IDs are caller-stable opaque identities, distinct from membership
digests. Repeating a member set in a later generation uses a different generation
ID. Pod UIDs are opaque; their spelling is preserved and no UUID format is
required. IDs contain 1–128 UTF-8 bytes without whitespace or control characters.
A generation contains 1–256 unique member UIDs. The complete encoded record is
limited to 64 KiB. Validation happens before any storage access.

Creation sorts a copy of the members. The lowercase SHA-256 digest covers the
UTF-8 bytes of `world-at-ruin/allocator-generation-members/v1` followed by one
newline and Go's JSON encoding of that sorted string array, with no trailing
newline. JSON string boundaries and escaping are part of the digest contract.
The generation ID is not part of this digest. Returned member slices belong to
the caller and do not alias another returned record or durable storage.

## Durable creation and uncertainty

`world_at_ruin_allocator_generations` uses the generation ID as its key under
the system owner. Read and write permissions are both zero. A single create-only
write with Nakama version `"*"` persists the whole record; the API has no overwrite
or delete operation. An identical existing record is returned without a write.
A different member set at the same generation ID produces `ErrConflict` and
leaves the existing record intact.

Successful creation returns the exact acknowledged storage version. Any error
or malformed acknowledgement after entering the write triggers one readback
under a detached context with a five-second deadline. The context retains caller
values. An exact durable match proves success; a different valid membership
proves conflict. Missing, unreadable or invalid readback produces
`ErrIndeterminate`, including when the original caller was canceled. The caller
must retry the same generation ID and membership. The store never retries a
write automatically or interprets an uncertain result as permission to create a
replacement identity. Storage implementations must honor context deadlines.

`Load` reports `ErrNotFound` only for an absent standalone read. Invalid storage
metadata or JSON produces `ErrStorage`. Reads validate the requested key,
collection, system owner, private permissions, bounded non-wildcard version,
complete canonical membership and its digest. Unknown, duplicate, omitted or
invalid-null fields, malformed Unicode, trailing input, unsupported schemas and
unsupported states are refused. Valid Unicode spelling, paired surrogate escapes
and escaped backslashes remain accepted. A refusal never becomes an absent record
that creation can replace.
Underlying storage errors and document contents do not appear in returned errors.

## Compatibility and operational authority

Schema 1 contains `schema`, `generation_id`, `member_pod_uids`,
`member_set_digest` and `state`; its only supported state is `open`. The permanent
ledger and golden fixture preserve this shape. The registered historical test
checks every field through the decoder and the real store read path. Conventional
collection and reader registrations accompany the ledger for automatic schema
discovery.

The store is not registered in a runtime module. It does not select endpoints,
pin a generation into a lease, advance generation state, supply Kubernetes
termination evidence, or release quarantine. The supervisor's exclusive write
authority belongs to its eventual composition and credentials; this package
alone cannot enforce it. New state readers must ship and reach the retained
rollback artifact before their writers are activated, following the
[server durability contract](../../docs/design/server-state-durability.md#read-support-ships-and-bakes-before-the-writer-that-needs-it).

Run `go test -race ./nakamageneration` from `server/` to exercise immutable replay,
concurrent creation, private identity checks, strict history reads and uncertain
write recovery with the shared Nakama storage fake.
