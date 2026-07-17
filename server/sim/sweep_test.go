package sim

import "testing"

// wideBounds is a zone large enough that the swept-collision tests never hit a
// wall — so any clamping observed is the sweep, never bounds.clamp.
var wideBounds = Bounds{
	Min: Vec3{X: -maxWorldExtentMM, Y: 0, Z: -maxWorldExtentMM},
	Max: Vec3{X: maxWorldExtentMM, Y: 4_000, Z: maxWorldExtentMM},
}

// horizDist2 is the squared ground-plane distance between two positions, in mm².
func horizDist2(a, b Vec3) int64 {
	dx, dz := a.X-b.X, a.Z-b.Z
	return dx*dx + dz*dz
}

// TestSweepPreventsTunneling is the #66 success signal: an actor driven at more
// than a combined-radius per tick straight at another must not pass through it.
// Without the swept pass it would teleport out the far side (proved by the
// no-obstacle control); with it, it stops on the near side, never closer than
// the contact surface.
func TestSweepPreventsTunneling(t *testing.T) {
	const (
		rA, rB   = int64(300), int64(300)
		rEff     = rA + rB - separationSlopMM // 592: the depth separation would act at
		bx       = int64(2_500)               // stationary target sits here on +X
		maxSpeed = int64(150_000)             // 150 m/s ⇒ 5 000 mm per 30 Hz tick
	)

	// Control: with no obstacle the charger reaches its full 5 000 mm step, so
	// absent the sweep it would indeed cross clean past bx=2 500.
	free := NewWorld(wideBounds)
	free.Add(Entity{ID: 1, Pos: Vec3{}, MaxSpeed: maxSpeed, Radius: rA})
	free.SetIntent(1, Vec3{X: maxSpeed})
	free.Step()
	if got := free.Get(1).Pos.X; got != 5_000 {
		t.Fatalf("control: unobstructed charger moved to X=%d, want 5000 (per-tick step)", got)
	}

	w := NewWorld(wideBounds)
	w.Add(Entity{ID: 1, Pos: Vec3{}, MaxSpeed: maxSpeed, Radius: rA})
	w.Add(Entity{ID: 2, Pos: Vec3{X: bx}, MaxSpeed: 0, Radius: rB}) // stationary wall
	w.SetIntent(1, Vec3{X: maxSpeed})
	w.Step()

	a, b := w.Get(1).Pos, w.Get(2).Pos
	if a.X >= b.X {
		t.Fatalf("charger tunneled: ended at X=%d, at/past the obstacle at X=%d", a.X, b.X)
	}
	// Never crossed into the contact surface: the ground-plane gap stayed at or
	// beyond rEff (the sweep stops at a lower bound on true contact, so the gap is
	// rEff or a touch more, never less).
	if got, min := horizDist2(a, b), rEff*rEff; got < min {
		t.Fatalf("charger crossed the contact surface: gap²=%d < rEff²=%d (a=%v b=%v)", got, min, a, b)
	}
	// And it genuinely stopped short of the free-run target, i.e. the sweep fired.
	if a.X > b.X-rEff {
		t.Fatalf("charger not stopped outside the contact surface: X=%d, want ≤ %d", a.X, b.X-rEff)
	}
	// The obstacle never moved (the stop is at ≈slop penetration, which separation
	// treats as resolved).
	if b.X != bx {
		t.Fatalf("stationary obstacle moved to X=%d, want %d", b.X, bx)
	}
}

// TestSweepStopsAtFirstOfManyObstacles: a charger crossing a line of obstacles
// must stop at the nearest one, regardless of the order they were added.
func TestSweepStopsAtFirstOfManyObstacles(t *testing.T) {
	const maxSpeed = int64(300_000) // 10 000 mm/tick
	build := func(addOrder []EntityID) *World {
		w := NewWorld(wideBounds)
		pos := map[EntityID]Vec3{
			1: {X: 0},     // charger
			2: {X: 6_000}, // far obstacle
			3: {X: 3_000}, // near obstacle — the one it should hit first
		}
		for _, id := range addOrder {
			e := Entity{ID: id, Pos: pos[id], Radius: 300}
			if id == 1 {
				e.MaxSpeed = maxSpeed
			}
			w.Add(e)
		}
		return w
	}
	a := build([]EntityID{1, 2, 3})
	b := build([]EntityID{3, 2, 1}) // reverse insertion order
	for _, w := range []*World{a, b} {
		w.SetIntent(1, Vec3{X: maxSpeed})
		w.Step()
	}
	if a.Hash() != b.Hash() {
		t.Fatalf("swept stop depended on insertion order: %#016x != %#016x", a.Hash(), b.Hash())
	}
	// Stopped just outside the NEAR obstacle at X=3000, not the far one at 6000.
	const rEff = 300 + 300 - separationSlopMM
	if x := a.Get(1).Pos.X; x >= 3_000 || x < 3_000-rEff-16 {
		t.Fatalf("charger did not stop at the near obstacle: X=%d, want just below %d", x, 3_000-rEff)
	}
}

