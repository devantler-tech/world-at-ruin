package sim

// Replication snapshots turn area-of-interest (aoi.go) — which entities each
// observer is told about — into the actual payload a networking layer (a later
// child of the server-foundation epic) serializes and sends: what state each
// observer needs, and what changed since the last tick. AoI answers membership;
// the snapshot answers state.
//
// Two shapes, both read-only and both built on Interest:
//
//   - A full Snapshot is the whole replicated state an observer should hold this
//     tick — every in-interest entity's id, position and radius, ascending-ID.
//   - A SnapshotDelta is the minimal per-tick update: who ENTERED interest (with
//     their state, to spawn on the client), who MOVED while staying in interest
//     (with new state, to update), and who LEFT (by id, to despawn). A still,
//     in-interest entity appears in none of them, so a client's bandwidth scales
//     with change rather than with zone population.
//
// Like AoI and the tick core, everything here is deterministic and integer-only:
// it reads the same stable ascending-ID order and copies integer fields, so the
// same world yields the same snapshot and the same delta stream on every host.
// None of it is part of Step, so it cannot move the movement golden.

import "sort"

// EntityState is the replicated state of one entity: the fields a remote client
// needs to represent it. Position and radius are what exist to replicate today;
// velocity, orientation, health and the rest arrive with the systems that add
// them, each a later child. It is a pure value type (no pointers), so two states
// compare equal with == exactly when every replicated field matches — which is
// what lets the delta tracker detect a state change cheaply.
type EntityState struct {
	ID     EntityID
	Pos    Vec3
	Radius int64
}

// Snapshot is the authoritative replicated state a single observer should hold
// after a given tick: the tick number plus the state of every entity in the
// observer's area-of-interest, in ascending-EntityID order. It excludes the
// observer itself (matching Interest); the observer's own reconciliation state
// is a separate replication concern (a later child). It is built read-only from
// world state, never in Step, so it cannot move a golden.
type Snapshot struct {
	Tick     uint64
	Observer EntityID
	Entities []EntityState // ascending ID, in-interest, excludes the observer
}

// Snapshot returns the observer's full replication snapshot for the current
// tick. It is a pure function of world state: the entities come from Interest
// (ascending-ID, boundary-inclusive, self-excluded), so the snapshot is
// deterministic and independent of map iteration order. An unknown observer, or
// one with no interest, yields a snapshot with no entities.
func (w *World) Snapshot(observer EntityID) Snapshot {
	interest := w.Interest(observer)
	s := Snapshot{Tick: w.Tick, Observer: observer}
	if len(interest) == 0 {
		return s
	}
	s.Entities = make([]EntityState, 0, len(interest))
	for _, id := range interest {
		e := w.ents[id]
		s.Entities = append(s.Entities, EntityState{ID: id, Pos: e.Pos, Radius: e.Radius})
	}
	return s
}

// SnapshotDelta is the minimal per-tick replication update for one observer:
// entities that just ENTERED interest (spawn them, with their state), entities
// still in interest whose replicated state CHANGED (update them, with the new
// state), and entities that LEFT interest (despawn them, by id). All three are
// in ascending EntityID order. An in-interest entity whose state is unchanged
// appears in none of them — the bandwidth win over resending a full snapshot.
type SnapshotDelta struct {
	Tick    uint64
	Entered []EntityState
	Moved   []EntityState
	Left    []EntityID
}

// Empty reports whether the delta carries no changes at all, so a caller can
// skip sending anything for this observer this tick.
func (d SnapshotDelta) Empty() bool {
	return len(d.Entered) == 0 && len(d.Moved) == 0 && len(d.Left) == 0
}

// SnapshotTracker follows one observer's replication snapshot across ticks and
// reports the delta each tick. It holds the observer's last snapshot state and
// does no I/O; call Update once per tick (after Step) with the same observer and
// it stays deterministic. It is the state-level companion to InterestTracker:
// where that reports interest-set membership changes, this reports the entity
// STATE the client must apply — spawn, update and despawn — in one pass.
type SnapshotTracker struct {
	observer EntityID
	prev     map[EntityID]EntityState
}

// NewSnapshotTracker returns a tracker for the given observer with an empty
// prior snapshot, so its first Update reports every in-interest entity as
// entered and nothing as moved or left.
func NewSnapshotTracker(observer EntityID) *SnapshotTracker {
	return &SnapshotTracker{observer: observer, prev: make(map[EntityID]EntityState)}
}

// Update recomputes the observer's snapshot from the world's current state and
// returns the delta since the previous call: entities newly in interest
// (entered, with state), entities still in interest whose replicated state
// changed (moved, with new state), and entities no longer in interest (left, by
// id). Entered and Moved are drawn from the ascending snapshot, so they are
// ascending without a re-sort; Left is drained from a map and sorted. Update is
// a pure function of world state plus the tracker's own prior snapshot, so
// replaying the same tick sequence yields the same delta stream on every host.
func (t *SnapshotTracker) Update(w *World) SnapshotDelta {
	snap := w.Snapshot(t.observer)
	d := SnapshotDelta{Tick: snap.Tick}
	next := make(map[EntityID]EntityState, len(snap.Entities))
	for _, es := range snap.Entities { // ascending ID
		next[es.ID] = es
		switch prev, was := t.prev[es.ID]; {
		case !was:
			d.Entered = append(d.Entered, es)
		case prev != es:
			d.Moved = append(d.Moved, es)
		}
	}
	for id := range t.prev {
		if _, still := next[id]; !still {
			d.Left = append(d.Left, id)
		}
	}
	t.prev = next
	// Left is drained from a map, whose iteration order Go randomises, so sort it
	// to stay deterministic. Entered and Moved are already ascending.
	sort.Slice(d.Left, func(i, j int) bool { return d.Left[i] < d.Left[j] })
	return d
}
