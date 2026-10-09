# ADR 0032 — Read issued grant journals without restoring authority

Status: accepted for an inactive source-reader contract (#1291). Journal writes,
durable recovery and production activation remain #793 and #569 gates.

The experimental private journal reader requires explicit enablement. Its
construction copies an independently supplied binding: generation ID and source
version, canonical member set and digest, authority incarnation, namespace and
Fleet, complete issued-set count and digest, and exact journal storage version.
Generation source version and journal storage version are distinct identities.

The journal key is a domain-separated SHA-256 over the JSON array containing
generation ID and incarnation. A read requires one successful private,
system-owned Nakama object at that exact key and collection/version. A row
returned alongside an error is not an observation. Missing, changed, public,
foreign and canceled reads return no inventory and no backing-storage details.

Schema 1 retains canonical member UIDs and zero to 256 grants, ordered by target
UID. Every grant retains actor UID, attempt ID, target name/UID and frozen
resource version; namespace and Fleet belong to the whole journal. Duplicate
target names or UIDs are refused. The issued-set digest is domain-separated
SHA-256 over Go JSON encoding of the ordered grant array, using the declared
field order. The reader recomputes it and compares both count and digest with
the independent binding. It never adopts expectations from the row itself.
JSON fields must be exact and complete at both nesting levels; null, unknown,
duplicate, lossy-Unicode and oversized input is refused.

A matching digest establishes agreement with the independently supplied set.
It cannot establish that no capability was omitted by its producer, exclusive
writer membership, durable admission closure or loss of mutation authority.
The returned inventory is detached diagnostic data. It cannot reconstruct a
grant or receipt, reopen an owner, replay a barrier or release quarantine.

The real kube-apiserver/etcd trial observes two outstanding native writes after
a fresh journal-reader construction. In the unfenced arm those writes still
allocate. In the fenced arm their frozen versions conflict after actual
barriers, and a fresh owner rejects the previous owner's receipt. The journal
fixture uses the shared Nakama storage fake; this proves the source reader,
not a serving Nakama rollout or actual retained-artifact compatibility.

No journal writer exists. The default-off read-only startup observation in
[ADR 0035](0035-observe-journals-through-the-packaged-nakama-candidate.md) adds
identified candidate-reader evidence. The permanent schema fixture
and production-reader registration preserve the reader contract before future
writer work. Activation requires every serving reader and the actual retained
rollback artifact to accept proposed documents, a complete durable grant
journal, authenticated exclusive writer membership, authority-incarnation
recovery, serialized durable admission/drain and real handoff reconciliation.

References: [ADR 0031](0031-close-the-complete-issued-gameserver-capability-set.md),
[server save-data contract](../design/server-save-data.md).
