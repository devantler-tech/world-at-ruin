// Package sim is the authoritative, deterministic zone-simulation core for a
// World at Ruin zone/dungeon server.
//
// Design constraints it exists to honour (settled server design, AGENTS.md):
//
//   - ONE tick loop per process, never decomposed. The unit of scale is the
//     number of zones, not the number of services inside one zone. A network
//     hop between "player moved" and "was he in the telegraph cone" would
//     re-create the desync the telegraph design exists to avoid.
//   - Physics stays OUT of the authoritative path. Movement is capsule
//     kinematics on a navmesh — no rigid-body physics engine — which is what
//     makes the Go authority cheap, deterministic and latency-tolerant.
//   - Determinism is a product-law requirement (no desync, no undo), so the
//     whole simulation is integer-only and every per-tick iteration runs in a
//     fixed, insertion-order-independent order.
//
// The fixed-timestep tick core lives here: capsule actors integrate a clamped
// intent on a bounded flat navmesh and are then de-overlapped, converging toward
// no two occupying the same space (capsule-vs-capsule separation, see
// separation.go), with a state hash that makes determinism testable.
// Area-of-interest — which entities each observer is told about — is its
// read-only companion query in aoi.go. Networking and client
// prediction/reconciliation, the Agones SDK, and real navmesh geometry are later
// children of the server-foundation epic and deliberately absent here.
package sim

import (
	"encoding/binary"
	"hash/fnv"
	"sort"
)

// TickHz is the authoritative simulation rate: the world advances in fixed
// steps of exactly 1/TickHz seconds. Fixing the rate is what lets identical
// inputs produce an identical tick sequence regardless of host speed.
const TickHz = 30

// maxWorldExtentMM bounds a legal world coordinate on each axis (±1 km). The
// bound guarantees HorizontalLen's squared sum cannot overflow int64 and keeps
// a zone a tractable size. NewWorld rejects bounds outside it.
const maxWorldExtentMM = 1_000_000

// maxIntentComponentMM bounds each component of a stored movement intent.
// Intent is the one untrusted, client-supplied field on an entity, so it is
// sanitised the moment it enters the world (SetIntent, Add). The bound is
// astronomically above any legitimate speed (1e9 mm/s = 1000 km/s) yet small
// enough that:
//   - HorizontalLen's X*X + Z*Z cannot overflow int64 (2e18 < 9.2e18), so a
//     hostile client can neither crash the single authoritative zone loop via
//     an isqrt panic on a wrapped-negative sum, nor slip past the speed cap via
//     a wrapped-small positive length; and
//   - clampSpeed's directional rescale v*maxSpeed/speed cannot overflow either
//     (that multiply only runs when speed > maxSpeed, so both factors are then
//     below ~1.41e9, product < 2e18).
//
// clampSpeed still caps the sanitised intent to the entity's real MaxSpeed, so
// this bound never touches legitimate motion — it only defuses garbage input.
const maxIntentComponentMM = 1_000_000_000

// maxRadiusMM bounds a capsule radius (100 m — far larger than any real actor,
// small enough to keep the separation arithmetic overflow-free). Radius feeds
// the separation push, so like intent it is clamped on ingestion (see Add):
// the radius sum stays <=2e5 and the scale product position*radius stays
// <=4e11, both far below the int64 ceiling, so no crafted or buggy spawn can
// overflow the single authoritative tick loop.
const maxRadiusMM = 100_000

// EntityID identifies a simulated actor. The step iterates entities in
// ascending EntityID order (never Go map order, which is randomised), so the
// tick result is independent of the order entities were added — a determinism
// requirement.
type EntityID uint64

