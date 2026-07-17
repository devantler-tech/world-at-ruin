package sim

import (
	"math"
	"testing"
)

// bigBounds is a roomy zone that never interferes with a separation assertion
// (the bounds clamp is tested separately; here we want pushes to land in open
// space).
var bigBounds = Bounds{
	Min: Vec3{X: -maxWorldExtentMM, Y: -maxWorldExtentMM, Z: -maxWorldExtentMM},
	Max: Vec3{X: maxWorldExtentMM, Y: maxWorldExtentMM, Z: maxWorldExtentMM},
}

// horizontalGap returns the ground-plane distance between two entities.
func horizontalGap(a, b *Entity) int64 {
	return a.Pos.Sub(b.Pos).HorizontalLen()
}

// TestSeparationPushesOverlappingApart is the core guarantee: two capsules that
// start overlapping are, after one tick, no longer overlapping (within the one
// or two mm of slack integer scaling can leave). A single relaxation pass fully
// resolves an isolated pair.
func TestSeparationPushesOverlappingApart(t *testing.T) {
	w := NewWorld(bigBounds)
	// Radii sum to 1000 mm; start them 400 mm apart on X — a 600 mm overlap.
	w.Add(Entity{ID: 1, Pos: Vec3{X: -200}, MaxSpeed: 0, Radius: 500})
	w.Add(Entity{ID: 2, Pos: Vec3{X: 200}, MaxSpeed: 0, Radius: 500})
	w.Step()
	gap := horizontalGap(w.Get(1), w.Get(2))
	const rsum = 1000
	if gap < rsum-2 {
		t.Fatalf("still overlapping after one tick: gap=%d, want >= %d", gap, rsum-2)
	}
	// The push is purely horizontal — the vertical axis must be untouched.
	if y := w.Get(1).Pos.Y; y != 0 {
		t.Fatalf("separation moved entity 1 vertically: Y=%d", y)
	}
}

// TestSeparationResolvesAgainstWall is the regression guard for the wall-clamp
// invariant break (Codex P1): when one capsule is pinned against a zone bound,
// its half of the separation push is otherwise discarded by the bounds clamp
// and the pair stays overlapping. The movable side must absorb the blocked
// push so the pair still fully separates, with the pinned actor left on the
// wall. Codex's exact counterexample: east bound X=1000, radius-500 actors at
// X=500 and X=1000.
func TestSeparationResolvesAgainstWall(t *testing.T) {
	b := Bounds{Min: Vec3{X: -3000, Y: 0, Z: -2000}, Max: Vec3{X: 1000, Y: 0, Z: 2000}}
	w := NewWorld(b)
	w.Add(Entity{ID: 1, Pos: Vec3{X: 500}, MaxSpeed: 0, Radius: 500})
	w.Add(Entity{ID: 2, Pos: Vec3{X: 1000}, MaxSpeed: 0, Radius: 500}) // pinned at the east wall
	w.Step()
	if gap := horizontalGap(w.Get(1), w.Get(2)); gap < 1000 {
		t.Fatalf("wall-pinned pair still overlaps: gap=%d, want >= 1000", gap)
	}
	if x := w.Get(2).Pos.X; x != 1000 {
		t.Fatalf("wall-pinned entity moved off the wall: X=%d, want 1000", x)
	}
	if x := w.Get(1).Pos.X; x != 0 {
		t.Fatalf("movable entity did not absorb the full push: X=%d, want 0", x)
	}
}

// TestSeparationHoldsInvariantAgainstWallWhilePushed is the dynamic half of the
// same P1: an actor continually driving into a wall-pinned actor must never
// sustain an overlap — every tick ends with the pair at least the radius sum
// apart, and the pinned actor never leaves the wall.
func TestSeparationHoldsInvariantAgainstWallWhilePushed(t *testing.T) {
	b := Bounds{Min: Vec3{X: -3000, Y: 0, Z: -1000}, Max: Vec3{X: 1000, Y: 0, Z: 1000}}
	w := NewWorld(b)
	w.Add(Entity{ID: 1, Pos: Vec3{X: -200}, MaxSpeed: 6000, Radius: 500})
	w.Add(Entity{ID: 2, Pos: Vec3{X: 1000}, MaxSpeed: 0, Radius: 500}) // pinned at the east wall
	for i := range 200 {
		w.SetIntent(1, Vec3{X: 500000}) // slam east into the pinned actor every tick
		w.Step()
		if gap := horizontalGap(w.Get(1), w.Get(2)); gap < 1000 {
			t.Fatalf("invariant broke against the wall at tick %d: gap=%d, want >= 1000", i+1, gap)
		}
		if x := w.Get(2).Pos.X; x != 1000 {
			t.Fatalf("pinned actor pushed off the wall at tick %d: X=%d", i+1, x)
		}
	}
}

