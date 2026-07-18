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
  - `MobController` — the **mob combat core**: the smallest brain that makes
    "step out of the circle" real. An idle mob acquires the nearest entity
    within an inclusive aggro radius (ties broken to the lowest ID, iterated in
    stable order), telegraphs a circle **anchored where the target stood at
    cast start** — ground-anchored, never tracking, which is exactly what makes
    the attack winnable by moving well and losable by standing still — and
    resolves it through `World.Caught` (excluding itself; caster filtering is
    this layer's job) into an event stream the future damage, replication and
    presentation children consume. A wind-up of zero is refused at construction:
    an instant telegraph cannot be dodged, and dodgeability is product law. A
    fifth committed golden pins a scripted encounter's event stream. It is a
    controller in the tracker mould — stepped by the caller after `Step`,
    read-only, so it cannot move the movement golden (a test pins that).
    Damage/health, chase movement, factions and interruption are deliberate
    later children (#188 lists them).
- **`wire/`** — the **versioned wire codec**: the transport-agnostic binary
  encoding of the replication payload (the full join snapshot and the per-tick
  delta stream). Every message opens with an explicit protocol version — product
  law requires backward-compatible protocols, so the format is born versioned and
  the decoder refuses anything it does not speak. The layout is canonical
  (fixed-width little-endian, one byte encoding per message value) and the
  decoder fails closed on untrusted bytes: counts are capped before any
  allocation, every read is bounds-checked, truncated or trailing bytes are
  refused, and the sim's ascending-ID list contract is enforced — never
  silently repaired — on both encode and decode. Committed hex goldens pin the
  exact byte layout (the fixture the client-side decoder will be written
  against), and a stream golden pins the codec over the live demo scenario.
  It exists as a pinned contract *before* transport selection, so the socket
  child builds against a settled format instead of inventing one.
- **`agones/`** — the **Agones GameServer lifecycle**: what makes the zone
  binary deployable on the fleet. Agones's contract is hard — a GameServer that
  never calls `Ready` is never allocated, and one that stops calling `Health`
  is killed as unhealthy — so this package speaks exactly that contract through
  the official Agones Go SDK (the server's first dependency): Ready once the
  serving loop is up, Health on a fixed cadence, Shutdown on every exit path.
  It is **opt-in behind the `-agones` flag, default off** — flag off means no
  SDK dial at all, and the lifecycle never touches `sim/`, so no golden can
  move. An unreachable sidecar with the flag on fails loudly, never silently.
  Tests drive the real SDK client against an in-process fake sidecar
  (`agones/agonestest`), at package level and against the built binary in both
  flag states.
- **`cmd/zone/`** — a runnable skeleton server. It boots the demo zone and either
  runs a fixed number of deterministic ticks (printing the state hash) or drives
  the loop from the wall clock. With `-replicate` it also runs the full
  replication pipeline a transport will carry — per-tick tracker delta →
  wire-encode → decode → verify — and prints the payload sizes (the baseline for
  future bandwidth evidence). With `-agones` (`-listen` only — Ready must
  mean a connectable endpoint, and only `-listen` opens one) it registers
  with the local Agones sidecar for its lifetime, so the shape a fleet
  GameServer runs is `-listen` + `-agones`.

```sh
cd server
go run ./cmd/zone                     # 600 deterministic ticks, then the state hash
go run ./cmd/zone -ticks 1800         # a different fixed count
go run ./cmd/zone -realtime -duration 3s   # drive the fixed loop from real time
go run ./cmd/zone -replicate 1        # also wire-encode observer 1's delta stream
go run ./cmd/zone -listen :8443 -tls-cert cert.pem -tls-key key.pem -agones  # fleet GameServer shape
```

## What is deliberately not here yet

Later children of the server-foundation epic
([#4](https://github.com/devantler-tech/world-at-ruin/issues/4), the first child
of the Phase 1 epic [#8](https://github.com/devantler-tech/world-at-ruin/issues/8)):
the socket **transport** and client prediction/reconciliation (the snapshot
*payload* and its wire encoding above are ready; transport selection, sockets,
and the client-side apply of the spawn/update/despawn deltas are the next
layer), real navmesh geometry, the Nakama meta tier, and
Postgres/CNPG persistence. The tick core, its capsule-vs-capsule separation, and
its area-of-interest and snapshot queries land first because everything else is
built on top of a simulation that is already proven deterministic.

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
