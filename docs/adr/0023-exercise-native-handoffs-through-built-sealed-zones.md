# 0023: Exercise native handoffs through built sealed zones

Status: accepted

The explicit disposable native trial runs the packaged Nakama/plugin against
fresh PostgreSQL and the built zone command against generated SDK sidecars.
The zone artifact uses the ordinary read-only server dependency graph and the
same static build settings as its runtime image. Its separately packaged digest
and native build information bind acceptance to the command being exercised.
The compatible native Nakama graph and its two-artifact manifest remain separate.

Each zone starts as a distinct GameServer, creates its own admission secret in
memory and publishes its identity-bound seal through the real Agones SDK.
The allocator fixture selects only observed Ready resources matching the native
client's Fleet and wrapping-key selectors. It patches the allocation locator into
both generated resource views. It never derives a zone secret or mints admission.

Acceptance authenticates through Nakama, consumes its actual handoff response
and opens the returned WebSocket-over-TLS endpoint. DNS routing maps only that
exact fixture endpoint to loopback; normal certificate-chain and hostname
verification remain active. The command calls Nakama's verified private claim
service before upgrade. Independent PostgreSQL readback proves the exact
system-owned claim and version precede a decoded observer snapshot.
The fixture sets interest to cover the bounded demo world, retaining a populated
snapshot control as its neighbours move during restart and rotation scenarios.
The native trial uses a two-minute lease with the ordinary 30-second handoff
token. Private claims authenticate the canonical token's own expiry, bounded
by the lease and by the claim operation's deadline. Exact lease-expiry equality
would incorrectly refuse these legitimate shorter tokens.

Ten process-boundary scenarios cover sealed readiness, authenticated replication,
commit-before-upgrade, workload identity, sibling isolation, SDK revision fencing,
restart protection, wrapping-key rotation, ambiguous allocation reconciliation
and shutdown ownership. Real database writes and generated resource lookups can
be held to observe ordering. A changed watch revision rejects the old in-flight
claim even after metadata restoration; a fresh valid observation can admit an
idempotent claim without changing its generation. Shutdown joins sockets and
admission before SDK Shutdown, without releasing durable claimed ownership.

The launcher requires all twenty-two named scenarios on both native Linux
architectures. It refuses an incomplete run, missing inputs or absent opt-in.
The movement scenario in ADR 0024 adds default-off negotiation, owner-applied
input and completed-tick acknowledgements without changing retained replication.
The image is unpublished and its network, database, credentials and process
fixtures are disposable. Fixture service-account access cannot certify production
workload credential isolation, RBAC, NetworkPolicy or certificate issuance.

Actual Agones/platform rollout, retained serving artifacts, irreversible
session-end authority and allocator-generation activation remain independent
acceptance gates under #569, #793, #1177 and #1192.
