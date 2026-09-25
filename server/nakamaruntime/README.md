# Nakama handoff runtime

The Go plugin at `cmd/nakama` registers `war_handoff` over the real handoff
service, durable lease coordinator, Agones resource adapter and admission
keyring. It supervises no-show cleanup until Nakama invokes its shutdown hook.
An independent opt-in hosts the private claim handler over mutual TLS.
The module is **off by default**. No deployment manifest or client call enables it.

## Build and configure

Build the plugin in the **same Go toolchain and dependency environment as the
target Nakama server**, as required by Go's plugin ABI:

```sh
go build -buildmode=plugin -o /tmp/world_at_ruin.so ./cmd/nakama
```

Place the artifact in Nakama's runtime module directory. The platform must
provide a **positive `shutdown_grace_sec`**, sufficient for cancellation and
cleanup: Nakama does not invoke shutdown hooks when this setting is zero.
See [Nakama's Go runtime guide](https://heroiclabs.com/docs/nakama/server-framework/go-runtime/)
and [shutdown hook contract](https://heroiclabs.com/docs/nakama/server-framework/go-runtime/function-reference/#registershutdown).
This package does not deploy or reconfigure a running Nakama server.

Supply these values through **Nakama `runtime.env`**, exposed in the server's
initialization context. Process environment variables alone do not enable the
module. The platform may populate `runtime.env` from its environment or Secret
projection; private key bytes belong in mounted files.

| Setting | Contract |
| --- | --- |
| `WAR_HANDOFF_ENABLED` | Exactly `true` to enable; absent or `false` performs no I/O or registration. Other values fail startup. |
| `WAR_HANDOFF_ALLOCATOR_ADDRESS` | DNS hostname and nonzero port, e.g. `allocator.example:443`. No URL, IP literal, credentials or resolver override. The hostname is also the TLS server identity. |
| `WAR_HANDOFF_ALLOCATOR_CA_FILE` | Absolute path to the allocator's trusted PEM CA bundle. |
| `WAR_HANDOFF_ALLOCATOR_CERT_FILE` | Absolute path to the allocator client certificate chain. |
| `WAR_HANDOFF_ALLOCATOR_KEY_FILE` | Absolute path to its matching private key. |
| `WAR_HANDOFF_UNWRAP_KEYS` | JSON array of 1–8 distinct absolute PEM paths. The **first** is the current wrapping key; remaining keys retain old allocations across rotation. RSA keys are at least 3072 bits, PKCS#1 or PKCS#8. |
| `WAR_HANDOFF_NAMESPACE` | One Kubernetes namespace. |
| `WAR_HANDOFF_FLEET` | One Agones Fleet, at most 63 bytes. |
| `WAR_HANDOFF_TLS_PORT_NAME` | The Fleet's player-facing TLS port name. |
| `WAR_HANDOFF_ZONE_DOMAIN` | Managed DNS suffix, e.g. `zones.example`. |
| `WAR_HANDOFF_LEASE_TTL` | Go duration from `2s` to `10m`; typically `1m`. A handoff needs at least one second remaining after allocation. |
| `WAR_HANDOFF_RPC_TIMEOUT` | Optional deadline, `1s` to `1m`, default `30s`. A shorter caller deadline or session expiry wins. |

Enabled initialization rejects missing/malformed settings before connection or
registration. Material reads are capped at 1 MiB each. Invalid, expired or
mismatched TLS credentials and invalid/duplicate unwrap keys fail startup;
errors expose neither file contents nor paths. The allocator uses verified
mutual TLS and disables configured gRPC retries. Startup completes a verified
handshake with the allocator within ten seconds and fails otherwise, so a
credential the allocator rejects never reaches a player request. Kubernetes uses in-cluster
credentials, a ten-second request timeout and refuses redirects. Its service
account needs namespaced GameServer get/list/delete only. Apply that restriction
in deployment RBAC; a Go interface is not an RBAC grant.

### Credential lifetime and rotation

Allocator and private-listener CA trust, certificate/key pairs and unwrap keys are loaded
**once at initialization**. Updating mounted files does not reload them. Before
enabling this module, deployment must bound each pod's lifetime to end before
its client certificate expires, with time for shutdown and replacement. A CA or
client credential rotation requires a controlled restart before the old trust
or certificate stops working; use an overlap period that covers the rollout.
New allocator TLS connections fail after the loaded certificate expires, even
if valid replacements are already mounted. Restart scheduling and expiry
monitoring belong to deployment under #12. This package supplies neither an
expiry alert nor an automatic reload controller; mounting a Secret does not
provide either behavior.

Unwrap-key rotation also requires restarting with the new key first and the old
keys retained in `WAR_HANDOFF_UNWRAP_KEYS` for every still-live allocation.
Removing an old key while an allocation still needs it makes that allocation
unreadable. Persisted leases survive the controlled restart and are reconciled
by the replacement module.

## Private claim listener

With `WAR_HANDOFF_ENABLED=true`, the following independent settings enable the
private HTTPS listener. Without its opt-in, no listener file is read or socket
bound. The enclosing module's disabled state ignores these settings entirely.

| Setting | Contract |
| --- | --- |
| `WAR_HANDOFF_CLAIMS_ENABLED` | Exactly `true` to enable; absent or `false` keeps the listener off. |
| `WAR_HANDOFF_CLAIMS_ADDRESS` | Explicit IP and nonzero port, e.g. `127.0.0.1:7443`; no hostname or implicit wildcard. |
| `WAR_HANDOFF_CLAIMS_CERT_FILE` | Absolute PEM path to the server certificate chain with a DNS/IP identity and server-auth usage. |
| `WAR_HANDOFF_CLAIMS_KEY_FILE` | Absolute PEM path to the matching server private key. |
| `WAR_HANDOFF_CLAIMS_CA_FILE` | Absolute PEM path to dedicated workload client trust roots. These are separate from allocator trust. |
| `WAR_HANDOFF_CLAIMS_TRUST_DOMAIN` | Trust domain for the existing exact `spiffe://<domain>/zone/<namespace>/<uid>` workload identity. |

Each material file is capped at 1 MiB. The certificate must be currently valid.
Initialization reserves the socket before registering `war_handoff` and begins
serving only after shutdown registration succeeds. Every initialization failure
releases the listener and acquired transports. The listener is HTTPS only,
requires verified workload certificates and serves only the existing `/v1/claim`
contract. Claim and session-end operations are never registered as public RPCs.

The listener permits at most 64 connected clients, uses HTTP/1.1 without stream
multiplexing, sets an 8 KiB header limit (plus the HTTP server's framing allowance),
five-second header/read/write and claim deadlines, and a thirty-second idle
timeout. Claim bodies remain capped at 4096 bytes. The same lease store and pinned
Agones resolver used by allocation independently verify the claim and persist
ownership before success. Lost responses retain the claim for an exact replay.

The zone's `-claim-url` must use a hostname covered by the server certificate;
its `-claim-ca` trusts the private server and its separate workload certificate
chains to `WAR_HANDOFF_CLAIMS_CA_FILE`. A bind address does not establish private
network exposure: deployment must restrict reachability and issue attested
per-GameServer identities. No platform resource is changed by this option.
See [ADR 0009](../../docs/adr/0009-host-private-claims-in-the-nakama-runtime.md).

## RPC contract

Send a Nakama-authenticated RPC with an empty object:

```json
{}
```

Any property is rejected, and request size is limited to 4096 bytes. The
payload cannot select a user, session, observer, endpoint, attempt ID, key or
reservation. Server-key/anonymous RPCs are refused.

The server uses one fixed reservation key for every player, so each account
holds at most one live attempt. A retry replays or adopts that attempt, a
request while the player's zone is claimed is refused, and only an expired
attempt is replaced. A client-chosen key would let one account start a fresh
allocation per request and reserve every Ready GameServer.

`nakamaauth.RuntimeVerifier` uses Nakama's authenticated user/expiry context,
then checks that exact account still exists and is enabled. It accepts no
bearer credential in the payload. The existing gRPC session verifier remains
available for callers outside the runtime.

Success serializes exactly `handoff.Handoff`: `ServerName`, `Port`, `Token`,
and `ExpiresAt` (RFC 3339 timestamp). Only the allocated zone can verify the
short-lived token. Raw admission secrets, lease references and account IDs do
not enter the response. Failures use Nakama runtime errors with sanitized
messages and the service's gRPC status class. Cancellation, shutdown and
timeouts return no partial handoff. A lost response leaves the durable lease
for a retry or no-show cleanup.

## Observer and lifetime policy

This first composition allocates **one entire GameServer per player** and binds
observer **1**, an entity already present in the current zone command's
`sim.NewDemoWorld`. The hub refuses unknown or already-connected observers.
A user hash would mint an unusable entity ID. Shared-zone party/entity ownership
is a later protocol change, not something this module infers.

Initialization's context is detached after composition because its request
lifetime is not the module lifetime. RPC and shutdown registration must both
succeed before the expiry goroutine and optional private listener start. Initialization
failures close acquired clients. Shutdown cancels public and private admission,
closes the listener, and waits for the reconciler and every admitted handler
(including detached fence-and-cleanup work) within the earlier of the supplied
deadline or five seconds when the private listener is enabled, then closes transports once.
With the listener disabled, the supplied shutdown context bounds the drain. Remaining connections
are force-closed at the deadline. An unexpected private serving failure cancels
module admission, so new public handoffs are refused until runtime replacement. Storage clients must
honor their contexts. A forced process kill cannot run a hook; persisted leases
remain available to the next module's startup sweep.

The coordinator retains ambiguous dispatched attempts. This module supplies no
allocator-generation fence and does not interpret Pod disappearance as proof
of lost commit authority. Platform rollout, attested workload certificate issuance,
trusted session-end/restart recovery, Google provisioning RPC and client integration
remain separate work. A returned handoff does not establish a deployed multiplayer path.

## Verification

Tests invoke the registered RPC over the real service, coordinator, lease store,
adapter and RSA envelope reader, replacing only external APIs. They check
persistence before response, retry replay without redispatch, refusal of a
client-chosen reservation, token
acceptance by the zone verifier, an existing observer, automatic no-show
reclamation, shutdown and secret absence. Separate tests send a real gRPC
request over verified mutual TLS and reject an untrusted allocator.
Private-listener tests send real verified HTTPS claims through the runtime's
lease store and resource adapter, reject anonymous/untrusted peers, preserve
claims against no-show cleanup, exercise initialization rollback, and prove
connection bounds plus cancellation/drain before dependency retirement.
