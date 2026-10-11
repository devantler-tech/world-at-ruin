# Acknowledge original receipt custody before admission

Status: accepted for an inert source boundary, part of #1318; production custody
and launch enrollment remain #1336.

## Decision

Use a separate authenticated custodian for the original zone lifetime. Custody
inside a zone shares its death/restart failure. Nakama lease readback can
corroborate a document but cannot establish the provenance of an originating
acknowledgement or independently authenticate a surviving supervisor.

The source boundary is `zoneclaim.NewCustodiedReceiptGate`. Its config requires
`Enabled: true` and an injected `ReceiptCustodian`; disabled or missing dependencies
refuse construction. The normal zone command keeps its legacy gate. Construction
starts no listener, goroutine, storage operation or completion hook.

The gate latches uncertainty before its first private claim can be issued. It
passes only the actual validated originating receipt to `RetainOriginal`, once,
and exports neither admission nor a receipt while that operation is pending.
A successful custody acknowledgement and a still-live context clear the latch.
The allocation observation must still be current before admitting the player.
Acknowledged original custody survives a refused socket upgrade or reconnect.

A failed, malformed, lost or canceled initial claim/custody acknowledgement
leaves that gate permanently uncertain. Subsequent callers cannot replay the
claim, retry custody, reconstruct a receipt from a row or adopt a newer version.
Refusals before initial dispatch leave the unissued lifetime available. After
successful custody, each reconnect authenticates again and must match the
complete original receipt; it never republishes or refreshes custody.

`ReceiptCustodian` is an injected trust boundary, not a supplied production
implementation. Its acknowledgement must mean protected original custody under
independently established enrollment. It must honor the request context. The
gate bounds the complete custody-aware admission operation to thirty seconds,
including serialization, claim and custody, preserving any shorter caller deadline.
The gate must be retained for its entire allocation lifetime, never copied or
reconstructed after uncertainty. Independent enforcement of that lifetime across
processes and restarts belongs to launch enrollment, not this local latch.

## Exclusive launch and custody contract

Before launch, a trusted service reserves one create-only enrollment key derived
from the original namespace, lease object, attempt, allocation and GameServer UID.
Owner/incarnation strings are excluded from the key, so a competing supervisor or
same-UID replacement must contend for the same lifetime. Only the trusted launcher
creates the child incarnation and authenticates its binding to the exact owned
process. A UID, PID, self-reported string or visible record is insufficient.
Missing enrollment acknowledgement permits neither launch nor readback recovery.

The custodian needs an issuer-attested supervisor principal distinct from the
zone identity, scoped to original enrollment, originating receipt retention,
exact-owner termination publication and corresponding readback. It gets no
allocation replay, version refresh, lease reconstruction or arbitrary cleanup
authority. The production credential issuer and authenticated launcher are not
composed here; the existing isolated test CA proves fixture identity only.
The completion handler's zone mTLS principal is not a supervisor delegation.

Retain the complete receipt and original process binding immutably. Remote claim
commit followed by lost claim/custody acknowledgement retains ownership and
grants neither admission, completion nor relaunch. Later visible documents or
nonces cannot replace independently retained originating acknowledgement pins.
Changed receipts, competing owners and replacement incarnations never refresh
the frozen version.

## Termination, restart and rollback

The enrolled supervisor exclusively owns kill/join of its exact child. A durable
termination tombstone needs independent non-resumption evidence, acknowledged
publication and continuously excluded relaunch. Death before kill, between kill
and join, before publication, after remote commit but before ACK, or before
protected ACK retention remains unknown. Exact-child join cannot retract work
already accepted by a remote service.

Restart needs authenticated original custody and tombstone pins, exact immutable
readback and independently retained rollback-resistant evidence. Missing or
rolled-back custody/tombstones refuse completion and relaunch. A backend that
can roll back both a document and its sole witness cannot establish this fact.
An independent monotonic witness is an undelivered prerequisite; a database
snapshot or a digest is not a substitute.

Keep enrollment and tombstones through resumed cleanup and all serving/retained
reader horizons. Lease deletion, expiry and replica observations cannot retire
that fence. No compaction is authorized until its continuity and retention
conditions are specified and demonstrated.

## Evidence and delivery limits

Race controls exercise pending custody, canceled waiters, uncertain claim and
custody results, invalidated observations, reconnect authentication and changed
receipts. Real mutual-TLS integration controls observe the actual originating
claim response, private fixture storage remaining unchanged after custody
refusal, one claim request on uncertain paths and no completion/cleanup effect.
Fixture storage is not actual Nakama durability or a production custodian.

#1335 delivers only this source boundary. #1336 must select and establish the
actual identity issuer, authenticated exclusive launcher, protected durable ACK
custody and rollback-resistant witness before a native ownership experiment.
Kill/join plus continuously fenced tombstone completion is a later child.
#1318 and #567 remain open; schemas, production credentials, completion
composition and rollout remain outside this delivery.
