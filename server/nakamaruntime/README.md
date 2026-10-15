# Nakama handoff runtime

The Go plugin at `cmd/nakama` registers `war_handoff` over the real handoff
service, durable lease coordinator, Agones resource adapter and admission
keyring. It supervises no-show cleanup until Nakama invokes its shutdown hook.
An independent opt-in hosts the private claim handler over mutual TLS.
Another independent opt-in supervises orphan cleanup after complete resource
and private lease observations.
The module is **off by default**. No deployment manifest or client call enables it.

## Native original-custody persistence experiment

The explicitly built `war_native_trial` bundle alone composes the individually
default-off `WAR_ZONE_CUSTODY_PROBE_ENABLED` startup experiment. Normal plugins
and zone commands do not import it. `true` requires one named scenario, bounded
complete diagnostic input and the disposable supervisor's literal loopback
control endpoint. `read` instead requires complete independently retained storage
pins and performs no writes. Absent/`false` ignores malformed dependencies; other
enablement values fail startup.

`TestNativeZoneCustodyDefaultOff`, `TestNativeZoneCustodyPersistence`,
`TestNativeZoneCustodyCrashCuts`, `TestNativeZoneCustodyCompetingProcesses` and
`TestNativeZoneCustodyReaderRefusals` are mandatory on both native architectures.
They inspect actual PostgreSQL effects separately from originating Nakama ACKs
and diagnostic pins delivered before exact source kill/join. Independent same-key
writers, same/changed-owner restart, ambiguous/canceled replies, private public-API
isolation and faulty fresh readers must never replace the original documents.

The default lifetime/receipt inputs are diagnostic fixtures. The explicitly
selected `WAR_ZONE_CUSTODY_PROBE_RECEIPT_SOURCE=control` mode instead supplies only
`Binding`, `Observer`, `OwnerID` and `ChildIncarnation` and obtains one complete
actual private claim response from the disposable controller after originating
enrollment acceptance. Its original enrollment process persists that unchanged
receipt and exports pins only after its originating custody ACK. The controller
uses verified fixture-CA TLS; receipt forwarding is bounded literal-loopback test
coordination, not an authenticated production custody path.

`TestNativeOriginalClaimCustody` is additionally mandatory on both architectures.
It joins the actual native private claim to native custody, independently checks
the full receipt and storage versions against PostgreSQL, and holds the committed
enrollment before its ACK to require zero claim calls. Lost/canceled storage ACKs,
lost or changed forwarded responses, source death and rejected pin delivery keep
uncertainty terminal. Same-correlation and changed-child restarts cannot retrieve
the receipt or reconstruct the original enrollment from visible rows.

Neither mode authenticates a supervisor, launches a child or establishes
independently protected production custody/rollback resistance.
Even successful fresh readback returns diagnostics only. See ADR 0045 and #1342;
authenticated original launch remains #1340, witness prerequisites #1341/#1336,
and completion #1318/#567. The receipt join is specified by ADR 0050/#1371; full
authenticated original-child composition remains #1346. The native bundle remains
unpublished and retirement is tracked in #1192. No production infrastructure or
credentials are configured.

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
| `WAR_HANDOFF_TOKEN_TTL` | Optional signed handoff lifetime from `1s` to `5m`, default `30s`. It cannot extend the durable lease. |
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

Each material file is capped at 1 MiB, and a PEM bundle whose remainder is not
whitespace, such as a truncated block, is refused. The server chain must be served
in order, each certificate issued by the next, and every certificate must be
currently valid. Claims material shares no key with allocator roots or
certificates in either direction, and the server key is not a workload root.
Initialization reserves the socket before registering `war_handoff` and begins
serving only after shutdown registration succeeds. Every initialization failure
releases the listener and acquired transports. The listener is HTTPS only,
requires verified workload certificates and serves `/v1/claim` (empty admission
acknowledgement) and `/v2/claim` (the original durable claim receipt). The zone
command uses v1; receipt-aware admission requires explicit source composition.
The separately constructed session-end handler is not registered on this listener
or on a public RPC. It requires independent, irreversible termination authority
as well as verified workload identity; no production verifier is supplied. See
[ADR 0020](../../docs/adr/0020-retain-exact-claim-receipts-for-private-completion.md).