// TestSeparationExactOverlapDeterministic covers the degenerate case where two
// actors share the exact same millimetre: the separation axis is undefined, so
// it must be chosen from the IDs (higher ID east) and the two must end apart.
func TestSeparationExactOverlapDeterministic(t *testing.T) {
	build := func() *World {
		w := NewWorld(bigBounds)
		w.Add(Entity{ID: 1, Pos: Vec3{X: 0, Z: 0}, MaxSpeed: 0, Radius: 400})
		w.Add(Entity{ID: 2, Pos: Vec3{X: 0, Z: 0}, MaxSpeed: 0, Radius: 400})
		return w
	}
	w := build()
	w.Step()
	// Higher ID (2) goes +X, lower ID (1) goes -X.
	if x := w.Get(2).Pos.X; x <= 0 {
		t.Fatalf("higher-ID entity did not move east: X=%d", x)
	}
	if x := w.Get(1).Pos.X; x >= 0 {
		t.Fatalf("lower-ID entity did not move west: X=%d", x)
	}
	if gap := horizontalGap(w.Get(1), w.Get(2)); gap < 800-2 {
		t.Fatalf("coincident actors not separated to the radius sum: gap=%d", gap)
	}
	// Determinism: a second identical run yields identical positions.
	w2 := build()
	w2.Step()
	if w.Get(1).Pos != w2.Get(1).Pos || w.Get(2).Pos != w2.Get(2).Pos {
		t.Fatal("coincident separation was not deterministic across runs")
	}
}

// TestSeparationCoincidentPicksRoomyAxis is the regression guard for the
// coincident-axis P1: two exactly-coincident actors in a corridor too narrow on
// X to fit them must separate along the roomy Z axis instead of jamming into the
// near X walls.
func TestSeparationCoincidentPicksRoomyAxis(t *testing.T) {
	// X span 600 (< the 1000 mm radius sum); Z span 10 000 (roomy).
	b := Bounds{Min: Vec3{X: -300, Y: 0, Z: -5000}, Max: Vec3{X: 300, Y: 0, Z: 5000}}
	w := NewWorld(b)
	w.Add(Entity{ID: 1, Pos: Vec3{X: 0, Z: 0}, MaxSpeed: 0, Radius: 500})
	w.Add(Entity{ID: 2, Pos: Vec3{X: 0, Z: 0}, MaxSpeed: 0, Radius: 500})
	w.Step()
	if gap := horizontalGap(w.Get(1), w.Get(2)); gap < 1000-separationSlopMM {
		t.Fatalf("coincident pair in a thin-X corridor not separated: gap=%d, want >= %d", gap, 1000-separationSlopMM)
	}
	// Separation happened along Z (the roomy axis), not the cramped X.
	if w.Get(1).Pos.Z == 0 && w.Get(2).Pos.Z == 0 {
		t.Fatal("coincident pair jammed on the cramped X axis instead of using Z")
	}
	if w.Get(2).Pos.Z <= w.Get(1).Pos.Z {
		t.Fatal("higher-ID actor should take the positive Z direction (deterministic)")
	}
}

// TestSeparationInsertionOrderIndependent extends the determinism law to the
// separation path: two worlds seeded with the same overlapping actors in a
// different Add order must hold an identical hash at every tick.
func TestSeparationInsertionOrderIndependent(t *testing.T) {
	seed := []Entity{
		{ID: 1, Pos: Vec3{X: 0, Z: 0}, MaxSpeed: 0, Radius: 600},
		{ID: 2, Pos: Vec3{X: 300, Z: 0}, MaxSpeed: 0, Radius: 600},
		{ID: 3, Pos: Vec3{X: 150, Z: 200}, MaxSpeed: 0, Radius: 600},
		{ID: 4, Pos: Vec3{X: -100, Z: 100}, MaxSpeed: 0, Radius: 600},
	}
	build := func(order []int) *World {
		w := NewWorld(bigBounds)
		for _, i := range order {
			w.Add(seed[i])
		}
		return w
	}
	a := build([]int{0, 1, 2, 3})
	b := build([]int{3, 1, 0, 2})
	for i := range 300 {
		a.Step()
		b.Step()
		if ha, hb := a.Hash(), b.Hash(); ha != hb {
			t.Fatalf("separation broke insertion-order independence at tick %d: %#016x != %#016x", i+1, ha, hb)
		}
	}
}