// TestSweepDeterministicAndRepeatable: two identical worlds stay bit-identical,
// tick after tick, with a fast mover crossing traffic — the determinism law.
func TestSweepDeterministicAndRepeatable(t *testing.T) {
	build := func() *World {
		w := NewWorld(wideBounds)
		w.Add(Entity{ID: 1, Pos: Vec3{X: -8_000}, MaxSpeed: 300_000, Radius: 300})
		w.Add(Entity{ID: 2, Pos: Vec3{X: 0}, MaxSpeed: 2_000, Radius: 400})
		w.Add(Entity{ID: 3, Pos: Vec3{X: 0, Z: 1_500}, MaxSpeed: 2_000, Radius: 400})
		return w
	}
	a, b := build(), build()
	for i := range 300 {
		for _, w := range []*World{a, b} {
			w.SetIntent(1, Vec3{X: 300_000})
			w.SetIntent(2, Vec3{Z: 2_000})
			w.SetIntent(3, Vec3{Z: -2_000})
			w.Step()
		}
		if a.Hash() != b.Hash() {
			t.Fatalf("swept sim diverged at tick %d: %#016x != %#016x", i+1, a.Hash(), b.Hash())
		}
	}
}

// TestFirstContactFrac exercises the swept narrow phase directly, covering the
// crossing/no-crossing boundary the golden-preservation relies on.
func TestFirstContactFrac(t *testing.T) {
	const ra, rb = int64(300), int64(300)
	const rEff = ra + rb - separationSlopMM // 592
	from := Vec3{}
	target := Vec3{X: 5_000} // a 5 m eastward step

	tests := []struct {
		name    string
		from    Vec3
		target  Vec3
		center  Vec3
		wantHit bool
	}{
		{"head-on tunnel", from, target, Vec3{X: 2_500}, true},
		{"ends inside contact distance", from, target, Vec3{X: 4_800}, false},
		{"starts inside contact distance", Vec3{X: 2_400}, target, Vec3{X: 2_500}, false},
		{"moving away from centre", from, Vec3{X: -5_000}, Vec3{X: 2_500}, false},
		{"parallel miss", from, target, Vec3{X: 2_500, Z: 2_000}, false},
		{"graze within the slop (below rEff depth)", from, target, Vec3{X: 2_500, Z: 596}, false},
		{"graze past rEff depth", from, target, Vec3{X: 2_500, Z: 580}, true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			frac := firstContactFrac(tc.from, tc.target, ra, tc.center, rb)
			if (frac != nil) != tc.wantHit {
				t.Fatalf("firstContactFrac hit=%v, want %v (frac=%v)", frac != nil, tc.wantHit, frac)
			}
			if frac == nil {
				return
			}
			// A hit's stop position must sit outside the contact surface (never
			// having crossed it) and at or before the true entry point.
			dx := tc.target.X - tc.from.X
			dz := tc.target.Z - tc.from.Z
			stop := Vec3{
				X: tc.from.X + fracMulTrunc(frac, dx),
				Z: tc.from.Z + fracMulTrunc(frac, dz),
			}
			if got := horizDist2(stop, tc.center); got < rEff*rEff {
				t.Fatalf("stop is inside the contact surface: gap²=%d < rEff²=%d (stop=%v)", got, rEff*rEff, stop)
			}
		})
	}
}

// TestSweepNoOpForSlowApproach: an actor stepping less than a capsule toward
// another is left entirely to separation — the sweep does not clamp it, so it
// integrates to its full target (which separation then de-overlaps). This is the
// property that keeps the sweep inert for realistic movement.
func TestSweepNoOpForSlowApproach(t *testing.T) {
	// A single slow mover with an obstacle out of its one-tick reach: it must
	// land exactly on its integrated target, untouched by the sweep.
	w := NewWorld(wideBounds)
	w.Add(Entity{ID: 1, Pos: Vec3{}, MaxSpeed: 6_000, Radius: 300}) // 200 mm/tick
	w.Add(Entity{ID: 2, Pos: Vec3{X: 5_000}, MaxSpeed: 0, Radius: 300})
	w.SetIntent(1, Vec3{X: 6_000})
	w.Step()
	if got := w.Get(1).Pos.X; got != 200 {
		t.Fatalf("slow mover clamped by the sweep: X=%d, want 200 (its full integrated step)", got)
	}
}
