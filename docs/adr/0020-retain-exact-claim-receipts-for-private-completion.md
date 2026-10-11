# Retain exact claim receipts for private completion

Status: accepted for inert source boundaries, part of #567.

## Decision

The private claim handler offers an additive `/v2/claim` route. It returns the
original durable claim's version and nanosecond generation with its exact lease,
attempt, allocation, workload UID, namespace and observer. `/v1/claim` retains its
empty 204 response. The receipt contains no secret or player identifier and is
neither authentication nor proof that the session ended. Receipt-aware admission
retains the first receipt for the allocation lifetime, including failed socket
upgrades and reconnects. A changed receipt refuses admission rather than adopting
a new cleanup target.

The separately constructed `/v1/session/end` handler requires a verified,
currently valid mutual-TLS zone workload identity matching the original UID and
namespace. It additionally requires a server-injected `SessionEndVerifier` to
independently prove termination of that exact original receipt. The verifier must
establish that the old process cannot resume its authority and keep that fence
effective throughout cleanup; an observation that can become false is insufficient.
It must not infer completion from the request, receipt possession, socket drain,
elapsed time, Pod absence or replica count. Missing, denied, uncertain or canceled
verification authorizes no storage mutation or resource deletion.

After verification, the storage owner's existing `EndSession` consumes the
original version/generation, persists and reads back `releasing`, then calls
UID-pinned cleanup and deletes only the exact barrier version. Neither a verifier
nor a retry may refresh the receipt from current storage. Failed cleanup leaves
the durable barrier for the existing reconciler. Old completion cannot target a
replacement lease or GameServer. The completion client sends one bounded request,
follows no redirects and performs no automatic destructive retry.

## Boundaries

Construction opens no listener and registers no public RPC. Production runtime
composition and normal shutdown hooks do not call this completion boundary.
The independent termination verifier has no production implementation: #567,
#569 and #793 retain process-authority, workload issuance, allocator fencing,
rollout and real-cluster acceptance. Storage schemas and writer capabilities are
unchanged. These source interfaces do not authorize deployment or activation.

## Native process-death controls

Original receipt custody has a separately enabled source boundary in
[ADR 0043](0043-acknowledge-original-receipt-custody-before-admission.md).
It withholds admission and receipt export until originating custody is
acknowledged, and refuses every retry after an ambiguous initial claim/custody
outcome. It supplies no production custodian, exclusive launch enrollment,
supervisor authentication or termination verifier; #1336 owns those prerequisites.

The explicit native trial exercises the built zone, native Nakama and disposable
PostgreSQL in `TestClosedLoopClaimAfterZoneDeath` and
`TestClosedLoopAcknowledgedZoneDeath` (#1330). The first control holds the actual
claim transaction, observes its PostgreSQL waiter, kills and joins the exact
owned zone, and observes ordinary disconnect cancellation. Its separate delayed
disconnect control forwards the original mutual-TLS ciphertext unchanged and
keeps the already authenticated backend connection until its bounded deadline.
Releasing the transaction after child join must commit the original claim while
no living zone can acknowledge it. The row remains private, keeps its original
allocation binding and gains a new claim version; readback is diagnostic only.

Both a late unacknowledged claim and a previously acknowledged claim must survive
native Nakama restart, repeated public handoff refusal and real expiry cleanup
of an unclaimed canary. Claimed ownership must remain byte/version identical,
with its exact resource retained and no allocation redispatch. The native runner
requires both controls on amd64 and arm64, with explicit verdicts and owned child,
listener and transport-worker cleanup.

Delayed disconnect is an explicit network fault model, not a claim that an
ordinary direct connection necessarily commits after death. The built zone uses
legacy `/v1/claim`; the experiment captures no original completion receipt and
constructs none from a visible row. It neither calls nor composes completion.
This evidence distinguishes process exit from outstanding remote work. It does
not establish authenticated independent supervisor authority, protected durable
receipt custody, a termination tombstone, exclusive relaunch ownership or their
restart/rollback behavior. Those remain open decision gates under #1318.

## Native watch-loss and resumption control

`TestClosedLoopMovementAfterWatchLoss` (#1332) exercises the explicitly enabled
v3 movement fixture with one input hold tick. It establishes a stationary
sequence-zero baseline on the real claimed socket, SIGSTOPs the exact owned
child, observes its stopped state through Linux procfs, ends the generated SDK
watch while retaining health, and SIGCONTs the same child. Repeated fresh
admission must return exactly HTTP 401 before the original handoff expires.
A never-used sequence sent after resumption on the established socket must
produce its exact applied-sequence ACK, a newer tick and bounded position change.
Buffered pre-suspension ACKs cannot contain that sequence. Later ticks must stop
at the applied position after the single hold tick.

The original private claim remains byte/version identical, with no new private
TCP connection. Connection counts do not establish an absence of private RPCs
on an existing TLS connection. Mutual TLS is unchanged, and no storage write,
claim acknowledgement or completion receipt is manufactured. One bounded reader
spans suspension and is canceled, closed and joined during cleanup. The native
fixture resumes stopped children before cooperative shutdown and bounds the
kill/join fallback. The successful control ends with exact-child SIGKILL and join.

This is watch-loss evidence, never demonstrated Pod or node deletion. Fresh
admission and existing session authority have separate paths; an unavailable
watch cannot establish irreversible loss of movement authority. The experiment
requires actual success on both native Linux architectures under the existing
non-root, capability-dropped trial. Missing visibility, signal permission or
bounded joins fails closed. It neither composes completion nor establishes
durable termination tombstones, independent production authority, protected
original-receipt custody or exclusive relaunch fencing. #1318 remains open.
