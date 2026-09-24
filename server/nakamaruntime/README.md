# Nakama handoff runtime

The Go plugin at `cmd/nakama` registers `war_handoff` over the real handoff
service, durable lease coordinator, Agones resource adapter and admission
keyring. It supervises no-show cleanup until Nakama invokes its shutdown hook.
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
mutual TLS and disables configured gRPC retries. Kubernetes uses in-cluster
credentials, a ten-second request timeout and refuses redirects. Its service
account needs namespaced GameServer get/list/delete only. Apply that restriction
in deployment RBAC; a Go interface is not an RBAC grant.

### Credential lifetime and rotation

Allocator CA trust, the client certificate/key pair and unwrap keys are loaded
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
succeed before the expiry goroutine starts. Initialization failures close
acquired clients. Shutdown refuses new RPCs, cancels active RPCs and the reconciler, waits within
the supplied shutdown context for the reconciler and every in-flight RPC to
return (including detached fence-and-cleanup work), and closes transports once. Storage clients must
honor their contexts. A forced process kill cannot run a hook; persisted leases
remain available to the next module's startup sweep.

The coordinator retains ambiguous dispatched attempts. This module supplies no
allocator-generation fence and does not interpret Pod disappearance as proof
of lost commit authority. The private zone claim endpoint, zone command claim
wiring, platform rollout, Google provisioning RPC and client integration remain
separate work. A returned handoff does not establish a deployed multiplayer path.

## Verification

Tests invoke the registered RPC over the real service, coordinator, lease store,
adapter and RSA envelope reader, replacing only external APIs. They check
persistence before response, retry replay without redispatch, refusal of a
client-chosen reservation, token
acceptance by the zone verifier, an existing observer, automatic no-show
reclamation, shutdown and secret absence. Separate tests send a real gRPC
request over verified mutual TLS and reject an untrusted allocator.
