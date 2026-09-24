# Authenticate private zone claims with an exact workload identity

Status: accepted for the default-off claim boundary (#873, part of #567).

## Context

The zone observes an opaque lease locator from its allocated GameServer and
verifies an allocation-scoped token before opening a socket. That observation
does not authorize a write to Nakama. No-show cleanup and admission must compete
on one exact lease version, without exposing the raw player or reservation ID.

## Decision

Provide an explicitly constructed private HTTPS handler and zone client. No
listener, public Nakama RPC or production command enables them by default.
The handler requires a verified mutual-TLS client chain and one URI SAN matching
`spiffe://<trust-domain>/zone/<namespace>/<gameserver-uid>`. Namespace and trust
domain are server configuration; the UID must also match the durable lease's
pinned GameServer reference. A role-wide certificate cannot claim arbitrary
zones. The URI is an identity, never a network destination.

This uses the [SPIFFE identity URI grammar](https://spiffe.io/docs/latest/spiffe-specs/spiffe-id/)
with a deployment-specific path. It does not implement or deploy SPIRE, a
Workload API, or an identity issuer. Deployment must attest the exact workload
before issuing its certificate, isolate its private key, and restrict the
private listener and CA trust. Shared Fleet credentials are insufficient.

After authenticating the workload, the handler strictly decodes a bounded
request, loads the private lease by its opaque object key, checks the exact
attempt digest/allocation/observer/UID, and resolves the pinned resource and
sealed envelope independently. The submitted token must equal the canonical
token for that lease's secret, allocation, observer and exact expiry. All
failures produce the same refusal without token or storage details.

The storage owner claims by exact version using the existing lease schema.
Replays reread the durable object; matching already-claimed records succeed.
A lost write acknowledgement triggers one bounded read, never another write.
Changed ownership, releasing/staging state, expiry or unavailable evidence
refuses admission. Cancellation after a committed claim does not release it.

The client uses verified HTTPS, a fixed endpoint and request deadline, rejects
redirects, and accepts only an empty successful response. It sends no raw player,
reservation or attempt identifier. The existing zone gate still rechecks its
observation after the private call and before socket admission.

## Consequences and delivery boundaries

Nakama's private collection and all shipped schema readers remain unchanged.
This boundary is inert until #569 composes it with the production runtime and
zone command. #567 must deliver fenced session-end recovery before activation:
claimed leases intentionally survive expiry and uncertain socket outcomes.
#12 must supply the issuer, verified transport, network restrictions, bounded
server timeouts, certificate rotation and process-level deployment evidence.
No runtime feature flag is removed or enabled by this library increment.

Allocator-generation fencing remains #793. An authenticated claim does not
resolve an ambiguous dispatch, prove process termination, or permit retries of
that dispatch. The quarantine policy is unchanged.

## Verification

Tests exercise actual mutual TLS, the real lease transition and zone socket
gate. Wrong workload identities and sibling tokens must leave storage unchanged.
Claim-versus-cleanup, changed pinned resources, lost acknowledgements, malformed
requests, cancellation and client redirects are explicit refusal cases. The
historical reader guard verifies every retained lease format after the new path.
