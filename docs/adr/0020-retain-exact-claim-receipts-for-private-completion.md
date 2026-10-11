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
