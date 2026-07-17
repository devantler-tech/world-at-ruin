package sim

// Area-of-interest (AoI) is how the authoritative zone decides *which* entities
// each observer is told about. It is the seam the replication layer (a later
// child) builds on: an entity entering an observer's interest is spawned on
// that client, one leaving is despawned. That delta is what upholds the world
// law that "nothing appears from nowhere" — the client is only ever shown
// entities it has been told to expect — and it is what keeps replication
// tractable as zone density grows (broadcasting the whole world to every client
// does not scale).
//
// Like the tick core, AoI is deterministic and integer-only: the query iterates
// entities in the same stable ascending-ID order the step uses, and distance is
// an exact squared-millimetre comparison, so the same world yields the same
// interest set and the same enter/leave events on every architecture. Interest
// is a read-only query over world state; it is never part of Step, so it cannot
// move the movement golden hash.

import "sort"

// maxInterestRadiusMM bounds an entity's area-of-interest radius. The radius is
// server-configured (not untrusted client input), but bounding it keeps the
// squared-distance comparison in Interest overflow-safe for any stored value:
// radius² at the cap is 1.6e13, far below the int64 ceiling. The cap (4e6 mm)
// also exceeds any legal zone's diagonal — a zone spans at most
// 2·maxWorldExtentMM per axis, so its ground diagonal is at most
// 2·√2·maxWorldExtentMM ≈ 2.83e6 mm — so an observer at the cap sees every
// entity in any legal zone.
const maxInterestRadiusMM = 4 * maxWorldExtentMM

// horizontalDist2 returns the squared horizontal (XZ) distance between a and b
// in mm². Squared distance avoids a sqrt in the AoI hot path and keeps the
// comparison exact and integer-only. It is overflow-safe for any two in-bounds
// positions: every position is clamped into ±maxWorldExtentMM (on Add and on
// each Step), so each delta component is at most 2·maxWorldExtentMM (2e6) and
// the sum of squares is at most 8e12 — well below the int64 ceiling.
func horizontalDist2(a, b Vec3) int64 {
	dx := a.X - b.X
	dz := a.Z - b.Z
	return dx*dx + dz*dz
}

// Interest returns the IDs of every other entity within the observer's
// area-of-interest — the set the server would replicate to that observer's
// client this tick. "Within" is a horizontal (ground-plane) distance in mm,
// inclusive of the radius boundary; the vertical axis is ignored, consistent
// with movement being a ground-plane quantity. The result excludes the observer
// itself and is returned in ascending EntityID order, so it is deterministic
// and independent of map iteration order — the same requirement the tick step
// upholds. An unknown observer, or one whose interest radius is zero, yields no
// entities (a nil slice).
func (w *World) Interest(observer EntityID) []EntityID {
	obs := w.ents[observer]
	if obs == nil || obs.InterestRadius <= 0 {
		return nil
	}
	// InterestRadius is clamped to maxInterestRadiusMM on ingestion, so r2
	// cannot overflow (see maxInterestRadiusMM).
	r2 := obs.InterestRadius * obs.InterestRadius
	var out []EntityID
	// w.order is maintained ascending, so out is ascending without a re-sort.
	for _, id := range w.order {
		if id == observer {
			continue
		}
		if horizontalDist2(obs.Pos, w.ents[id].Pos) <= r2 {
			out = append(out, id)
		}
	}
	return out
}

// InterestTracker follows one observer's area-of-interest across ticks and
// reports who ENTERED and who LEFT it since the last update. That delta is
// exactly what a replication layer consumes: an entity entering interest is
// spawned on the client, one leaving is despawned. The tracker holds no clock
// and does no I/O; call Update once per tick (after Step) with the same
// observer, and it stays deterministic.
type InterestTracker struct {
	observer EntityID
	current  map[EntityID]struct{}
}

// NewInterestTracker returns a tracker for the given observer with an empty
// prior interest set, so its first Update reports every currently-interesting
// entity as entered.
func NewInterestTracker(observer EntityID) *InterestTracker {
	return &InterestTracker{observer: observer, current: make(map[EntityID]struct{})}
}

// Update recomputes the observer's interest set from the world's current state
// and returns who entered and who left since the previous call. Both slices are
// in ascending EntityID order and are nil when empty. The first call reports the
// whole current interest set as entered and nothing as left. Update is a pure
// function of the world state plus the tracker's own prior set, so replaying the
// same tick sequence yields the same event stream on every host.
func (t *InterestTracker) Update(w *World) (entered, left []EntityID) {
	next := make(map[EntityID]struct{})
	// Interest returns ascending IDs, so entered is appended ascending.
	for _, id := range w.Interest(t.observer) {
		next[id] = struct{}{}
		if _, was := t.current[id]; !was {
			entered = append(entered, id)
		}
	}
	for id := range t.current {
		if _, still := next[id]; !still {
			left = append(left, id)
		}
	}
	t.current = next
	// left is drained from a map, whose iteration order Go randomises, so it
	// must be sorted to stay deterministic. entered is already ascending.
	sort.Slice(left, func(i, j int) bool { return left[i] < left[j] })
	return entered, left
}