// Entity is a capsule actor on the navmesh. The authoritative path never runs a
// physics engine over it: Intent is the desired ground velocity this tick and
// the world integrates it as capsule kinematics.
type Entity struct {
	ID  EntityID
	Pos Vec3 // world position, mm

	// Intent is the desired velocity for the next step, in mm/s, as set from
	// player input or server-side AI. It is clamped to MaxSpeed before it is
	// applied, so an actor can never move faster than its cap however large an
	// intent an untrusted client asks for.
	Intent Vec3

	// MaxSpeed caps ground speed in mm/s. Zero pins the actor in place.
	MaxSpeed int64

	// Radius is the capsule radius in mm, bounded to maxRadiusMM on ingestion.
	// The separation pass reads it to keep actors from overlapping; a zero (or
	// negative, clamped to zero) radius is a point capsule that never separates.
	Radius int64

	// InterestRadius is the horizontal (ground-plane) distance in mm within
	// which this entity, as an observer, is told about other entities — its
	// area-of-interest (see aoi.go). It is server-configured, not untrusted
	// client input, but it is still clamped into [0, maxInterestRadiusMM] on
	// ingestion so the squared-distance comparison in World.Interest can never
	// overflow. Zero means the observer sees nothing. It is not part of the
	// hashed state (Hash captures step results, not query configuration), so a
	// world's movement golden is unaffected by an entity's interest radius.
	InterestRadius int64
}

// Bounds is the axis-aligned navmesh extent. Positions are clamped inside it
// every step. A flat plane is enough for the skeleton; real navmesh geometry
// is a later child.
type Bounds struct {
	Min, Max Vec3
}

func (b Bounds) clamp(p Vec3) Vec3 {
	return Vec3{
		X: clampAxis(p.X, b.Min.X, b.Max.X),
		Y: clampAxis(p.Y, b.Min.Y, b.Max.Y),
		Z: clampAxis(p.Z, b.Min.Z, b.Max.Z),
	}
}

func clampAxis(v, lo, hi int64) int64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// World is one zone's authoritative state. It is owned by exactly one goroutine
// (the tick loop); it holds no locks because it is never stepped concurrently.
type World struct {
	// Tick is the number of fixed steps executed since creation. It is part of
	// the hashed state so a divergence in tick count is caught too.
	Tick uint64

	bounds Bounds
	ents   map[EntityID]*Entity
	order  []EntityID // ascending EntityID; rebuilt when the membership changes
}

// NewWorld creates an empty world with the given navmesh bounds. It panics if
// the bounds are inverted or exceed maxWorldExtentMM: an illegal zone size is a
// programming error, and the simulation must never silently run in a degenerate
// space.
func NewWorld(bounds Bounds) *World {
	if bounds.Min.X > bounds.Max.X || bounds.Min.Y > bounds.Max.Y || bounds.Min.Z > bounds.Max.Z {
		panic("sim: inverted world bounds")
	}
	for _, v := range []int64{
		bounds.Min.X, bounds.Min.Y, bounds.Min.Z,
		bounds.Max.X, bounds.Max.Y, bounds.Max.Z,
	} {
		if v < -maxWorldExtentMM || v > maxWorldExtentMM {
			panic("sim: world bounds exceed the maximum zone extent")
		}
	}
	return &World{bounds: bounds, ents: make(map[EntityID]*Entity)}
}

// Add inserts a copy of e (clamped into bounds) and returns a pointer to the
// stored entity. It panics on a duplicate ID: entity identity is meaningful and
// a silent overwrite would be a determinism-corrupting bug.
func (w *World) Add(e Entity) *Entity {
	if _, exists := w.ents[e.ID]; exists {
		panic("sim: duplicate entity ID")
	}
	stored := e
	stored.Pos = w.bounds.clamp(stored.Pos)
	stored.Intent = sanitizeIntent(stored.Intent)
	stored.Radius = clampAxis(stored.Radius, 0, maxRadiusMM)
	stored.InterestRadius = clampAxis(stored.InterestRadius, 0, maxInterestRadiusMM)
	w.ents[e.ID] = &stored
	w.order = append(w.order, e.ID)
	sort.Slice(w.order, func(i, j int) bool { return w.order[i] < w.order[j] })
	return &stored
}

// Get returns the stored entity for id, or nil if there is none.
func (w *World) Get(id EntityID) *Entity { return w.ents[id] }

// Count returns the number of entities in the world.
func (w *World) Count() int { return len(w.order) }

