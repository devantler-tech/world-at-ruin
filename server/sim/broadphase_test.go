package sim

import (
	"fmt"
	"math"
	"slices"
	"testing"
)

// separateFullScan is the pre-broad-phase reference: it scans every actor pair
// once per pass in ascending-ID order through the exact same narrow-phase
// resolvePair. It is the oracle for the cases where the broad phase must match
// the naive scan byte-for-byte (the committed golden cluster and any layout
// whose overlapping clusters stay within a cell neighbourhood while settling).
func separateFullScan(w *World) {
	n := len(w.order)
	if n < 2 {
		return
	}
	for range separationIterations {
		moved := false
		for i := range n {
			a := w.ents[w.order[i]]
			for j := i + 1; j < n; j++ {
				if w.resolvePair(a, w.ents[w.order[j]]) {
					moved = true
				}
			}
		}
		if !moved {
			return
		}
	}
}

// buildFrom seeds a fresh world with the given entities (all separation-oracle
// seeds use MaxSpeed 0, so only the separation pass moves them — the code under
// test).
func buildFrom(bounds Bounds, seed []Entity) *World {
	w := NewWorld(bounds)
	for _, e := range seed {
		w.Add(e)
	}
	return w
}

// packedGrid seeds side×side radius-r actors at the given spacing, offset so the
// block straddles the origin (exercising negative cell coordinates / floorDiv).
func packedGrid(side int, spacing, r int64) []Entity {
	out := make([]Entity, 0, side*side)
	id := EntityID(1)
	off := int64(side) * spacing / 2
	for row := 0; row < side; row++ {
		for col := 0; col < side; col++ {
			out = append(out, Entity{
				ID:     id,
				Pos:    Vec3{X: int64(col)*spacing - off, Z: int64(row)*spacing - off},
				Radius: r,
			})
			id++
		}
	}
	return out
}

// goldenClusterSeed is the committed separation-golden layout (8 radius-700
// actors packed so every one overlaps its neighbours) — small enough that its
// whole settling stays within one cell neighbourhood, so the broad phase must
// match the naive scan on it exactly.
var goldenClusterSeed = []Entity{
	{ID: 1, Pos: Vec3{X: 0, Z: 0}, Radius: 700},
	{ID: 2, Pos: Vec3{X: 200, Z: 100}, Radius: 700},
	{ID: 3, Pos: Vec3{X: -150, Z: 150}, Radius: 700},
	{ID: 4, Pos: Vec3{X: 100, Z: -200}, Radius: 700},
	{ID: 5, Pos: Vec3{X: -250, Z: -100}, Radius: 700},
	{ID: 6, Pos: Vec3{X: 300, Z: 250}, Radius: 700},
	{ID: 7, Pos: Vec3{X: -300, Z: 0}, Radius: 700},
	{ID: 8, Pos: Vec3{X: 0, Z: 350}, Radius: 700},
}

// TestBroadPhaseMatchesFullScan proves the broad phase changes nothing for the
// layouts where a byte-match is the contract: the committed golden cluster, and
// a comfortably-spaced (non-overlapping) field where separation is a pure no-op
// scan. For these the grid separate() and the full-scan reference must agree on
// every actor's position at every tick.
func TestBroadPhaseMatchesFullScan(t *testing.T) {
	cases := map[string]struct {
		seed  []Entity
		ticks int
	}{
		"goldenCluster": {goldenClusterSeed, 300},
		"sparseField":   {packedGrid(10, 3000, 500), 5}, // 2500 mm gaps → nothing overlaps
		"moderate8x8":   {packedGrid(8, 400, 300), 60},  // overlapping but no mid-pass chaining
	}
	for name, cfg := range cases {
		t.Run(name, func(t *testing.T) {
			grid := buildFrom(bigBounds, cfg.seed)
			ref := buildFrom(bigBounds, cfg.seed)
			for tick := 0; tick < cfg.ticks; tick++ {
				grid.separate()
				separateFullScan(ref)
				for _, id := range grid.order {
					if g, r := grid.Get(id).Pos, ref.Get(id).Pos; g != r {
						t.Fatalf("tick %d entity %d diverged from full scan: grid=%+v full-scan=%+v", tick+1, id, g, r)
					}
				}
			}
		})
	}
}

// denseSeeds are pile-ups too dense for a byte-match with the naive scan: a
// chained push carries a third actor into a pair that was *not* overlapping when
// the grid was built, which the full scan (re-testing every pair against live
// positions) catches the same pass but the grid picks up on the next pass's
// fresh grid. Here the broad phase's contract is the sim's real guarantees —
// deterministic, insertion-order independent, convergent to a non-overlapping
// arrangement — not a byte-match. (Moderately-overlapping layouts with no such
// mid-pass chaining *do* byte-match; see moderate8x8 in TestBroadPhaseMatchesFullScan.)
func denseSeeds() map[string]struct {
	seed  []Entity
	ticks int
} {
	return map[string]struct {
		seed  []Entity
		ticks int
	}{
		"crowd5x10": {packedGrid5x10(), 60},
		"packed12":  {packedGrid(12, 10, 500), 120}, // 144 actors inside one radius
		"packed6":   {packedGrid(6, 700, 500), 60},  // radius > spacing → chains
	}
}

