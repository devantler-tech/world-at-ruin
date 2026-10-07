# ADR 0012 — Keep allocator fence authority at the commit boundary

Status: accepted for an inactive reference protocol. Production allocator fencing
and quarantine release remain blocked by #793 and the real handoff proof in #569.

An allocation request can reach its server, lose its response or exceed its
deadline, and still commit. A canceled connection, stopped forwarding proxy,
finished callback or dead allocator Pod cannot prove that an already submitted
Kubernetes write will not take effect. A definitive zero-resource result needs
authority that prevents those mutations at the place where they commit.

`server/internal/fencereference` owns an in-memory allocation ledger and performs
its generation check and ledger mutation under one shared lock. Admission,
drain, commit and fence use that same authority. Copying its public handle shares
the private state and lock. No external API, callback or delayed mutation occurs
inside its commit operation. This is a reference for the required boundary; it
cannot fence native Agones writes.

Construction requires explicit enablement, an exact open generation observation,
its source version, a canonical complete member digest and a distinct trusted
server-public-key pin for every member. Membership and pins are copied and never
changed. The source version is an opaque observation identity, not an ordering
number or a fence. The reference does not discover, persist or authenticate that
record; its caller must obtain it from the trusted durable reader.

Admission issues one opaque process-local ticket per attempt and refuses a
second dispatch. The generation has a finite admission budget, defaulting to
256 with a maximum of 4096. Successful commit records the exact actor, attempt
and resource. Exact replay is idempotent while open; conflicting replays or reuse
of a resource fail. Drain closes admission and revokes every uncommitted ticket.
Once drained, commit always refuses, including exact replay; callers resolve
the terminal outcome through the fence receipt instead.

A fence receipt belongs to the originating authority incarnation and binds its
terminal revision, exact generation, digest, source version and complete member
set. It cannot be reconstructed from public fields or serialized across restart.
Only that receipt permits a committed outcome or definitive absence in the owned
ledger. Cancellation, deadline expiry and a lost response leave an attempt
unknown without this proof. Reconstructing a reference after a restart grants no
authority over the earlier instance's attempts, allocations or receipts.

The reference TLS client preserves normal certificate-chain and hostname checks,
requires TLS 1.3 and additionally pins the allocator **server** SPKI to its exact
member UID. The coordinator client certificate is a separate identity. Issuance
and mapping must come from an operator-trusted source; Pod labels, addresses,
metadata and a certificate sharing a CA do not establish the member identity.
The executable fixture verifies both directions of TLS identity and uses Agones'
generated Allocate RPC over a real loopback TLS connection. It holds a request
across an accepted fence and observes the actual ledger, with an unfenced positive
control and cancellation, deadline and lost-response cases.

The constructor is default-off and no production command, adapter or plugin
imports the reference. A composition guard checks decoded Go imports, including
raw, escaped and aliased forms. There is no production switch, new endpoint,
durable schema or change to the existing ambiguous-dispatch quarantine.

Production activation needs the equivalent authenticated generation check and
mutation in the actual Agones/Kubernetes commit boundary, backed by durable
incarnation recovery and the end-to-end acceptance gates. Forwarding this
reference's receipt or replacing its ledger with a network callback does not
meet that requirement. The reference remains independently inspectable while
that design is unresolved; no receipt here can authorize cleanup or release in
the production handoff coordinator.
