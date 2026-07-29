# ADR 0002: Seal zone admission secrets before readiness

- Status: Accepted
- Date: 2026-07-29
- Decision issue: [#450](https://github.com/devantler-tech/world-at-ruin/issues/450)
- Parent: [#4](https://github.com/devantler-tech/world-at-ruin/issues/4)

## Context

`server/handoff` mints a short-lived HMAC token for one allocated GameServer and
one observer. `server/handoffalloc` durably stages that attempt in Nakama before
external work and records only an opaque `SecretRef` after provisioning.
`server/agonesalloc` can allocate a Ready GameServer, while `server/cmd/zone`
still receives its admission secret from an environment variable intended for
local development.

Production cannot use one environment secret across a Fleet. A compromised
zone holding that key could mint a valid token for every other allocation.
Generating a secret after allocation and mounting it into the selected Pod is
also not a viable lifecycle: an Agones GameServer is already running before it
becomes Ready, and a
[Kubernetes Secret volume](https://kubernetes.io/docs/concepts/storage/volumes/#secret)
names its Secret in the Pod specification before startup. Secret volumes are
read-only, but their `secretName` is not a late-bound allocation result.

Agones already supplies the two required rendezvous points through its
[Client SDK](https://agones.dev/site/docs/guides/client-sdks/) and
[allocation API](https://agones.dev/site/docs/reference/gameserverallocation/):

- the zone can set labels and annotations through the local SDK, observe the
  resulting GameServer with `WatchGameServer`, and only then call `Ready`;
- an allocation can select that Ready label, and the allocation response
  includes the selected GameServer's labels and annotations.

Both operations are eventually consistent. The protocol therefore needs an
explicit observed-before-Ready barrier, not timing assumptions.

## Decision

Each zone process will generate its own 32-byte admission secret in memory
before it becomes Ready. It will seal that secret to the coordinator's public
key and publish only the ciphertext on its own GameServer. The coordinator
will obtain and decrypt that envelope only after Agones allocates the exact
GameServer.

The ciphertext on the GameServer is the durable recovery source. Raw
per-allocation secret bytes will not be persisted in a Kubernetes Secret or a
Nakama object. `SecretRef` will pin the selected GameServer identity, wrapping
key, and envelope digest so the coordinator can resolve the same material
after a restart without widening secret custody.

### Threat model

The trusted principals are the coordinator/Nakama server process and the exact
zone process selected for an allocation. The player, public network, other
zone processes, and metadata readers are untrusted. Kubernetes and Agones
administrators remain infrastructure-trusted; compromising the coordinator's
unwrap key or the cluster control plane is outside this application boundary.

The protocol must preserve these properties:

1. Compromising one zone reveals only that process's in-memory secret and
   cannot mint for another allocation.
2. A player never receives a secret, unwrap key, envelope plaintext, or
   Kubernetes credential.
3. Raw admission bytes never enter Nakama storage, GameServer metadata, logs,
   errors, metrics, issue text, or PR evidence.
4. Replaying or moving an envelope to another GameServer fails identity
   validation.
5. Metadata corruption and control-plane ambiguity can deny a handoff, but
   cannot make the coordinator accept the wrong zone or secret.

The unwrap private key is a distinct platform-delivered coordinator
credential. Zones receive only its public key. A compromised zone can create a
new envelope for itself, but cannot decrypt another zone's envelope or cause
one GameServer's identity-bound envelope to validate for another.

### Envelope format and metadata

Version 1 uses RSA-OAEP with SHA-256 and a minimum 3072-bit key. This keeps the
implementation in Go's standard cryptography library and makes the one-time
per-process cost negligible. The plaintext is exactly 32 cryptographically
random bytes.

The OAEP label is these UTF-8 fields in fixed order, separated by one `0x00`
byte and with no trailing separator:

```text
world-at-ruin/zone-admission/v1
namespace
GameServer name
GameServer UID
wrapping-key fingerprint
```

The lowercase, unpadded base32 encoding of the full SHA-256 fingerprint of the
DER SubjectPublicKeyInfo bytes returned by Go's `x509.MarshalPKIXPublicKey`
identifies the key. PKCS #1 encoding is not accepted for this fingerprint. The
zone base64url-encodes the ciphertext without padding and publishes:

| Metadata | Value |
|---|---|
| `agones.dev/sdk-war-admission-envelope` annotation | Version 1 ciphertext |
| `agones.dev/sdk-war-admission-key` annotation | Full wrapping-key fingerprint |
| `agones.dev/sdk-war-admission-ready` label | `v1` |

These are the names produced when the zone gives the suffixes to Agones SDK
`SetAnnotation` and `SetLabel`. The envelope and fingerprint are not
credentials. They are still size-limited, schema-validated, and excluded from
ordinary logs.

The coordinator holds a keyring indexed by the full fingerprint. Rotation
publishes a new public key first, waits for new Ready GameServers to advertise
it, and retains the previous private key until every GameServer and handoff
lease using it has expired. Unknown or retired fingerprints fail closed.

### Zone boot and readiness

The production Agones lifecycle will perform these steps in order:

1. Read the public wrapping key from a read-only ConfigMap projection and get
   this GameServer's namespace, name, UID, and state through the local Agones
   SDK.
2. Refuse an invalid identity or an already-Allocated restart. An allocated
   process that lost its in-memory key calls `Shutdown` and exits; it never
   advertises a replacement key or returns itself to Ready.
3. Generate the admission secret with `crypto/rand`, seal it with the
   identity-bound OAEP label, and retain the raw bytes only in process memory.
4. Set the two annotations and Ready label through the SDK.
5. Observe all three exact values through `WatchGameServer`.
6. Start the TLS socket with an HMAC verifier bound to the GameServer name,
   then call `Ready`.

Any failure before step 6 leaves the GameServer unallocatable. The existing
health and shutdown contract continues after readiness. A sidecar reconnect
does not regenerate the secret or re-send `Ready`.

The GameServer name is the allocation ID signed into the existing version 3
token. Fleet-generated names must satisfy both Kubernetes DNS-label rules and
the token's opaque allocation-ID grammar.

### Provisioning and durable resolution

`GameServerResources.Provision` will use this ordering:

1. Receive the already-durable staging attempt from `handoffalloc`.
2. Before allocating, reconcile any Allocated GameServer carrying the full
   SHA-256-derived attempt label.
3. Otherwise call the Agones allocation service with selectors for the
   configured Fleet and `agones.dev/sdk-war-admission-ready=v1`. The existing
   reservation and attempt correlation labels are applied atomically by the
   allocation request.
4. Validate the response metadata, then perform a bounded read-after-allocation
   retry of an exact Kubernetes `get` for the named GameServer. Check its UID,
   Allocated state, Fleet, attempt label, envelope, key fingerprint, and TLS
   port. The retry waits only for that identity and never substitutes another
   object.
5. After the returned GameServer is observable, list managed Allocated
   GameServers with the exact attempt digest from a consistent Kubernetes API
   snapshot. Finalization requires exactly one match and its UID must equal the
   returned GameServer. Zero matches are retried within the same bound. More
   than one match moves every matched exact UID through release, then fails
   closed; a retry allocation is never finalized without this singleton check.
6. Reconstruct the OAEP label, decrypt exactly 32 bytes, and construct the
   durable reference.
7. Return the raw bytes only in the in-memory `handoff.Allocation`. The
   coordinator finalizes the Nakama lease with `SecretRef`; `handoff.Service`
   mints the token and releases its copy.

The reference is a lowercase DNS-subdomain value compatible with the current
Nakama schema:

```text
v1.k<base32-sha256-public-key>.u<base32-sha256-gameserver-uid>.e<base32-sha256-envelope>.p<decimal-tls-port>
```

`AllocationID` supplies the GameServer name and the adapter configuration
supplies the namespace. `Resolve` gets that exact GameServer, recomputes every
reference component, requires the named TLS port to equal the persisted decimal
port, repeats the state and correlation checks, and decrypts the pinned
envelope. A changed UID, annotation, key, label, port, or state is an invalid
resource, never an opportunity to repair in place.

No raw secret store exists to reconcile or garbage-collect. Removing the
GameServer removes the only persisted ciphertext.

### Observer binding and admission claim

The allocation metadata patch also carries a non-secret claim locator composed
of the private Nakama lease object ID and the attempt digest. It contains no
user ID, reservation ID, raw attempt ID, or authorization material. The zone
observes that locator through its existing GameServer watch and remains
fail-closed for player admission until it arrives.

The token continues to bind the GameServer allocation ID, observer entity, and
nanosecond expiry under the allocation secret. On connection:

1. the zone verifies the HMAC and allocation ID locally;
2. before upgrading the socket, it sends the token and claim locator to the
   private Nakama claim boundary;
3. that boundary loads the exact private lease, resolves its pinned envelope,
   independently verifies the token, observer, allocation, attempt digest, and
   expiry, then performs the existing exact-version `Claim`;
4. only a successful or idempotently repeated claim admits the observer.

The locator is routing, not authority. A compromised zone cannot claim another
allocation because it cannot supply a token verified by that allocation's
secret. `Claim` and `BeginRelease` keep their current version race: exactly one
of admission or cleanup can win.

### Retry, recovery, and cleanup behavior

| Event | Required behavior |
|---|---|
| Successful handoff | Finalize the exact GameServer and `SecretRef` before returning an endpoint or token. |
| Agones timeout after allocation | List only managed GameServers with the exact attempt digest; reconcile one exact match and retry allocation when none exists. After any retry succeeds, repeat the consistent singleton list before finalization; fail closed while releasing all exact-UID duplicates when more than one exists. |
| Same-attempt replay | Reuse the staging expiry and the exact attempt-labelled GameServer; do not allocate again. |
| Same reservation, newer attempt | Mark the older lease `releasing`, delete only its exact UID, then stage the new attempt. |
| Stale-attempt release | Validate the attempt digest, allocation ID, UID digest, and envelope digest; never delete a newer attempt's GameServer. |
| Claim racing cleanup | The Nakama exact-version `Claim`/`BeginRelease` barrier decides the winner before external deletion. |
| No-show expiry | The supervised lease reconciler begins release and deletes the exact GameServer with a UID precondition. |
| Coordinator restart | Resolve the GameServer and ciphertext from the durable lease reference and decrypt with the retained keyring. |
| Allocated zone restart | Shut down and let the lease retry allocate a new process; never regenerate a key for an Allocated GameServer. |
| Orphan after a crash | A startup and periodic sweep compares attempt-labelled Allocated GameServers with live private leases. After a bounded grace and two observations, it deletes only exact-UID orphans. Ready pool members have no attempt label and are excluded. |
| Delete timeout | Re-read by name; absence is success, the same UID is retried, and a different UID is left untouched. |

The sweep may list managed GameServer metadata and private Nakama leases. It
never lists Kubernetes Secrets because this protocol creates none.

### RBAC and network authority

The production identities are deliberately asymmetric:

- **Zone ServiceAccount:** `automountServiceAccountToken: false`; no Kubernetes
  RBAC. It can reach only its localhost Agones SDK sidecar, the private claim
  endpoint, and its player-facing TLS listener. The wrapping public key is a
  read-only ConfigMap projection.
- **Coordinator ServiceAccount:** Agones allocator mTLS credentials and a
  namespaced Role limited to `get`, `list`, and `delete` on
  `gameservers.agones.dev`. It receives no `create`, `update`, `patch`,
  `watch`, Pod, ConfigMap, or Secret API permission. Deletes carry UID
  preconditions.
- **Nakama storage:** the lease and claim lookup remain system-owned,
  server-only objects with no player read or write permission.

NetworkPolicy permits coordinator-to-allocator and coordinator-to-Kubernetes
API traffic, zone-to-local-sidecar traffic, and zone-to-private-claim traffic.
The claim endpoint requires the zone workload's mTLS identity and independently
verifies the allocation token; it is not exposed through the player RPC
surface. Player traffic reaches only the zone's TLS WebSocket port and the
existing public Nakama endpoints.

Hermetic authorization tests must prove both the allowed calls and negative
capabilities: the zone has no Kubernetes token, the coordinator cannot read
Secrets or mutate GameServers, public callers cannot reach the claim boundary,
and one allocation's token cannot claim another.

## Rejected alternatives

### One Fleet-wide HMAC key

This makes every zone a minting authority for every allocation. Rotation also
becomes a Fleet-wide synchronized event. It violates the primary isolation
property.

### Plaintext GameServer metadata

Labels and annotations are visible to control-plane readers and often copied
into diagnostics. They are an appropriate rendezvous for public key IDs,
ciphertext, and digests, not raw admission material.

### Kubernetes Secret volume or environment delivery

A Pod's Secret reference is fixed before the GameServer becomes Ready.
Pre-creating one Secret per unknown future allocation has no selector binding,
while patching the running Pod specification is unsupported and would bypass
the Agones lifecycle. A Fleet-wide mounted Secret reduces to the shared-key
failure above.

### Zone access to the Kubernetes Secret API

Giving every GameServer a namespace-wide Secret reader makes workload
compromise a cross-allocation secret compromise. Kubernetes's own
[Secret good practices](https://kubernetes.io/docs/concepts/security/secrets-good-practices/)
warn that `list` and `watch` effectively reveal Secret contents. Even a scoped
mount would persist raw bytes unnecessarily. The selected envelope lets the
zone create its own secret and needs no Kubernetes credential.

### Coordinator-generated secret after allocation

The coordinator could fetch a zone public key, encrypt a new secret, and patch
the allocated GameServer. That adds a second post-allocation metadata race and
a new zone installation acknowledgement before minting. Publishing the
zone-generated envelope before Ready makes the allocation response the
rendezvous and removes that extra mutable phase.

### Keep the developer environment variable

The flag remains useful for local socket exercises, but it has neither
allocation identity nor production custody and is not a Fleet delivery path.

## Delivery boundaries

The decision is implemented through independently reviewable children of #4:

1. [#564](https://github.com/devantler-tech/world-at-ruin/issues/564) publishes
   and observes a zone-generated sealed envelope before Agones Ready.
2. [#565](https://github.com/devantler-tech/world-at-ruin/issues/565) returns
   and validates admission-envelope metadata at the Agones allocation
   boundary.
3. [#566](https://github.com/devantler-tech/world-at-ruin/issues/566)
   implements concrete `GameServerResources` provisioning, resolution, release,
   and ambiguous-outcome recovery.
4. [#567](https://github.com/devantler-tech/world-at-ruin/issues/567) binds the
   private zone claim path to the exact durable lease and token.
5. [#568](https://github.com/devantler-tech/world-at-ruin/issues/568)
   reconciles attempt-labelled orphan GameServers without Secret access.
6. [#569](https://github.com/devantler-tech/world-at-ruin/issues/569) composes
   and proves the production handoff lifecycle end to end.

The first real end-to-end proof is #569. It will boot the built zone binary
against the fake Agones sidecar, allocate it through the real generated
allocation gRPC contract, create a handoff through the real Nakama gRPC/storage
shapes, open the TLS WebSocket with the returned token, and prove that the
exact claim wins against no-show cleanup. The same test must show that a token
or envelope from a sibling GameServer is refused and that an ambiguous
allocation retry does not create a second surviving zone.

This ADR changes no runtime behavior. The environment secret remains a
developer-only helper until all production composition children land.

## Consequences

The coordinator must retain an unwrap keyring for at least the longest
GameServer and handoff lifetime, and production readiness gains an observable
metadata barrier. Coordinator recovery now depends on an exact GameServer GET,
but no new raw-secret data store, controller, mounted allocation Secret, or
namespace-wide Secret authority is introduced.

The result preserves the current HMAC token and durable lease seams while
making each GameServer its own admission authority. A compromised zone can
deny its own allocation, but it cannot expand that authority to another.
