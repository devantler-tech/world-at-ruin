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
- **`cmd/zone/`** — a runnable skeleton server. It boots the demo zone and either
  runs a fixed number of deterministic ticks (printing the state hash) or drives
  the loop from the wall clock.

```sh
cd server
go run ./cmd/zone                     # 600 deterministic ticks, then the state hash
go run ./cmd/zone -ticks 1800         # a different fixed count
go run ./cmd/zone -realtime -duration 3s   # drive the fixed loop from real time
```

## What is deliberately not here yet

Later children of the server-foundation epic
([#4](https://github.com/devantler-tech/world-at-ruin/issues/4), the first child
of the Phase 1 epic [#8](https://github.com/devantler-tech/world-at-ruin/issues/8)):
networking and client prediction/reconciliation (the layer that will consume the
area-of-interest deltas above), capsule-vs-capsule resolution, real navmesh
geometry, the Agones SDK integration and GameServer health, the Nakama meta tier,
and Postgres/CNPG persistence. The tick core and its area-of-interest query land
first because everything else is built on top of a simulation that is already
proven deterministic.

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
