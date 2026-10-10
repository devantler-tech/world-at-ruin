# ADR 0036 — Serialize durable grant registration and drain

Status: accepted for the default-off admission experiment (#1313), following decision #1312. Production allocator fencing remains #793.

## Context

The process-local generation owner serializes preparation and closure but cannot arbitrate another process incarnation. Schema-1 grant journal keys include incarnation, so two incarnations can create different journals for one generation. Private Nakama permissions exclude clients, but other runtime writers remain possible. Durable records do not authenticate exclusive allocation authority.

## Decision

Use one private generation-scoped admission document, keyed by SHA-256 of the domain-separated JSON generation ID, independently of incarnation. It contains schema 1, phase `open` or `draining`, and the existing complete strict schema-1 journal inventory. Immutable generation membership, source version, incarnation, namespace and fleet remain inside it. One bounded object avoids a multi-record transaction join.

Create uses Nakama create-only version `*`. Every registration and irreversible drain uses the exact returned root version. Registration adds the frozen target without refreshing its GameServer UID or source version. Drain changes only phase and preserves the complete registered set. Competing registrations or drain against one version cannot both update it. A losing or uncertain operation returns no snapshot and poisons further writes by that experimental writer; it never reads a new version or retries. Successful snapshots have private writer provenance and export detached diagnostic observations only. They are neither mutation capabilities nor fence receipts.

The candidate writer is composed only in the explicitly built `war_native_trial` plugin and also requires `WAR_ALLOCATOR_ADMISSION_PROBE_ENABLED=true`. Normal runtime artifacts have no admission writer import or activation path. Trial startup controls choose a sequence, competing incarnations, simultaneous registration/drain, or a reply lost after the actual native transaction. Flag retirement is tracked in #1316.

The permanent strict reader refuses ambiguous JSON, unknown schemas/phases, incomplete or noncanonical inventories, lossy identities, wrong owner/permissions, stale versions and independently pinned binding/phase/count/digest mismatches. Observations cannot create a writer, snapshot, GameServer capability or receipt. The original journal reader remains StorageRead-only; its schema and historical bytes are unchanged.

## Exposure, crash and recovery order

Capability integration ([ADR 0037](0037-register-frozen-capabilities-before-exposure.md), #1314) freezes the GameServer outside admission, persists registration, then exports a capability only while local admission is still open. A crash before registration exports nothing; a crash after registration leaves a conservative entry even if nothing escaped. If registration wins before drain, drain includes it. If drain wins, registration fails. A late registration acknowledgment cannot export after local closure. In-flight entries and an explicitly empty set are both covered. Production authority and independent recovery remain separate gates.

Lost or malformed replies, cancellation after submission and partial evidence remain unknown. Restart may not reopen admission, replay allocation, refresh a frozen target, reconstruct receipt pointers, or learn a new authority incarnation from storage. Admission closure is not a GameServer barrier: #1315 must reconcile every potentially issued frozen mutation against acknowledged barriers and exact readback at real kube-apiserver/etcd. Missing targets, replacement UIDs, changed histories and partial/lost barrier replies retain quarantine. Nakama and GameServer writes are distinct storage transactions.

## Alternatives and activation gates

Per-incarnation create-only journals fail generation arbitration. A separate service adds an operational boundary without proving the existing mutation boundary exclusive. A Kubernetes-owned supervisor cannot combine Nakama registration with Agones mutation. Pod disappearance, stored digests, operator assertions and serialized receipt fields do not establish closure or recovery.

This increment ships source and a disposable native write-path proof. It does not enable serving writers, deploy a server, allocate GameServers or release quarantine. Activation still requires actual serving-reader adoption, readback by the actual retained rollback artifact, authenticated exclusive mutation authority and held-write/restart integration evidence under ADRs 0012, 0031, 0032 and 0035.

## Validation

Source tests cover generation-wide election, conservative zero/full set closure, stale transitions, original identity validation, private snapshot provenance and unknown acknowledgments. Native Linux amd64/arm64 acceptance uses the pinned Nakama Go runtime's StorageWrite path against fresh disposable PostgreSQL. SQL independently reads the resulting row and verifies one generation root, private permissions, immutable binding, exact frozen inventory and race outcomes; it never seeds the admission record. Fault injection loses the reply only after a real committed write. Existing real GameServer fencing trials remain separate and required.
