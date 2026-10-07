# ADR 0019: Expand allocator readers before state writers

Allocator generation schema 2 represents open and draining observations with the
same immutable, canonical member set as schema 1. Lease schema 4 retains a
generation ID, member-set digest and selected allocator Pod UID. These scalar
values identify observations; they neither authenticate an actor nor establish
loss of allocation commit authority.

Readers retain every historical schema and the complete expanded records at
their exact storage versions. Schema 4 requires all three binding members. Only
undispatched staging, including staging release, has an empty binding. Dispatched,
finalized, claimed and allocated releasing records retain a complete binding.
Finalization clears transient dispatch flags while preserving the binding.

Expanded records are reader-only. Existing generation creates write schema 1 and
lease writers write schema 3. Mutations recheck the durable record, rather than
trusting a caller's reconstructed observation, and refuse expanded schemas before
any write, deletion, external cleanup or admission result. Read-only provenance
is independent of binding presence and lifecycle state. Refusal is never absence.

Historical fixtures remain immutable; complete expanded fixtures and their
registered reader tests cover lossless read support. Serving-reader rollout and
actual retained rollback-artifact readback remain required before a separate
writer activation. Current fixture tests do not establish either deployment fact.

No state writer, production composition or fencing authority is activated.
Draining, Pod absence, replacement, cancellation and expiry do not clear an
ambiguous dispatch. ADR 0012's commit-boundary proof remains required.