// TestSeparationConvergesCluster confirms a tight cluster of mutually
// overlapping actors converges to a fully non-overlapping arrangement within a
// handful of ticks — the multi-pass relaxation plus repetition across ticks
// resolves the whole neighbourhood, not just isolated pairs.
func TestSeparationConvergesCluster(t *testing.T) {
	w := NewWorld(bigBounds)
	const r = 500
	// Five actors packed inside a 200 mm box — everything overlaps everything.
	for id, p := range []Vec3{
		{X: 0, Z: 0}, {X: 100, Z: 0}, {X: -100, Z: 50},
		{X: 50, Z: 100}, {X: -50, Z: -100},
	} {
		w.Add(Entity{ID: EntityID(id + 1), Pos: p, MaxSpeed: 0, Radius: r})
	}
	for range 60 {
		w.Step()
	}
	// Every pair must now be apart to within the penetration tolerance.
	ids := []EntityID{1, 2, 3, 4, 5}
	for i := range ids {
		for j := i + 1; j < len(ids); j++ {
			if gap := horizontalGap(w.Get(ids[i]), w.Get(ids[j])); gap < 2*r-separationSlopMM {
				t.Fatalf("pair (%d,%d) never separated: gap=%d, want >= %d", ids[i], ids[j], gap, 2*r-separationSlopMM)
			}
		}
	}
}

// TestSeparationDenseCrowdConverges is the regression guard for the dense-crowd
// P1: a tight pile-up does not fully separate in a single tick, but it must
// converge — over a few ticks — to within the penetration tolerance, and once
// settled it must stay settled. Codex's case: 50 radius-500 actors packed into
// a 5×10 grid at 10 mm spacing (every actor overlapping many neighbours).
func TestSeparationDenseCrowdConverges(t *testing.T) {
	const r = 500
	build := func() *World {
		w := NewWorld(bigBounds)
		id := EntityID(1)
		for row := 0; row < 5; row++ {
			for col := 0; col < 10; col++ {
				w.Add(Entity{ID: id, Pos: Vec3{X: int64(col) * 10, Z: int64(row) * 10}, MaxSpeed: 0, Radius: r})
				id++
			}
		}
		return w
	}
	minGap := func(w *World) int64 {
		m := int64(1) << 60
		for i := range w.order {
			for j := i + 1; j < len(w.order); j++ {
				if g := w.Get(w.order[i]).Pos.Sub(w.Get(w.order[j]).Pos).HorizontalLen(); g < m {
					m = g
				}
			}
		}
		return m
	}

	// A single tick does NOT fully resolve the pile — that is expected and is
	// what makes this a convergent relaxation, not an unbounded single-tick solve.
	one := build()
	one.Step()
	if minGap(one) >= 2*r-separationSlopMM {
		t.Fatal("dense pile fully resolved in one tick — the convergent-relaxation premise changed; revisit the docs")
	}

	// Within a handful of ticks it converges to within tolerance, and stays there.
	w := build()
	for range 20 {
		w.Step()
	}
	if got := minGap(w); got < 2*r-separationSlopMM {
		t.Fatalf("dense crowd did not converge: minGap=%d, want >= %d", got, 2*r-separationSlopMM)
	}
	settled := minGap(w)
	for range 20 {
		w.Step()
	}
	if got := minGap(w); got < settled {
		t.Fatalf("dense crowd regressed after settling: %d -> %d", settled, got)
	}
}

// TestSeparationNoOpWhenApart proves separation never perturbs actors that are
// not overlapping: with intent zero and a comfortable gap, positions are
// unchanged tick after tick. This is what lets the demo golden hash stay stable
// unless actors actually collide.
func TestSeparationNoOpWhenApart(t *testing.T) {
	w := NewWorld(bigBounds)
	w.Add(Entity{ID: 1, Pos: Vec3{X: -5_000}, MaxSpeed: 0, Radius: 300})
	w.Add(Entity{ID: 2, Pos: Vec3{X: 5_000}, MaxSpeed: 0, Radius: 300})
	before1, before2 := w.Get(1).Pos, w.Get(2).Pos
	for range 100 {
		w.Step()
	}
	if w.Get(1).Pos != before1 || w.Get(2).Pos != before2 {
		t.Fatalf("separation moved non-overlapping actors: %+v %+v", w.Get(1).Pos, w.Get(2).Pos)
	}
}

// TestSeparationTouchingIsAllowed pins the boundary: capsules exactly the radius
// sum apart are touching, not overlapping, and must not be pushed.
func TestSeparationTouchingIsAllowed(t *testing.T) {
	w := NewWorld(bigBounds)
	w.Add(Entity{ID: 1, Pos: Vec3{X: 0}, MaxSpeed: 0, Radius: 500})
	w.Add(Entity{ID: 2, Pos: Vec3{X: 1000}, MaxSpeed: 0, Radius: 500}) // exactly 1000 apart
	w.Step()
	if w.Get(1).Pos.X != 0 || w.Get(2).Pos.X != 1000 {
		t.Fatalf("touching capsules were pushed: %d %d", w.Get(1).Pos.X, w.Get(2).Pos.X)
	}
}