func packedGrid5x10() []Entity {
	out := make([]Entity, 0, 50)
	id := EntityID(1)
	for row := 0; row < 5; row++ {
		for col := 0; col < 10; col++ {
			out = append(out, Entity{ID: id, Pos: Vec3{X: int64(col) * 10, Z: int64(row) * 10}, Radius: 500})
			id++
		}
	}
	return out
}

// TestBroadPhaseDeterministic is the reproducibility half of the determinism
// law under the broad phase: the same dense seed stepped twice must produce a
// bit-identical hash at every tick. (Host-independence follows from the
// integer-only cell math; the committed golden hashes prove that separately.)
func TestBroadPhaseDeterministic(t *testing.T) {
	for name, cfg := range denseSeeds() {
		t.Run(name, func(t *testing.T) {
			a := buildFrom(bigBounds, cfg.seed)
			b := buildFrom(bigBounds, cfg.seed)
			for tick := 0; tick < cfg.ticks; tick++ {
				a.separate()
				a.Tick++
				b.separate()
				b.Tick++
				if ha, hb := a.Hash(), b.Hash(); ha != hb {
					t.Fatalf("dense separation not reproducible at tick %d: %#016x != %#016x", tick+1, ha, hb)
				}
			}
		})
	}
}

// TestBroadPhaseInsertionOrderIndependent is the load-bearing half of the
// determinism law: even for a dense pile, the broad phase's result must not
// depend on the order actors were Added (or on Go map iteration order). Two
// worlds seeded with the same dense actors in reversed Add order must hold an
// identical hash at every tick.
func TestBroadPhaseInsertionOrderIndependent(t *testing.T) {
	for name, cfg := range denseSeeds() {
		t.Run(name, func(t *testing.T) {
			fwd := cfg.seed
			rev := make([]Entity, len(fwd))
			for i, e := range fwd {
				rev[len(fwd)-1-i] = e
			}
			a := buildFrom(bigBounds, fwd)
			b := buildFrom(bigBounds, rev)
			for tick := 0; tick < cfg.ticks; tick++ {
				a.separate()
				a.Tick++
				b.separate()
				b.Tick++
				if ha, hb := a.Hash(), b.Hash(); ha != hb {
					t.Fatalf("dense separation broke insertion-order independence at tick %d: %#016x != %#016x", tick+1, ha, hb)
				}
			}
		})
	}
}

// TestBroadPhaseConverges confirms the broad phase still fully de-overlaps a
// dense pile within a handful of ticks — the acceleration must not cost the
// convergence guarantee. After settling, every pair is apart to within the
// penetration tolerance.
func TestBroadPhaseConverges(t *testing.T) {
	for name, cfg := range denseSeeds() {
		t.Run(name, func(t *testing.T) {
			w := buildFrom(bigBounds, cfg.seed)
			for tick := 0; tick < cfg.ticks; tick++ {
				w.separate()
			}
			for i := range w.order {
				for j := i + 1; j < len(w.order); j++ {
					a, b := w.Get(w.order[i]), w.Get(w.order[j])
					rsum := a.Radius + b.Radius
					if gap := a.Pos.Sub(b.Pos).HorizontalLen(); gap < rsum-separationSlopMM {
						t.Fatalf("pair (%d,%d) never separated after %d ticks: gap=%d want >= %d",
							a.ID, b.ID, cfg.ticks, gap, rsum-separationSlopMM)
					}
				}
			}
		})
	}
}

// TestBroadPhaseNeverPrunesAnOverlappingPair is the safety invariant the whole
// design rests on: when the grid is built, every pair that actually overlaps
// must be offered as a candidate of its lower-ID member. If cell sizing or the
// 3×3 neighbourhood were wrong, an overlapping pair could be pruned and left
// intersecting — the one thing the broad phase must never do.
func TestBroadPhaseNeverPrunesAnOverlappingPair(t *testing.T) {
	w := buildFrom(bigBounds, packedGrid(9, 300, 500)) // radius 500 > spacing 300 → dense overlap
	grid := newSepGrid(w, separationCellMM(w))
	offered := map[[2]EntityID]bool{}
	var buf []EntityID
	for _, id := range w.order {
		a := w.ents[id]
		buf = grid.neighbours(a, buf)
		for _, b := range buf {
			offered[[2]EntityID{a.ID, b}] = true
		}
	}
	for i := range w.order {
		for j := i + 1; j < len(w.order); j++ {
			a, b := w.ents[w.order[i]], w.ents[w.order[j]]
			if a.Pos.Sub(b.Pos).HorizontalLen() < a.Radius+b.Radius && !offered[[2]EntityID{a.ID, b.ID}] {
				t.Fatalf("overlapping pair (%d,%d) was pruned by the broad phase", a.ID, b.ID)
			}
		}
	}
}

