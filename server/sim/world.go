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
// This first slice is the fixed-timestep tick core: capsule actors integrating
// a clamped intent on a bounded flat navmesh, with a state hash that makes
// determinism testable. Networking, the Agones SDK, area-of-interest, and
// capsule-vs-capsule resolution are later children of the server-foundation
// epic and deliberately absent here.
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

	// Radius is the capsule radius in mm. It is carried now so entity data is
	// forward-compatible; capsule-vs-capsule separation is a later child and
	// does not read it yet.
	Radius int64
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
	w.ents[e.ID] = &stored
	w.order = append(w.order, e.ID)
	sort.Slice(w.order, func(i, j int) bool { return w.order[i] < w.order[j] })
	return &stored
}

// Get returns the stored entity for id, or nil if there is none.
func (w *World) Get(id EntityID) *Entity { return w.ents[id] }

// Count returns the number of entities in the world.
func (w *World) Count() int { return len(w.order) }

// SetIntent sets an entity's desired velocity (mm/s) for the next step. It is a
// no-op for an unknown ID.
func (w *World) SetIntent(id EntityID, intent Vec3) {
	if e := w.ents[id]; e != nil {
		e.Intent = intent
	}
}

// Step advances the world by exactly one fixed tick. For each entity, in
// ascending-ID order, it clamps the intent to the entity's max speed, converts
// the per-second velocity into a per-tick displacement by integer division, and
// clamps the new position into the navmesh bounds. Integer division truncates
// toward zero — deterministically — so the same inputs always yield the same
// positions.
func (w *World) Step() {
	for _, id := range w.order {
		e := w.ents[id]
		v := clampSpeed(e.Intent, e.MaxSpeed)
		// mm/s / (ticks/s) = mm/tick.
		disp := Vec3{X: v.X / TickHz, Y: v.Y / TickHz, Z: v.Z / TickHz}
		e.Pos = w.bounds.clamp(e.Pos.Add(disp))
	}
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