The listener permits at most 64 connected clients, uses HTTP/1.1 without stream
multiplexing, sets an 8 KiB header limit (plus the HTTP server's framing allowance),
and five-second header/read/write and claim deadlines. It closes each connection
after its response, so idle zone clients never hold one of the 64 slots. Claim
bodies remain capped at 4096 bytes. The same lease store and pinned
Agones resolver used by allocation independently verify the claim and persist
ownership before success. Lost responses retain the claim for an exact replay.
The canonical signed token may expire before its durable lease (the handoff
service defaults to 30 seconds). Claims verify its exact allocation and observer,
refuse expiry beyond the lease, and bound claim completion by the token's own
expiry. A shorter token never changes the stored lease window.

The zone's `-claim-url` must use a hostname covered by the server certificate;
its `-claim-ca` trusts the private server and its separate workload certificate
chains to `WAR_HANDOFF_CLAIMS_CA_FILE`. A bind address does not establish private
network exposure: deployment must restrict reachability and issue attested
per-GameServer identities. No platform resource is changed by this option.
See [ADR 0009](../../docs/adr/0009-host-private-claims-in-the-nakama-runtime.md).

### Static material initialization

`InitializeWithClaimsMaterial(ctx, logger, nk, initializer, material)` explicitly
selects a static `ClaimsTLSMaterial` snapshot. `Initialize` and
`InitializeWithLogger` keep projected-file behavior. No current plugin entry
selects material mode. Both `WAR_HANDOFF_ENABLED=true` and
`WAR_HANDOFF_CLAIMS_ENABLED=true` are required for its private listener; disabled
paths ignore even malformed supplied material.

| Material field | Contract |
| --- | --- |
| `CertificateChainDER` | Leaf first, then its ordered issuers; one to eight certificates. |
| `Signer` | Matching signing handle retained by the initializing process for the runtime lifetime. |
| `ClientAuthoritiesDER` | One to 32 inspectable client-authority certificates; no opaque root pool. |
| `ExpectedServerDNS` | Independently pinned exact DNS SAN; wildcard-only matches and IP substitutions are refused. |
| `ExpectedServerURI` | Independently pinned canonical SPIFFE URI in the configured claims trust domain; exactly one leaf URI must match. Path segments use letters, digits, dots, dashes and underscores; legacy charset mode is refused. |

Each DER certificate is at most 64 KiB, and both groups together are at most
256 KiB. The runtime clones and reparses the bytes before verifying validity,
signatures, purposes, signer equality and the server's anchored chain. It checks
all supplied authority/chain keys against allocator roots/leaves, and the server
leaf against issuer keys. The fixed TLS policy requires verified client
certificates, TLS 1.2 or later and HTTP/1.1. Caller TLS configuration or
verification callbacks are not accepted.

Material mode ignores the three claims credential-file settings and never falls
back to them on a missing/invalid snapshot. Existing address, trust-domain,
allocator and unwrap-key configuration still applies. Listener preparation,
registration rollback, request/connection limits and actual shutdown drain use
the same runtime owner as projected initialization.

Keep input buffers and slice headers stable until initialization returns. Later
DER mutation or replacing the input signer field cannot replace the retained
configuration. The signer object itself cannot be cloned: underlying
key mutation can cause handshake refusal, and the caller must retain its valid
handle until owned shutdown completes. There is no credential watcher, refresh,
rotation or revocation guarantee in this entry.

The verified-TLS tests exercise complete claim receipts with fixture storage and
refusal/rollback/drain controls. This does not establish successful WorkloadAPI
issuance inside Nakama, process attestation/key ownership, native PostgreSQL
custody, role-private controller cleanup, protected forwarding, gameplay admission
or rollback-resistant recovery. Those remain #1374/#1346; retirement remains
#1192. See [ADR 0052](../../docs/adr/0052-accept-inspectable-claims-material-under-one-runtime-owner.md).

## Orphan supervision

With `WAR_HANDOFF_ENABLED=true`, these runtime.env settings enable the existing
orphan reconciler. Absent or disabled opt-in performs no orphan scan; other orphan
settings are ignored. The enclosing module's disabled state ignores all of them.

| Setting | Contract |
| --- | --- |
| `WAR_HANDOFF_ORPHANS_ENABLED` | Exactly `true` to enable; absent or `false` keeps cleanup off. Other values fail startup. |
| `WAR_HANDOFF_ORPHANS_GRACE` | Optional Go duration, `30s`–`1h`, default `2m`. At least two complete observations and the full grace precede deletion. |
| `WAR_HANDOFF_ORPHANS_INTERVAL` | Optional Go duration, `1s`–`1h`, default `30s`. Startup sweeps immediately; subsequent sweeps are serial. |
| `WAR_HANDOFF_ORPHANS_TIMEOUT` | Optional Go duration, `1ms`–`1m`, default `30s`. Bounds the whole resource/lease/cleanup sweep; the existing Kubernetes request timeout may be shorter. |
| `WAR_HANDOFF_ORPHANS_MAX_PAGES` | Optional canonical decimal integer, `1`–`1000`, default `100`. Each resource and private lease scan has this page budget, with 100 objects per page. |

Malformed enabled settings fail before connection or registration. Namespace and
Fleet come from the existing handoff configuration; there is no second cleanup
scope, credential surface or lease store. GameServer enumeration completes before
the private lease scan. Any extant attempt protects its resources, including
expired, staging, dispatched, claimed, releasing and reader-only leases. Only the
coordinator may retire a lease through its existing barriers. Malformed, partial,
inconsistent, timed-out or over-budget observations authorize no delete and
discard earlier grace history. A restart also starts with fresh history.

Cleanup excludes Ready pool members and resources without attempt labels. A
fresh read must retain namespace, Fleet, attempt, Allocated state and exact UID;
deletion also requires UID and resource-version preconditions. A lost delete
acknowledgement is observed once and retried on a later complete sweep if still
unresolved. Transient failures do not stop the periodic worker.

The native plugin forwards its Nakama logger for aggregate observations: one
fixed outcome and scanned/waiting/protected/deleted/changed/failed counts per
sweep. Raw provider errors, identities, paths and lease contents never enter
these records. Legacy callers of `Initialize` may omit logging; use
`InitializeWithLogger` to supply it.

This option supplies source composition. It does not activate a deployed module,
grant RBAC, add allocator fencing or establish session-end authority. Production
artifact/cluster proof and flag retirement remain tracked by #1177. See
[ADR 0021](../../docs/adr/0021-supervise-orphan-cleanup-in-the-nakama-runtime.md).

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
succeed before the expiry/orphan workers and optional private listener start. Initialization
failures close acquired clients. Shutdown cancels public and private admission,
closes the listener, and waits for both workers and every admitted handler
(including detached fence-and-cleanup work) within the earlier of the supplied
deadline or five seconds when the private listener is enabled. Transports close
exactly once after both workers and every handler actually return. If the hook's
deadline expires first, retirement continues asynchronously after the drain;
a timeout never permits closing a transport underneath ongoing work.
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
Orphan tests compose the real private store and generated Agones HTTP client,
exercise elapsed grace, restart and failed-observation history, retained lease
fixtures, scoped lists, UID/resource-version deletes, resource replacement and
lost delete acknowledgements. Held-worker tests prove a shutdown deadline cannot
retire dependencies early.

## Experimental native Nakama acceptance

The native bundle uses the separate generated locks `server/nakama-runtime/go.mod`
and `server/nakama-runtime/go.sum`, aligned with Nakama 3.40's runtime API 1.47.
It leaves the ordinary server dependency graph intact. From `server/`:

```sh
go run ../tools/nakama-runtime-build/main.go ../tools/nakama-runtime-build/build.go \
  -experimental -source . -output /tmp/new-war-native-bundle
```

The output must be absent. The builder selects the exact Go 1.27.2 toolchain,
native CGO and compatible flags for both the Nakama binary and WAR plugin; its
`bundle.json` records actual graph and artifact hashes. This command builds a
trial artifact and does not publish or deploy it.

The separate acceptance image is built from the repository root and never
published by CI:

```sh
docker build -f server/Dockerfile.nakama-native --build-arg EXPERIMENTAL=true \
  -t world-at-ruin-nakama-native:trial .
bash tools/smoke-nakama-native.sh world-at-ruin-nakama-native:trial --experimental
```

The image refuses a default invocation. Every named mandatory scenario uses
the real loaded plugin, authentication and PostgreSQL-backed private storage.
The closed-loop scenarios run the built sealed zone command through generated SDK sidecars,
consume the authenticated handoff and decode a real TLS WebSocket snapshot.
The command uses its own random admission secret; fixture-side minting is absent
from this closed-loop path. Normal TLS chain and hostname verification remain
active while only the exact fixture DNS endpoint routes to loopback.
Held native storage writes and generated resource lookups expose claim-before-upgrade
and shutdown ordering. Workload identity, sibling isolation, changed SDK revisions,
restart cleanup, wrapping-key rotation and ambiguous allocation replies each have
negative controls. The image supplies only disposable fixture
credentials; the script publishes no ports and removes its own containers and
network. Linux amd64 and arm64 CI both execute the packaged runtime. Missing
trial inputs fail; the `war_native_trial` build tag selects this explicit process
suite separately from ordinary unit tests.

The movement scenario additionally proves default-off v3 refusal, explicit
negotiation, increasing applied-sequence acknowledgements, server-bounded ground
movement, expiry, malformed-input refusal and reconnect without inherited input.
It reads back the same durable claim before and after movement and keeps normal
TLS verification. The shipping Godot client remains on v2; this is a server
capability trial, not player input/prediction delivery or production activation.

The watch-loss control observes the exact child stopped through Linux procfs,
ends its generated SDK watch and resumes it. Fresh sockets must receive repeated
HTTP 401 before token expiry while SDK health remains active. A new sequence sent
after resumption must move the established v3 socket at a newer applied tick.
The exact private claim bytes/version and private TCP connection count remain
unchanged; connection counts do not prove an absence of RPCs on existing TLS.
One bounded reader spans suspension, and cleanup resumes the child before bounded
cooperative shutdown or kill/join. The control ends by killing and joining the
exact child. This demonstrates watch loss, not Pod/node deletion, original receipt
custody or irreversible production session termination. See ADR 0020 and #1318.

Lock maintenance is deliberate: use Go's alternate-module commands to resolve
both `github.com/heroiclabs/nakama/v3` and `./cmd/nakama`, plus the tagged native
trial package, and run `go mod download -modfile=nakama-runtime/go.mod` to retain
checksums for every selected platform dependency. Never edit generated sums or
substitute the ordinary graph for the full runtime graph. The container build
checks that dependency download leaves both lock files byte-identical and scans
the full native server/plugin for reachable vulnerabilities.

### Identity SDK runtime compatibility

The fixed `issued` profile uses the separate nested module
`server/nakama-issued-runtime`, Nakama 3.41/runtime API 1.48, SPIFFE SDK 2.9.0
and gRPC 1.84. Its Go-generated locks include the complete binary/plugin union;
the local server replacement also contributes its own recorded lock hashes.
The builder requires SDK presence in the actual compiled plugin. From `server/`:

```sh
go run ../tools/nakama-runtime-build/main.go ../tools/nakama-runtime-build/build.go \
  -experimental -profile issued -source . -output /tmp/new-war-issued-bundle
```

To exercise the distinct unpublished image from the repository root:

```sh
docker build -f server/Dockerfile.nakama-native --build-arg EXPERIMENTAL=true \
  --build-arg RUNTIME_PROFILE=issued -t world-at-ruin-nakama-issued:trial .
bash tools/smoke-nakama-native.sh world-at-ruin-nakama-issued:trial --experimental --issued
```

Both native architectures run the complete 41-scenario storage suite, plus
the SDK startup boundary. Its separate entry has a default-off diagnostic
`WAR_ISSUED_SDK_PROBE_ENABLED` flag. Absent/false ignores malformed socket
settings. With `true`, `WAR_ISSUED_SDK_PROBE_SOCKET` names an absolute Unix
socket; a real request runs within three seconds before shared initialization.
Unavailable issuers refuse startup with a sanitized verdict, without provider
effects or a private claim listener. Even successful fetches grant no serving
authority. Ordinary plugin artifacts contain no identity SDK.

This is runtime compatibility and unavailable-issuer proof. It does not prove
successful SPIRE issuance or the combined original custody path.

### Static WorkloadAPI claims entry

Only the distinct issued plugin can select `WAR_ISSUED_CLAIMS_ENABLED=true`.
It also requires `WAR_HANDOFF_ENABLED=true` and
`WAR_HANDOFF_CLAIMS_ENABLED=true`. Set these explicit runtime environment values:

| Setting | Meaning |
|---|---|
| `WAR_ISSUED_CLAIMS_SOCKET` | Canonical absolute local Unix socket path, at most 100 bytes; no percent encoding, query, fragment or ambient endpoint fallback. |
| `WAR_ISSUED_CLAIMS_SERVER_DNS` | Independently pinned exact server DNS SAN; no IP or wildcard. |
| `WAR_ISSUED_CLAIMS_SERVER_URI` | Independently pinned exact SPIFFE server URI in `WAR_HANDOFF_CLAIMS_TRUST_DOMAIN`. |

Disabled mode ignores these settings and keeps the projected-file path. Invalid
enablement, missing existing opt-ins and simultaneous SDK diagnostic enablement
refuse startup. Enabled mode makes one real SDK request with a three-second
deadline and 256 KiB message limit. Exactly one parsed SVID and its pinned-domain
bundle are required. The SDK transport closes before runtime initialization.
The retained signer and cloned certificate DER select ADR 0052's fixed listener,
including independent chain/key/purpose/identity and allocator-separation checks.
The three projected claims credential-file settings are ignored in this mode.
There is no refresh, adoption or projected-credential fallback: expiration needs
a controlled process restart, and runtime shutdown owns the listener and drain.

Both issued native architectures require the actual loaded plugin's positive
private mTLS claim, independent PostgreSQL receipt/version/generation readback,
unchanged original replay, startup/client refusal controls, SDK stream retirement
and listener shutdown. Its WorkloadAPI fixture is synthetic and transfers fixture
key bytes; it proves SDK-to-native-serving integration, not actual SPIRE issuance,
distinct workload roles or process-exclusive keys. #1374 retains real issuance
and original custody; #1346 retains protected forwarding and gameplay admission.
#1387 delivers this prerequisite and #1192 owns switch retirement. See ADR 0053.
Those outcomes remain #1374; protected forwarding, gameplay admission and the
independent rollback witness remain #1346/#1341. Experimental retirement is #1192.
See ADR 0051 for the artifact and authority boundaries.

The distinct `issued-spire` acceptance profile uses the same issued runtime
locks with pinned real SPIRE Server/Agent binaries. Build with
`RUNTIME_PROFILE=issued-spire`, then run the disposable wrapper with
`--experimental --spire`. Both Linux architectures require this combined proof.
A separate controller uses only SETUID/SETGID/KILL. Its unprivileged native
fixture worker owns Nakama startup, PostgreSQL state and child retirement;
the plugin obtains its own static credential. After the actual handoff, a
distinct zone UID receives an exact-allocation registration and fetches its
own credential. Ordinary chain/DNS verification and exact server URI checks
apply to the real private claim. Refusals preserve SQL state, and complete
receipt/replay checks compare independently read native versions/generation.
Cleanup requires both the native-child acknowledgement and exact worker joins.
No workload key crosses the private coordination pipes. See ADR 0054.

The same profile separately requires the nine originating enrollment/receipt/
custody cuts, each with a fresh issuer and database. The zone is registered from
the actual handoff and ready before original enrollment. Only the original
receipt GET triggers its sole real zone claim; the entire actual response is
forwarded before the declared loss/change cut. SQL readback verifies the complete
receipt, committed rows and accepted pins independently. Every original,
successful reader and refused restart process fetches its own credential with
projected claims files absent. Their constant `ISSUED CLAIMS SNAPSHOT FETCHED`
marker means snapshot selection only, before the later full listener validation.
The original coordinator joins health and captured snapshot output within one
existing startup window: HTTP readiness alone does not drain child stdout.
Failures report a fixed milestone and allow-listed startup condition, refusal
class and snapshot count without publishing the private child log. Classification
requires one exact structured fatal record; malformed, duplicate-key, oversized
or ambiguous output stays unclassified. The controller revalidates every new
field before public output. A WorkloadAPI refusal identifies the failed request,
not its underlying cause; a listening issuer socket alone does not prove usable
credentials. Before the original main launches, a disposable same-UID helper
waits for that exact role, closes its SDK, emits one fixed verdict and exits.
The bridge joins it before starting main and receives no credential material;
the helper has no database credential. Prerequisite, HTTP health and captured
snapshot all consume the original twenty-second startup window. Main still
performs its own single three-second fetch; a prerequisite cannot substitute
its snapshot, retry a failed main or grant original custody/serving authority.
Peers use a distinct claims address and are joined before reuse. Both fresh
same-correlation and replacement processes must refuse enrollment after their
own successful snapshot fetch, with no further GET, claim or provider effects.

The private protocol has one owner, case/sequence/operation correlation and a
five-second receipt bridge containing the existing three-second RPC. Original
HTTP/probe/stage bounds and the six-minute profile budget are unchanged. The
wrapper requires both top-level tests and every custody-cut verdict. Completion
follows the inner fixture cleanup and database retirement. See ADR 0055.
Controller forwarding remains diagnostic. Protected forwarding and gameplay
admission remain #1346; the independent witness remains #1341. No production
activation or same-role adoption is authorized.

The manual `Issued native startup stability` workflow measures ten fresh complete
issued-SPIRE trials on each native architecture. Dispatch it from `main` with
`gh workflow run issued-native-stability.yaml --ref main -f confirmation=measure-issued-startup`.
It binds the full source SHA, run ID and attempt before checkout, then builds one
local immutable image per architecture. Every trial creates and retires its own
database, network and issuer processes; only image bytes are shared within the job.
The measurement stops on the first failed or incomplete observation, including a
printed pass followed by failed cleanup. It is not a retry-to-green path.
Only ten successful joined wrappers produce an architecture completion receipt;
both architecture jobs must succeed for complete measurement. Source/image drift,
missing prerequisite observations and failed reads refuse completion.
The normal CI matrix, six-minute profile and twenty-second startup limits remain
unchanged. The manual job retains a twenty-five-minute cap and bounds its ten-trial
step to fifteen minutes; exhausting either budget is incomplete evidence. These
samples describe only the measured source and images, not every historical cause
or production serving authority. No reusable runtime archive is published.

These disposable checks establish behavior of the identified candidate artifacts.
They do not establish adoption by production serving artifacts or compatibility of
the actual retained rollback artifact. Production serving artifacts,
rollout, attested credentials and the existing authority/fencing gates remain
under #569 and #1177. Experimental build retirement is tracked by #1192. See
[ADR 0022](../../docs/adr/0022-prove-the-native-nakama-runtime-with-disposable-storage.md) and
[ADR 0023](../../docs/adr/0023-exercise-native-handoffs-through-built-sealed-zones.md) and
[ADR 0024](../../docs/adr/0024-negotiate-authoritative-movement-on-opt-in-zone-sockets.md).


## Default-off journal observation

The packaged plugin has a read-only startup observation for the inactive
allocator grant journal. It does nothing when
`WAR_ALLOCATOR_JOURNAL_PROBE_ENABLED` is absent or `false`, even if its
subsettings are malformed. Explicit `true` requires
`WAR_ALLOCATOR_JOURNAL_PROBE_BINDING` in Nakama's `runtime.env`: a JSON
encoding of the independently pinned journal binding (generation identity and
source version, canonical membership and digest, incarnation, namespace, Fleet,
complete issued count/digest and exact journal object version). Expectations
never come from the stored row. Reads have a five-second deadline.

A complete private read logs only its grant count and full-observation SHA-256.
An invalid, missing, conflicting, incomplete or canceled read prevents startup
with a generic unknown observation and no partial report or provider details.
The explicit `WAR_ALLOCATOR_JOURNAL_PROBE_CANCEL_READ=true` fixture control
cancels that read before dispatch; it does not cancel the parent initialization
context. It is absent in normal invocation.

Three required native scenarios use the same candidate binary and plugin,
verify their bundle hashes and architecture, and separately prove default-off
startup, complete zero/one/two-grant observations, and eleven unknown controls.
Fixture writes happen only in fresh disposable PostgreSQL setup. Reads leave
object bytes, version and privacy unchanged and make no allocation requests.
This journal observation introduces no journal writer, allocation capability,
receipt, admission closure, barrier or quarantine authority. Existing generation
and lease compatibility trials remain mandatory.

This is candidate-reader evidence for #1293. Every serving reader and the
actual retained rollback artifact still require compatibility proof before
future journal writers or recovery are activated under #793/#569. See
[ADR 0035](../../docs/adr/0035-observe-journals-through-the-packaged-nakama-candidate.md).

## Disposable durable admission experiment

The explicitly experimental native bundle additionally compiles the
`war_native_trial` admission startup experiment. Normal runtime plugin builds
do not import the admission writer or expose an activation path. In the trial
bundle, `WAR_ALLOCATOR_ADMISSION_PROBE_ENABLED` must be `true`; absent or `false`
returns before dependency or subsetting validation and performs no reads or writes.

`WAR_ALLOCATOR_ADMISSION_PROBE_JOURNAL` supplies an empty strict schema-1 journal,
and `WAR_ALLOCATOR_ADMISSION_PROBE_GRANT` supplies one frozen grant as JSON.
`WAR_ALLOCATOR_ADMISSION_PROBE_SCENARIO` is one of `sequence`, `incarnation-race`,
`drain-race`, or `lost-ack`. A five-second bound covers all operations. The
experiment publishes a private generation-scoped admission root through the
actual runtime StorageWrite API; it never seeds that row through SQL.

Registration and irreversible open-to-draining closure compete on the same
exact storage version. Concurrent incarnations compete on the same create-only
key. The lost-reply control discards the acknowledgment after the native
transaction commits. Stale or uncertain transitions return no snapshot and
never retry or refresh a version. Race and lost-reply reports explicitly retain
an unknown outcome; a persisted diagnostic record is not recovered authority.

Two required native scenarios cover disabled startup and all four enabled
controls on Linux amd64 and arm64. Database readback independently checks the
private row, immutable generation binding and complete inventory. No public RPC,
GameServer request, capability or receipt is introduced. Production authority,
serving-reader and actual retained rollback-artifact compatibility and independent
barrier recovery remain #793/#1315.
Flag retirement is tracked by #1316. See
[ADR 0036](../../docs/adr/0036-serialize-durable-grant-registration-and-drain.md).

## Disposable durable capability composition

The native-only startup probe additionally requires
`WAR_DURABLE_GENERATION_PROBE_ENABLED=true`. Absent or `false` returns before
reading fixture material or storage. Ordinary plugin builds exclude the probe
and its capability imports. It has no public RPC or production activation path.

The fixed `WAR_DURABLE_GENERATION_PROBE_SCENARIO` controls are `unfenced`, `held-put`,
`late-ack`, `lost-ack`, `cancel-after-write`, and the paired
`crash-before-exposure`/`restart` arms. The trial supplies a private 0600 material file through
`WAR_DURABLE_GENERATION_PROBE_MATERIAL` and an owned loopback synchronization
endpoint through `WAR_DURABLE_GENERATION_PROBE_CONTROL`. No ambient cluster,
kubeconfig, external executable authentication or service-account discovery is used.
An owned fixture helper starts pinned kube-apiserver/etcd binaries and the rendered
Agones CRD; stdin closure retires that helper and its private state. Both Linux
architectures verify the downloaded fixture checksums before building the image.

The native parent independently reads the actual PostgreSQL registration while
its acknowledgment is held and verifies that no capability or allocation escaped.
After exposure, it captures the original allocation PUT, drains through actual
Nakama StorageWrite, observes a real GameServer barrier, and releases the old PUT
to require HTTP 409 without changing the barrier.
The same captured frozen mutation succeeds through the unfenced positive control.
The late-ack control proves local closure before acknowledgment release and barriers
the unexposed registered grant.
The lost-reply control retains the committed row but cannot expose a grant, fence,
or recreate the generation root in a new owner. Post-write cancellation also
refuses exposure and prevents an already waiting fence from producing a receipt.
A killed process leaves its registered-but-unexposed entry;
the restarted native incarnation cannot adopt it or mutate the GameServer.
These diagnostics do not authorize
production quarantine release. See
[ADR 0037](../../docs/adr/0037-register-frozen-capabilities-before-exposure.md).

## Disposable acknowledged recovery handoff

The native-only `WAR_DURABLE_RECOVERY_HANDOFF_PROBE_ENABLED=true` probe
publishes a private create-only generation handoff after acknowledged drain.
Absent or `false` is inert before dependency access. Its scenario, private 0600
material, owned loopback control and independently retained pins are supplied
through the corresponding `WAR_DURABLE_RECOVERY_HANDOFF_PROBE_*` inputs.
Normal plugin builds exclude this probe; retirement is tracked by #1316.

The supervisor receives acknowledged pins over its private control channel,
checks the actual private PostgreSQL rows, kills and joins the original process,
then starts a fresh packaged reader with those retained pins. The complete
original inventory and exact drain version must survive. A held original
allocation PUT returns HTTP 200/Allocated after fresh readback with zero barrier
PUTs: the handoff has no fencing authority.

Mandatory controls include registered-but-unexposed late acknowledgment,
lost drain and publication replies, post-write cancellation, source death after
drain but before publication, competing create-only publication, and refused
stale/changed/missing/public/omitted-inventory rows. Visible committed rows cannot
replace a missing acknowledgment or independent pin retention.
Barrier-only recovery and owner exclusion use the separate default-off experiments
in ADRs 0039/0040. Production quarantine release remains #1315/#793.
See [ADR 0038](../../docs/adr/0038-retain-an-acknowledged-drain-handoff.md).

## Disposable complete recovery publication

`WAR_DURABLE_RECOVERY_PUBLICATION_PROBE_ENABLED=true` enables only the native trial.
Absent or `false` is inert before storage, pin or material access. The corresponding
`*_ID`, `*_SCENARIO`, `*_CONTROL`, `*_MATERIAL`, `*_PINS` and `*_PUBLICATION_PINS`
inputs remain private disposable fixture inputs. Normal plugin builds exclude this
entrypoint and its writer; #1316 tracks retirement.

The originating complete opaque result spends one shared publication attempt across
copies and independent publisher wrappers. One generation-scoped private create-only
row requires exact native storage ACK, same-version private proof readback and the
unchanged original owner/handoff/root. Only that live accepted result delivers pins
to the supervisor. A fresh read-only process validates those independently retained
pins after publisher death, without restoring publication or allocation authority.

Both native architectures join two frozen targets, original HTTP-409 barrier controls,
complete/mixed outcomes, competing owners and same-result publishers, omitted/changed
proof contents, lost/canceled storage replies and actual killed/joined processes before
submission, after commit before ACK, after ACK before readback and after complete
readback before pin export. Visible rows never repair missing acknowledgment or pins.
Every mandatory native scenario must pass. This supervisor does not establish
authenticated durable production custody or database rollback survival. Exclusive
mutation authority, serving/retained reader adoption and quarantine release remain
separate #1315/#793 gates. See
[ADR 0041](../../docs/adr/0041-publish-an-acknowledged-complete-recovery-proof.md).
