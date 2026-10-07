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