// SetIntent sets an entity's desired velocity (mm/s) for the next step. The
// intent is untrusted client input, so it is sanitised on the way in (see
// sanitizeIntent) — a hostile or buggy client can never feed the simulation a
// value that overflows the tick arithmetic. It is a no-op for an unknown ID.
func (w *World) SetIntent(id EntityID, intent Vec3) {
	if e := w.ents[id]; e != nil {
		e.Intent = sanitizeIntent(intent)
	}
}

// SetInterestRadius sets an entity's area-of-interest radius (mm), clamped into
// [0, maxInterestRadiusMM] so World.Interest stays overflow-safe. It is a no-op
// for an unknown ID. Interest radius is server-configured, so this is an
// operator/AI knob, not an untrusted-client surface.
func (w *World) SetInterestRadius(id EntityID, radius int64) {
	if e := w.ents[id]; e != nil {
		e.InterestRadius = clampAxis(radius, 0, maxInterestRadiusMM)
	}
}

// sanitizeIntent clamps every component of an untrusted intent into
// [-maxIntentComponentMM, maxIntentComponentMM], upholding the world invariant
// that stored intent can never overflow HorizontalLen or clampSpeed. Direction
// is preserved for any realistic value (all far below the bound); only
// pathological garbage is trimmed, and clampSpeed then enforces the real speed.
func sanitizeIntent(v Vec3) Vec3 {
	return Vec3{
		X: clampAxis(v.X, -maxIntentComponentMM, maxIntentComponentMM),
		Y: clampAxis(v.Y, -maxIntentComponentMM, maxIntentComponentMM),
		Z: clampAxis(v.Z, -maxIntentComponentMM, maxIntentComponentMM),
	}
}

// Step advances the world by exactly one fixed tick. For each entity, in
// ascending-ID order, it clamps the intent to the entity's max speed, converts
// the per-second velocity into a per-tick displacement by integer division, and
// clamps the new position into the navmesh bounds. Integer division truncates
// toward zero — deterministically — so the same inputs always yield the same
// positions. It then resolves capsule overlap (see separate), driving the
// tick's final state toward no two actors sharing the same space — exactly for
// an isolated pair, and convergently (within a few ticks) for a dense pile-up.
func (w *World) Step() {
	for _, id := range w.order {
		e := w.ents[id]
		v := clampSpeed(e.Intent, e.MaxSpeed)
		// mm/s / (ticks/s) = mm/tick.
		disp := Vec3{X: v.X / TickHz, Y: v.Y / TickHz, Z: v.Z / TickHz}
		e.Pos = w.bounds.clamp(e.Pos.Add(disp))
	}
	w.separate()
	w.Tick++
}

// clampSpeed limits the horizontal (ground-plane) speed of v to maxSpeed mm/s,
// preserving direction by integer scaling. The vertical component passes
// through unchanged (there is no vertical speed cap yet). A non-positive
// maxSpeed pins the actor.
func clampSpeed(v Vec3, maxSpeed int64) Vec3 {
	if maxSpeed <= 0 {
		return Vec3{}
	}
	speed := v.HorizontalLen()
	if speed <= maxSpeed {
		return v
	}
	return Vec3{
		X: v.X * maxSpeed / speed,
		Y: v.Y,
		Z: v.Z * maxSpeed / speed,
	}
}

// Hash returns an order-stable FNV-1a digest of the entire world state (tick
// count plus every entity's ID and position, in ascending-ID order). Two worlds
// that have received identical inputs must return the same hash at every tick;
// a divergence is an immediate, testable determinism failure. Intent and the
// static caps are excluded because Hash captures the *result* of a step, not
// its pending inputs.
func (w *World) Hash() uint64 {
	h := fnv.New64a()
	var buf [8]byte
	put := func(v uint64) {
		binary.LittleEndian.PutUint64(buf[:], v)
		_, _ = h.Write(buf[:])
	}
	put(w.Tick)
	for _, id := range w.order {
		e := w.ents[id]
		put(uint64(id))
		put(uint64(e.Pos.X))
		put(uint64(e.Pos.Y))
		put(uint64(e.Pos.Z))
	}
	return h.Sum64()
}
