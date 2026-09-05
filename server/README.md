# `server/` — the authoritative realtime tier

The Go server that owns the world. The client renders and predicts; **the server
decides**. This directory is the start of that tier, per the settled server
design in the repo [`AGENTS.md`](../AGENTS.md).

## What is here now

The **zone tick core** — the deterministic simulation heart of a single
zone/dungeon server:

- **`sim/`** — the authoritative simulation, with no I/O and no clock of its own:
  - `Vec3` world coordinates in **integer millimetres**. Integer-only math makes
    the simulation bit-identical on every host — floating point is the classic
    source of physics desync, and this game's product law (no desync, no undo)
    makes determinism a day-one requirement.
  - `World.Step` — one fixed authoritative tick: capsule actors integrate a
    clamped movement intent on a bounded flat navmesh, iterated in a stable
    entity order so the result never depends on map iteration order. **No physics
    engine runs in the authoritative path** — capsule kinematics only, which is
    what keeps the Go authority cheap, deterministic and latency-tolerant.
  - **Capsule-vs-capsule separation** — after movement, each tick resolves
    overlap so no two actors share the same space, the one spatial rule a client
    cannot be trusted to make. It is a positional de-overlap (each overlapping
    pair pushed apart by half its penetration) solved by integer-only,
    order-independent relaxation — no impulses, no physics engine — with its own
    committed golden hash pinning the settled state across architectures. A
    spatial-hash **broad phase** offers only the pairs that can actually touch,
    so the pass costs ~O(n) instead of O(n²) as a zone's actor count grows,
    without changing that deterministic settled state.
  - **Swept (continuous) collision** (`World.SweptCollision`, a **feature flag,
    default off**) — separation only sees where actors *end up*, so an actor
    moving faster than a capsule per tick could pass clean through another
    between two ticks (and separation would then push it out the far side, not
    back). With the flag on, `Step` integrates continuously — a mover is stopped
    at first contact, computed in the pair's relative frame so it is correct when
    both actors move. It is exact-integer (`math/big` for the few over-`int64`
    intermediates, never floating point). It ships off because stop-at-contact is
    a genuine behaviour change; the flag is armed before the high-speed movement
    (a dash/charge) that needs it, and flipped on after validation — the product
    law has no undo. With it off the movement pass is byte-identical to the plain
    integration, so every settled golden is unchanged.
  - `FixedLoop` — a fixed-timestep accumulator that runs the sim at exactly
    `TickHz` regardless of wall-clock jitter, with a catch-up cap so a stalled
    process can never spiral.
  - `World.Hash` — an order-stable digest that makes determinism testable, and
    a committed golden hash that pins the demo scenario's exact behaviour.
  - `World.Interest` + `InterestTracker` — **area-of-interest**: which entities
    each observer is told about (a horizontal-radius query, ascending-ID and
    integer-only) and the per-tick **enter/leave** deltas a replication layer
    needs. This is what upholds "nothing appears from nowhere" and keeps
    replication tractable as zone density grows; a second committed golden pins
    the demo scenario's event stream, proving AoI is cross-platform too. It is a
    read-only query — never part of `Step`, so it cannot move the movement golden.
  - `World.Snapshot` + `SnapshotTracker` — the **replication payload** built on
    AoI: a per-observer snapshot is the state (id, position, radius) of every
    in-interest entity, and the tracker diffs consecutive snapshots into the
    minimal per-tick **spawn / update / despawn** delta, so a client's bandwidth
    scales with change, not with zone population. A third committed golden pins
    the demo scenario's delta stream — folding in moved-entity state, so it pins
    the replicated *state*, not just membership — proving it is cross-platform.
    Read-only, never part of `Step`.
  - `Telegraph` + `World.Caught` — **authoritative telegraph resolution**: who is
    standing in a shape painted on the ground (circle, ring, cone, beam) when it
    resolves. Every semantic mirrors the client's `Telegraph` predicates
    deliberately — planar XZ, inclusive edges, apex-inside, degenerate-safe —
    because the client predicts with the same question and the two answers must
    agree, or the player dodges on screen and is hit on the server. The maths is
    exact and integer-only: circle and ring are `int64` squared-distance
    comparisons, while the cone's angular test and the beam's projection use
    `math/big` for the intermediates that outgrow `int64`, so there is no float
    and no `isqrt` truncation; a cone carries a **precomputed scaled cosine**, so
    the authoritative path never calls a trig function. A fourth committed golden
    pins the demo scenario's resolution stream. Ascending-ID and read-only —
    never part of `Step`, so it cannot move the movement golden.
  - `World.AddMob` + the cast lifecycle — the **mob combat AI** (the single
    implementation by decision, #207): a registered mob acquires the nearest
    non-mob entity within an inclusive aggro radius (ties broken to the lowest
    ID, iterated in stable order) and paints a circle **anchored where the
    target stood at cast start** — ground-anchored, never tracking, which is
    exactly what makes the attack winnable by moving well and losable by
    standing still. A positive `MobParams.ChaseSpeedMM` makes the mob write
    horizontal intent through the existing deterministic kinematic path until
    the gap between capsule surfaces reaches the inclusive
    `MobParams.CastRangeMM` (zero means contact), then stop and paint; target
    loss and an in-flight cast also stop it. Zero chase speed deliberately
    preserves the original stationary-caster behavior. Both parameters are
    clamped at `AddMob` ingestion, including a one-millimetre-per-tick floor
    for positive chase speed; a deterministic dominant-axis staircase keeps
    the floor moving diagonally.
    The cast resolves a fixed number of ticks later against where everyone is
    standing **at resolution** (leave and wander back in and you are still
    hit), excluding the caster, into a bounded `TelegraphHit` record log the
    consumer drains every tick. A zero wind-up is clamped to a full tick: an
    instant telegraph cannot be dodged, and dodgeability is product law.
    `ActiveCasts` exposes the painted, unresolved marks — the read seam the
    future replication child consumes, because a client must SEE the mark to
    step out of it. Runs inside `Step` (one tick loop, resolution before
    decision) and decides in ascending-ID order. The flag-off world keeps the
    original stationary combat golden unchanged; chase has insertion-order,
    range, stop and hostile-parameter regressions. Threat, dead-target
    filtering, factions, interruption, real navmesh routing and cast
    replication remain later children; #357 owns enabling or retiring the
    delivery flag after real-zone evidence.
  - `Entity.Health` + `World.ApplyDamage` — the **consequence layer**: a
    resolved telegraph finally costs something. Health is part of the hashed
    world state for entities with a pool (`MaxHealth > 0`) — a divergence in
    health is a desync like any other — while poolless entities hash exactly
    as before, so every pre-health golden is unchanged by construction. A
    `TelegraphHit` carries its mob's configured damage, and the zone loop
    lands each drained hit with one explicit `ApplyDamage(hit.Targets,
    hit.Damage)` call — application is caller-owned ordering, not a hidden
    phase of `Step`. Damage is clamped at ingestion (never negative, never
    overflowing), a dead entity is skipped (which makes each `DeathEvent`
    observable exactly once), and what death *does* — despawn, respawn, loot —
    is deliberately the next child: the world cannot even remove entities yet.
    A committed damaged-world golden pins a scripted encounter in which the
    standing target dies and the escaping walker ends unharmed, with an
    application-ablated twin proving the golden is not blind to health.
- **`wire/`** — the **versioned wire codec**: the transport-agnostic binary
  encoding of the replication payload (the full join snapshot and the per-tick
  delta stream). Every message opens with an explicit protocol version. The
  server currently retains entity-only v1 and adds v2, whose snapshot tail
  carries active telegraph casts and whose delta tail carries cast starts and
  ends. A WebSocket peer without `X-WAR-Wire-Version` stays on v1; the v2
  Godot client requests version 2 during its authenticated upgrade, and that
  selection is fixed for the connection lifetime. This is the expand half of
  the product's expand-then-contract law: old clients remain serviceable while
  new clients receive authoritative cast geometry and timing. The layout is
  canonical (fixed-width little-endian, one-byte encoding per message value) and the
  decoder fails closed on untrusted bytes: counts are capped before any
  allocation, every read is bounds-checked, truncated or trailing bytes are
  refused, and the sim's ascending-ID list contract is enforced — never
  silently repaired — on both encode and decode. Committed hex goldens pin the
  exact byte layout, while shared entity and cast-stream goldens prove the Go
  tracker/encoder and Godot decoder/store/connection agree on exact frames.
  It exists as a pinned contract *before* transport selection, so the socket
  child builds against a settled format instead of inventing one.
- **`agones/`** — the **Agones GameServer lifecycle**: what makes the zone
  binary deployable on the fleet. Agones's contract is hard — a GameServer that
  never calls `Ready` is never allocated, and one that stops calling `Health`
  is killed as unhealthy — so this package speaks exactly that contract through
  the official Agones Go SDK (the server's first dependency): Ready once the
  serving loop is up, Health on a fixed cadence, Shutdown on every exit path.
  Its sealed-admission path reads the GameServer identity while it is
  `Starting`, generates one 32-byte secret in memory, RSA-OAEP seals it to a
  projected public key, publishes the versioned envelope, key fingerprint and
  fingerprint-qualified Ready label, then waits for `WatchGameServer` to
  return those exact values. The command starts the identity-bound HMAC
  verifier and listener before calling `Ready`. A `Ready`, `Reserved`, or
  `Allocated` restart calls `Shutdown` without replacing metadata.
  It is **opt-in behind the `-agones` flag, default off** — flag off means no
  SDK dial at all; adding `-agones-admission-public-key <path>` selects sealed
  admission, while omitting it retains the environment-secret path for local
  socket exercises. The lifecycle never touches `sim/`, so no golden can move.
  An unreachable sidecar with the flag on fails loudly, never silently.
  Tests drive the real SDK client against an in-process fake sidecar
  (`agones/agonestest`), at package level and against the built binary in both
  flag states. The pod-shape contract leaves `serviceAccountName` unset so the
  Agones controller installs its official SDK identity and shadows that token
  only in the zone container; the sidecar retains its credential, the public
  wrapping key is a read-only ConfigMap projection, and no Kubernetes Secret
  volume is part of the shape.
- **`nakamastorage/`** — the primitives every Nakama-backed store is built on: the
  slice of the runtime storage surface a store depends on, the system owner private
  records live under, canonical JSON encoding of a document, subject-identity
  validation, strict object decoding, and the sanitising of a storage error so a
  caller learns about its own cancellation and nothing about the store. A new store
  calls through to it rather than carrying its own copy (#780).
- **`nakamaauth/`** — the first **Nakama meta-tier seam**. Its session verifier
  presents a Nakama session to the generated gRPC `GetAccount` API as bearer
  metadata, and only Nakama's authenticated user ID crosses back into World at
  Ruin. Its default-off Google OIDC provisioner validates the ID token locally
  against the configured `GoogleClientID`, rejects unsafe/non-RS256 JWT shapes
  before entering the pinned validator, bounds token size before segment
  parsing, accepts only Google's issuer and a non-empty subject, and sends
  Nakama `AuthenticateEmail` a domain-separated opaque address plus a separately
  derived password. Both derive from the subject and server-only
  `NakamaIdentityKey`; the identifier Nakama may log cannot authenticate without
  the unlogged password. The raw Google credential therefore never reaches
  Nakama's credential-logging Google path, while the public Google subject
  cannot be guessed into Nakama credentials. After first-use account
  verification, an independently domain-separated HMAC key owns a strict,
  create-only mapping to the user ID in private, system-owned Nakama runtime
  storage. Later sign-ins resolve that immutable binding before touching
  Nakama's mutable email field, so ordinary email link/unlink operations cannot
  detach the Google identity or strand the original account; the production
  store then asks Nakama for that exact account and refuses a missing,
  mismatched, or disabled user, so the stable-ID fast path cannot bypass a ban.
  Both the email insert and binding write reconcile one concurrent winner
  without overwriting it, and neither the binding API nor its production store
  exposes an update or delete operation.
  `ProvisionerConfig.GoogleProvisioningEnabled` is false by default, and
  enabling it also requires `GoogleClientID`, a stable and backed-up
  `NakamaIdentityKey` of at least 32 bytes, `NakamaServerKey`, and a durable
  `GoogleBindingStore`; `NewNakamaGoogleBindingStore` is the production
  implementation over Nakama's authoritative runtime storage surface. The
  identity key and binding collection are durable identity roots: rotating,
  losing, deleting, or rewriting either requires an explicit account migration.
  Binding documents use a strict schema that rejects unknown, duplicate,
  missing, trailing, public, or client-writable data; schema 1 is permanently
  pinned by `nakamaauth/testdata/shipped_google_binding_versions.txt` and its
  matching golden. The complete identity-address contract—including the
  collection and exact HMAC-derived email, password and binding address—is
  pinned by `nakamaauth/testdata/golden_google_identity_address_v1.json`.
  CI compares those permanent fixtures against the base revision before this
  default-off writer can be composed and enabled.
  The provisioner uses the Nakama server key only for Nakama's
  Basic-authenticated account-creation RPC, then replaces it with the returned
  session bearer for account verification. Binding operations receive neither
  bearer nor server-key metadata. Every path fails closed on empty, malformed,
  corrupt, disabled, or unavailable responses, preserves only actionable
  transport status codes, and exposes no upstream credential, server key,
  binding key, user ID, or Nakama error text. Hermetic tests exercise the real
  generated gRPC client/server and authoritative-storage paths.
- **`agonesalloc/`** — the typed **Agones allocation API boundary**: it sends
  one current-format `AllocationRequest` through Agones's generated gRPC client,
  selecting only Ready GameServers whose fleet and admission-ready label match
  the configured wrapping-key fingerprint exactly. Reservation and attempt
  values enter GameServer labels only as full SHA-256-derived, label-safe
  correlation values; a versioned claim locator combines the private lease
  object ID with the attempt digest without exposing the caller's raw
  identifiers. A response is usable only when it names a valid GameServer,
  carries exactly one in-range configured TLS port, echoes the exact fleet,
  readiness, wrapping-key and claim metadata, and supplies a bounded canonical
  version-one admission envelope. The returned endpoint includes the validated
  fingerprint and sealed envelope so an allocated lease remains resolvable
  across wrapping-key rotation. Allocation refusals preserve the stable gRPC
  code without reflecting upstream text. Hermetic tests exercise the real
  generated client/server path.
- **`gameserverapi/`** — the least-privilege **Agones GameServer resource
  boundary** used by durable handoff reconciliation. Its Kubernetes seam
  exposes only namespaced `get`, `list`, and `delete`: no create, update, patch,
  watch, or access to another resource kind. Exact-name reads pin namespace,
  name, UID, Fleet, full attempt digest, `Allocated` state, and one named TLS
  status port; exact-attempt listing uses the same shared full SHA-256 label
  contract as allocation and returns every match so duplicates stay explicit.
  Cleanup accepts only a complete identity and sends its UID as a Kubernetes
  deletion precondition, preventing stale cleanup from deleting a recreated
  GameServer. Returned metadata maps are detached snapshots. Hermetic tests
  drive the generated Agones fake client through zero, one, duplicate,
  changed-identity, and exact-UID paths.
- **`nakamalease/`** — the private **Nakama handoff lease store**: one
  server-owned object per SHA-256-derived user/reservation key owns the current
  allocation attempt, including its pre-provision staging intent, observer
  binding, per-allocation secret reference, no-show deadline and optional claim
  time. Global system ownership prevents players from pre-creating or replacing
  a lease; objects are also server-only
  (`PermissionRead: 0`, `PermissionWrite: 0`), use a strict versioned JSON
  schema, omit the raw user/reservation identifiers and admission-secret bytes,
  and expose only sanitized errors. The reader permanently accepts every
  ledgered schema-one through schema-three lifecycle shape, with base-anchored
  ledgers and complete goldens preventing a shipped shape from being rewritten
  or removed. Schema-three writes add a durable `dispatched` point of no return
  and unique dispatch-call identity, while the existing durable `releasing`
  barrier atomically decides whether zone admission or external cleanup owns
  an attempt. A paginated private-collection sweep exact-version
  fences expired staging and allocated attempts before idempotent external
  cleanup, deletes only the fenced version, and preserves a dispatched staging
  attempt for exact reconciliation instead of guessing that an expired RPC did
  not commit. Nakama's unique-create marker and exact storage versions make
  create, dispatch, staging finalization, replacement, claim and release safe
  under retries and overlapping attempts; a stale attempt cannot overwrite,
  claim or delete the current owner. Hermetic
  race-enabled tests exercise Nakama's real runtime storage request, object and
  acknowledgement shapes.
- **`handoff/`** — the transport-neutral **player handoff core**: it consumes
  `nakamaauth` rather than accepting a client-provided identity, gives only that
  verified user ID plus a caller-stable reservation key and server-generated
  attempt ID to an allocation boundary, validates the returned GameServer is
  under the configured managed DNS domain with a usable endpoint and observer
  binding, and mints the short-lived token with a per-allocation secret that
  only that zone receives. Every failed stage returns a zero handoff;
  post-allocation failures and ambiguous allocation errors conditionally
  reconcile the verified-user/key/attempt on a bounded cleanup context, while
  stale attempts cannot release a newer overlapping retry. Each allocation is
  an expiring no-show lease that its adapter must reclaim unless first valid
  zone admission claims it, and the nanosecond-precision token never outlives
  that lease. Retryable gRPC status codes survive without upstream text, and
  credentials never enter returned errors. Hermetic tests drive the real
  generated Nakama gRPC path through the service and then verify its token
  through the real zone verifier.
- **`admissionref/`** — the sealed-admission material boundary. A
  rotation-capable RSA keyring indexes retained unwrap keys by the canonical
  SubjectPublicKeyInfo fingerprint. It opens only a canonical version-1
  envelope whose OAEP label binds the namespace, GameServer name, UID and key,
  requires exactly 32 plaintext bytes, and returns isolated secret copies.
  The same boundary derives and verifies the durable DNS-safe reference that
  pins the key, UID digest, ciphertext digest and TLS port. Recovery refuses a
  changed identity, envelope, key or port through one sanitized error. It is
  pure and remains uncomposed until the concrete GameServer resource adapter
  owns the Agones and Kubernetes calls.
- **`handoffalloc/`** — the durable **handoff allocation coordinator**: it
  implements `handoff.Allocator` over the real `nakamalease` store and an
  injected GameServer-resource boundary. It persists a staging intent and an
  exact-version `dispatched` barrier with a unique call identity before the one
  permitted external allocation call. A lost or malformed barrier
  acknowledgement is re-read so only the caller whose identity committed may
  dispatch; then connection material returns only after the exact allocation
  and secret reference replace the intent durably. A replay, restart or
  concurrent loser reconciles only that attempt and never issues a second
  allocation call. Timeout, cancellation and other ambiguous outcomes retain
  the dispatched attempt in quarantine. A transport retry with the same
  reservation adopts that durable attempt for observation-only reconciliation;
  a retry after finalization resolves the same unclaimed allocation. Reused
  and newly published allocations are retained on downstream response failure so
  overlapping callers cannot tear down a GameServer another caller received;
  its no-show lease is the sole bounded cleanup owner. Ambiguous post-dispatch
  errors carry the same non-destructive marker through the outer handoff service.
  This remains safe in either finalization order: an adopter or the original
  dispatcher may publish first, and neither response receives cleanup authority.
  Expiry cleanup cannot pass an unresolved quarantine without the later
  allocator-generation fence, and unverified outer cleanup cannot erase it. An
  expired attempt is atomically marked `releasing` before external cleanup so a
  concurrent zone claim cannot win after reclamation begins.
  Replacement and release retry from that barrier; once a concrete resource is
  observed, the complete fence-and-cleanup transaction uses a bounded context
  that survives caller cancellation. Its supervised expiry reconciler
  lists the private lease collection, automatically reclaims no-shows, and
  retries transient storage or resource cleanup failures without stopping the
  supervisor. This includes a crash that left only an attempt ID. Claimed and
  stale attempts remain untouched, external errors are sanitized, and raw
  admission-secret bytes never enter the lease. The coordinator is inert until
  a concrete `GameServerResources` adapter provisions Agones GameServers,
  composes the `admissionref` boundary, and resolves their zone-generated envelopes
  according to [ADR
  0002](../docs/adr/0002-seal-zone-admission-secrets-before-readiness.md), its
  expiry loop will be supervised, and a Nakama RPC will register the resulting
  handoff service.
- **`cmd/zone/`** — a runnable skeleton server. It boots the demo zone and either
  runs a fixed number of deterministic ticks (printing the state hash) or drives
  the loop from the wall clock. With `-replicate` it also runs the full
  replication pipeline a transport will carry — per-tick tracker delta →
  wire-encode → decode → verify — and prints the payload sizes (the baseline for
  future bandwidth evidence). With `-agones` (`-listen` only — Ready must
  mean a connectable endpoint, and only `-listen` opens one) it registers
  with the local Agones sidecar for its lifetime, so the shape a fleet
  GameServer runs is `-listen` + `-agones`. Supplying
  `-agones-admission-public-key` makes the observed GameServer name the
  allocation ID and removes the local environment secret from that path.

```sh
cd server
go run ./cmd/zone                     # 600 deterministic ticks, then the state hash
go run ./cmd/zone -ticks 1800         # a different fixed count
go run ./cmd/zone -realtime -duration 3s   # drive the fixed loop from real time
go run ./cmd/zone -replicate 1        # also wire-encode observer 1's delta stream
go run ./cmd/zone -allocation-id local-zone -listen :8443 -tls-cert cert.pem -tls-key key.pem -agones
go run ./cmd/zone -listen :8443 -tls-cert cert.pem -tls-key key.pem -agones \
  -agones-admission-public-key /var/run/world-at-ruin/admission/public.pem
```

## What is deliberately not here yet

Later children of the server-foundation epic
([#4](https://github.com/devantler-tech/world-at-ruin/issues/4), the first child
of the Phase 1 epic [#8](https://github.com/devantler-tech/world-at-ruin/issues/8)):
the concrete resource adapter that composes `agonesalloc`, `gameserverapi`,
`admissionref`, and the zone-side sealed-envelope lifecycle in
[ADR 0002](../docs/adr/0002-seal-zone-admission-secrets-before-readiness.md),
the zone admission claim adapter, Nakama RPC registration that exposes the
handoff service, the client entry point that enables Google account
provisioning, the rest of the Nakama social/chat/storage surface, client
prediction and reconciliation, real navmesh geometry, and Postgres/CNPG
persistence. Zone boot already generates, publishes and observes the sealed
envelope; allocation metadata validation, coordinator unwrap/recovery and
private claim behavior are not composed yet. The tick core, socket, client
replica store, Agones lifecycle, default-off Nakama account provisioning and
session verification, allocation API boundary, exact-UID GameServer resource
boundary, private lease store, durable handoff coordinator and fail-closed
handoff core are in place; later slices build on those tested seams instead of
creating a parallel meta service.

## Validate

```sh
cd server
gofmt -l .            # must print nothing
go vet ./...
go test -race ./...   # includes the tick-determinism and golden-hash tests
go build ./...
```

CI runs exactly this in the `Server CI (Go)` job, aggregated into the
`CI - Required Checks` gate.

## Product-law notes

- **Determinism is enforced, not hoped for.** The two-world determinism test and
  the cross-platform golden hash fail the build the moment a change makes the
  simulation diverge. Changing the golden is a deliberate, reviewed act.
- **Forward-only by construction.** Simulation units are integers and the tick
  rate is a constant; there is no wall-clock or unseeded randomness in the
  authoritative path, so a build's behaviour is fully attributable to its code.
