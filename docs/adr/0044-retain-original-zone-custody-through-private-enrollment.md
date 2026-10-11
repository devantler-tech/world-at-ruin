# Retain original zone custody through private enrollment

Status: accepted for the inert source persistence boundary in #1338.
Authenticated launch and rollback-resistant custody remain #1336/#1318.

## Decision

`internal/zonecustody` requires explicit `Config.Enabled` and a storage client.
Construction validates the complete original allocation route and immutable
owner/child correlations without starting I/O, a listener or a child process.
The normal zone command and serving Nakama plugin do not import the owner.

One lifetime key hashes a domain-separated JSON encoding of namespace, lease
object ID, attempt digest, allocation ID and GameServer UID. Owner ID, child
incarnation, watch revision and storage version cannot change this key. Competing
owners and same-UID replacement incarnations therefore contend for the same
private system-owned enrollment document. Every write is create-only; there is
no update, takeover, deletion, expiry or compaction operation.

`Owner.Reserve` consumes its attempt before storage I/O. Copies share that
decision. Only one exact originating enrollment acknowledgement returns an
opaque live `Enrollment`. A committed write with a lost, malformed, partial or
canceled reply leaves exclusion data but no usable handle. A fresh owner cannot
adopt that data or retry through an existing enrollment.

The enrollment implements `zoneclaim.ReceiptCustodian`. Its one terminal
retention attempt requires a complete receipt matching the original route and
a valid observer, version and generation. The second private create-only
document binds the immutable enrollment, its original acknowledgement version
and the complete original claim receipt. Only its exact originating custody
acknowledgement exports detached pins. Both operations bound the entire attempt
to thirty seconds while preserving a shorter caller deadline.

`Read` has a storage-read-only interface. It compares both complete private
documents with independently retained original pins and versions under one
bounded read. Strict schema-1 readers reject missing, duplicate, null, foreign,
future or trailing fields at every object level. Readback and pins are diagnostics;
neither can construct an enrollment or grant launch/completion authority.
Both persisted families retain permanent goldens and registered executed readers.

## Trust and rollback limits

An owner or child correlation is not a credential or process attestation. A
process-local opaque handle does not authenticate a supervisor, establish
exclusive launch, protect acknowledgements across death or resist database
rollback. Private Nakama permissions prevent ordinary client access; they cannot
stop a privileged server or restored database from erasing both documents.
This boundary must not authorize production launch, recovery or completion.

The current zone starts before its allocated lease/attempt route exists. A
production launch contract keyed by that route needs a separately selected
bootstrap/gameplay-child boundary, rather than declaring the running bootstrap
process exclusively enrolled. Independently attested supervisor/custodian
principals, an exact owned child handle and independently protected monotonic
acknowledgement custody remain required before a native ownership experiment.
No deployment or shared credential change is introduced here.

Receipt retention acknowledges storage only. `NewCustodiedReceiptGate` still
requires authentication of every admission and a current allocation observation;
reconnects never republish custody or refresh the original receipt. Irreversible
termination, continuous launch exclusion, tombstone publication and recovery
through cleanup remain separate #1318/#567 delivery gates.

## Evidence

Race controls exercise competing owners, copies, pending writes, cancellation,
malformed/lost/partial acknowledgements and immutable receipt identity. Actual
mutual-TLS integration passes the originating claim into this owner and verifies
that a committed custody row with a lost reply leaves admission refused and the
claimed lease unchanged. These storage fixtures prove the source protocol,
not native Nakama durability, authenticated launcher ownership or rollback safety.
