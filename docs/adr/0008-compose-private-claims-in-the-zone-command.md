# Compose private claims in the zone command

Status: proposed for #880, part of #569.

## Decision

The zone command exposes `-private-claims`, default off. Enabling it requires
TLS serving, the Agones lifecycle, sealed admission and a private HTTPS claim
endpoint with a dedicated trust root and workload client certificate. Partial
configuration, developer token minting and plaintext serving are refused before
SDK access. Disabled mode reads no claim credentials and constructs no client.

The command composes the existing SDK-observed claim binding, private mTLS client
and claimed socket hub. The player supplies only the existing bearer token.
The exact observed locator selects the private lease; a verified, durable claim
must complete before WebSocket upgrade. The observation is rechecked after the
private response. Refusals remain generic and never compensate by releasing a
potentially committed claim.

Certificate material is bounded and validated before readiness. Transport verifies
the endpoint hostname and server chain, presents the separate workload identity,
refuses redirects and bounds requests. Transport retirement follows the hub drain
so shutdown cancels admitted work before closing idle private connections.

## Activation boundary

This option is an integration surface, not production activation. The private
Nakama listener, credential issuance/rotation, session-end producer and restart
recovery, RBAC/network policy and cluster acceptance remain under #567/#569.
Allocator-generation commit fencing remains under #793. Neither a successful
claim nor socket shutdown proves allocator or zone process death. The default
developer path and every persisted/wire format remain unchanged.

Issue #881 tracks retiring this temporary rollout flag after the complete sealed
handoff has passed those activation gates.

The command regression runs the built executable with the real SDK and private
TLS transports, a sealed envelope and the real lease store/claim handler. It
checks durable ownership before the first snapshot and verifies refusal paths
without substituting a successful claim for storage evidence.