// TestBroadPhaseQueriesSnapshotCell is the regression guard for the P1 Codex
// caught: a neighbourhood query must key off the actor's cell *at grid-build
// time*, not its live Pos. Within a Gauss-Seidel pass an actor can be pushed
// across a cell boundary (as an earlier pair's partner) before its own turn; if
// the lookup used the moved Pos it would query the wrong cell against the
// build-time buckets and could prune a partner that overlapped it at build time
// and still overlaps it — violating the no-prune invariant and changing the
// bounded-pass result. So moving an actor after the grid is built must NOT
// change the candidates its lookup returns.
func TestBroadPhaseQueriesSnapshotCell(t *testing.T) {
	w := buildFrom(bigBounds, packedGrid(6, 700, 500))
	cell := separationCellMM(w)
	grid := newSepGrid(w, cell)
	a := w.ents[w.order[0]]
	before := slices.Clone(grid.neighbours(a, nil))
	if len(before) == 0 {
		t.Fatal("test setup: expected the lowest-ID actor to have neighbourhood candidates")
	}
	// Simulate a being shoved several cells away before its own turn.
	a.Pos = a.Pos.Add(Vec3{X: 12 * cell, Z: 9 * cell})
	after := slices.Clone(grid.neighbours(a, nil))
	if !slices.Equal(before, after) {
		t.Fatalf("neighbours changed after the actor moved — the lookup used the live position, not the snapshot cell\nbefore=%v\nafter =%v", before, after)
	}
}

// TestSeparationCellMM checks the cell width tracks the largest radius present
// and never drops below 1 mm (point-capsule / empty world).
func TestSeparationCellMM(t *testing.T) {
	if got := separationCellMM(NewWorld(bigBounds)); got != 1 {
		t.Fatalf("empty world cell = %d, want 1", got)
	}
	points := buildFrom(bigBounds, []Entity{{ID: 1, Radius: 0}, {ID: 2, Radius: 0}})
	if got := separationCellMM(points); got != 1 {
		t.Fatalf("point-capsule world cell = %d, want 1", got)
	}
	mixed := buildFrom(bigBounds, []Entity{{ID: 1, Radius: 300}, {ID: 2, Radius: 750}, {ID: 3, Radius: 500}})
	if got := separationCellMM(mixed); got != 1500 {
		t.Fatalf("mixed world cell = %d, want 1500 (2×max radius)", got)
	}
}

// TestFloorDiv pins the flooring semantics the uniform tiling depends on:
// negative coordinates must floor (not truncate toward zero) so cells straddle
// the origin without a doubled-width cell at 0.
func TestFloorDiv(t *testing.T) {
	cases := []struct{ a, cell, want int64 }{
		{0, 1000, 0}, {999, 1000, 0}, {1000, 1000, 1},
		{-1, 1000, -1}, {-1000, 1000, -1}, {-1001, 1000, -2},
	}
	for _, c := range cases {
		if got := floorDiv(c.a, c.cell); got != c.want {
			t.Fatalf("floorDiv(%d,%d) = %d, want %d", c.a, c.cell, got, c.want)
		}
	}
}

// benchSeparation times one separation pass over n radius-500 actors on a
// non-overlapping grid (spacing 2000 mm > the 1000 mm radius sum), so the pass
// is a pure no-op scan — exactly where the O(n²) full scan hurts and the broad
// phase wins. Comparing grid vs fullscan across n shows the scaling.
func benchSeparation(b *testing.B, n int, full bool) {
	side := int(math.Ceil(math.Sqrt(float64(n))))
	const r, spacing = 500, 2000
	w := NewWorld(bigBounds)
	for i := 0; i < n; i++ {
		w.Add(Entity{ID: EntityID(i + 1), Pos: Vec3{X: int64(i%side) * spacing, Z: int64(i/side) * spacing}, Radius: r})
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if full {
			separateFullScan(w)
		} else {
			w.separate()
		}
	}
}

func BenchmarkSeparation(b *testing.B) {
	for _, n := range []int{64, 256, 1024, 4096} {
		b.Run(fmt.Sprintf("grid/n=%d", n), func(b *testing.B) { benchSeparation(b, n, false) })
		b.Run(fmt.Sprintf("fullscan/n=%d", n), func(b *testing.B) { benchSeparation(b, n, true) })
	}
}
