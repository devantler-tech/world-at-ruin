# Retain inactive authoritative mastery transactions

World at Ruin retains a private schema-1 mastery record and a private schema-1
mastery outcome through the shared player mutation audit collection. Weapon
tracks keep exact integer banked and unbanked points. Banked points are multiples
of 100 and never fall; unbanked points remain below 100. Opaque weapon identifiers
remain readable. A standing stain has an exact identity and positive per-weapon
amounts. The client vault grammar is independent and unchanged.

The server-only owner is default-off through its explicit `Config.Enabled` flag.
There is no production import, RPC or gameplay writer. Its process-local event
seal is an ownership boundary, not external source authentication. Production
composition requires runtime-authenticated original source provenance, combat
eligibility and diminishing-return policy, account-specific opt-in, and retained
reader and rollback evidence. Those gates remain in #1100 and #1101; #926 remains
open. Enabling an internal test owner does not satisfy them.

An event identity uses the original source UID, original source incarnation and
original event ID. Restarts and retries retain that tuple. Operation, weapon,
amount, death percentage and expected stain identity bind the immutable audit
payload instead of changing the event key. Changing any of them under a committed
identity is a key conflict.

Every operation authenticates the exact account before accessing system-owned,
private storage. The owner looks up the original audit before reading current
mastery. A new decision commits one conditional record replacement and one
create-only audit in the same storage batch. Valid no-op deaths also commit an
audit, so replay cannot deduct value earned after the original event.

Awards bank whole 100-point steps within the JSON exact-integer ceiling. Death
transfers the integer-floored configured share of unbanked points to a newly
identified stain. Positive loss replaces the previous stain and audits destroyed
amounts; zero loss retains it. Reclaim requires the exact standing identity and
validates the entire transfer before committing. Conflicts require redecision
under the same immutable event. Read-only recovery returns the original durable
outcome or keeps the dispatch indeterminate. An absent audit is not evidence that
a dispatched write failed.

Complete original record and outcome fixtures, production decoder registrations,
and physical writer registrations are retained by the existing durability guard.
Local conditional-storage scenarios establish the inactive owner's behavior;
production provenance, Nakama rollout and gameplay outcomes remain separate proof.