// TestAddClampsRadius covers the ingestion guard: a negative radius becomes a
// point capsule (0) and an absurd radius is capped to maxRadiusMM.
func TestAddClampsRadius(t *testing.T) {
	w := NewWorld(bigBounds)
	if got := w.Add(Entity{ID: 1, Radius: -5}).Radius; got != 0 {
		t.Fatalf("negative radius not clamped to 0: %d", got)
	}
	if got := w.Add(Entity{ID: 2, Radius: math.MaxInt64}).Radius; got != maxRadiusMM {
		t.Fatalf("huge radius not clamped to maxRadiusMM: %d", got)
	}
}

// TestSeparationHostileRadiusNoOverflow is the overflow regression guard,
// paralleling the hostile-intent test: even radii pushed to the ingestion bound
// and actors at opposite world extents must resolve without panicking the
// authoritative loop or wrapping the push arithmetic.
func TestSeparationHostileRadiusNoOverflow(t *testing.T) {
	w := NewWorld(bigBounds)
	// Both clamped to maxRadiusMM; placed so they deeply overlap.
	w.Add(Entity{ID: 1, Pos: Vec3{X: -1000, Z: -1000}, MaxSpeed: 0, Radius: math.MaxInt64})
	w.Add(Entity{ID: 2, Pos: Vec3{X: 1000, Z: 1000}, MaxSpeed: 0, Radius: math.MaxInt64})
	for range 200 {
		w.Step() // must not panic or wrap
	}
	// With both radii at the 100 m cap they still push apart, not toward.
	if gap := horizontalGap(w.Get(1), w.Get(2)); gap <= 2828 { // initial ~2828 mm
		t.Fatalf("hostile-radius pair did not separate: gap=%d", gap)
	}
}

// separationGoldenHash pins the exact settled state of a dense, deeply
// overlapping cluster after separationGoldenTicks fixed steps. Like the tick
// core's demoGoldenHash, the whole separation solve is integer-only, so this
// hash is identical on every architecture — it is the cross-platform
// determinism proof for the separation math specifically (isqrt of the
// separation axis, integer push scaling), not just for movement. Changing it is
// a deliberate, reviewed act.
const separationGoldenTicks = 300
const separationGoldenHash uint64 = 0x2988c8ccaf02e984

// buildSeparationGoldenWorld seeds eight radius-700 actors packed so every one
// overlaps its neighbours (MaxSpeed 0, no intent — only the separation pass
// moves them). It settles to a fully non-overlapping arrangement well before
// the golden tick count.
func buildSeparationGoldenWorld() *World {
	w := NewWorld(DemoBounds)
	const r = 700
	seeds := []Vec3{
		{X: 0, Z: 0}, {X: 200, Z: 100}, {X: -150, Z: 150},
		{X: 100, Z: -200}, {X: -250, Z: -100}, {X: 300, Z: 250},
		{X: -300, Z: 0}, {X: 0, Z: 350},
	}
	for i, p := range seeds {
		w.Add(Entity{ID: EntityID(i + 1), Pos: p, MaxSpeed: 0, Radius: r})
	}
	return w
}

func TestSeparationGoldenHash(t *testing.T) {
	w := buildSeparationGoldenWorld()
	for range separationGoldenTicks {
		w.Step()
	}
	if got := w.Hash(); got != separationGoldenHash {
		t.Fatalf("separation cluster hash after %d ticks = %#016x, want %#016x\n"+
			"if this change to separation behaviour is intentional, update separationGoldenHash",
			separationGoldenTicks, got, separationGoldenHash)
	}
	// The settled cluster must actually be non-overlapping — the golden pins the
	// exact state, this asserts that state is the correct one.
	const r = 700
	ids := []EntityID{1, 2, 3, 4, 5, 6, 7, 8}
	for i := range ids {
		for j := i + 1; j < len(ids); j++ {
			if gap := horizontalGap(w.Get(ids[i]), w.Get(ids[j])); gap < 2*r-separationSlopMM {
				t.Fatalf("golden cluster still overlaps at pair (%d,%d): gap=%d", ids[i], ids[j], gap)
			}
		}
	}
}

// TestSeparationZeroRadiusNeverSeparates confirms point capsules (radius 0) are
// allowed to coincide — there is no extent to resolve, so the pass leaves them.
func TestSeparationZeroRadiusNeverSeparates(t *testing.T) {
	w := NewWorld(bigBounds)
	w.Add(Entity{ID: 1, Pos: Vec3{X: 0, Z: 0}, MaxSpeed: 0, Radius: 0})
	w.Add(Entity{ID: 2, Pos: Vec3{X: 0, Z: 0}, MaxSpeed: 0, Radius: 0})
	w.Step()
	if w.Get(1).Pos != (Vec3{}) || w.Get(2).Pos != (Vec3{}) {
		t.Fatalf("zero-radius actors were separated: %+v %+v", w.Get(1).Pos, w.Get(2).Pos)
	}
}
