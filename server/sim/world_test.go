package sim

import "testing"

// demoGoldenHash pins the exact end state of the shared demo scenario after
// demoGoldenTicks fixed steps. Because the whole simulation is integer-only,
// this hash is identical on every architecture — so this test both guards
// against an accidental change in simulation behaviour AND proves the
// cross-platform determinism the product law requires. Changing it is a
// deliberate act (like updating a golden file); a change to the sim that moves
// it must be reviewed on purpose, never rubber-stamped.
const demoGoldenTicks = 600
const demoGoldenHash uint64 = 0x99cf0bbe914e3ecc

// runDemo runs the shared demo scenario for n ticks and returns the world.
func runDemo(n int) *World {
	w := NewDemoWorld()
	for range n {
		DriveDemoTick(w)
		w.Step()
	}
	return w
}

func TestDemoGoldenHash(t *testing.T) {
	got := runDemo(demoGoldenTicks).Hash()
	if got != demoGoldenHash {
		t.Fatalf("demo scenario hash after %d ticks = %#016x, want %#016x\n"+
			"if this change to simulation behaviour is intentional, update demoGoldenHash",
			demoGoldenTicks, got, demoGoldenHash)
	}
}

// TestStepDeterminismTwoWorlds is the core tick-determinism guarantee: two
// worlds fed identical inputs must hold identical state at every single tick,
// not merely at the end.
func TestStepDeterminismTwoWorlds(t *testing.T) {
	a, b := NewDemoWorld(), NewDemoWorld()
	for i := range 1000 {
		DriveDemoTick(a)
		a.Step()
		DriveDemoTick(b)
		b.Step()
		if ha, hb := a.Hash(), b.Hash(); ha != hb {
			t.Fatalf("determinism broke at tick %d: %#016x != %#016x", i+1, ha, hb)
		}
	}
}

// TestInsertionOrderIndependent proves the step is independent of the order
// entities were added — the reason Step iterates a sorted ID list rather than
// ranging the map (whose order Go randomises).
func TestInsertionOrderIndependent(t *testing.T) {
	build := func(ids []EntityID) *World {
		w := NewWorld(DemoBounds)
		for _, id := range ids {
			w.Add(Entity{ID: id, Pos: Vec3{X: int64(id) * 1000}, MaxSpeed: 5000})
		}
		return w
	}
	a := build([]EntityID{1, 2, 3, 4, 5})
	b := build([]EntityID{5, 3, 1, 4, 2})
	for range 200 {
		for _, w := range []*World{a, b} {
			for _, id := range []EntityID{1, 2, 3, 4, 5} {
				w.SetIntent(id, Vec3{X: 90000, Z: -90000})
			}
			w.Step()
		}
	}
	if a.Hash() != b.Hash() {
		t.Fatalf("insertion order changed the result: %#016x != %#016x", a.Hash(), b.Hash())
	}
}

// TestSpeedClampAxisAligned pins the exact per-tick displacement of an
// axis-aligned mover to maxSpeed/TickHz, truncated.
func TestSpeedClampAxisAligned(t *testing.T) {
	w := NewWorld(DemoBounds)
	w.Add(Entity{ID: 1, Pos: Vec3{}, MaxSpeed: 4000})
	w.SetIntent(1, Vec3{X: 100000}) // far above the 4000 mm/s cap
	w.Step()
	want := Vec3{X: 4000 / TickHz} // 133 mm
	if got := w.Get(1).Pos; got != want {
		t.Fatalf("clamped displacement = %+v, want %+v", got, want)
	}
}

// TestSpeedClampDiagonalBound checks a diagonal mover never exceeds its per-tick
// speed budget in any direction.
func TestSpeedClampDiagonalBound(t *testing.T) {
	const maxSpeed = 5000
	w := NewWorld(DemoBounds)
	w.Add(Entity{ID: 1, Pos: Vec3{}, MaxSpeed: maxSpeed})
	w.SetIntent(1, Vec3{X: 100000, Z: 100000})
	w.Step()
	perTick := int64(maxSpeed/TickHz) + 1 // allow one mm of truncation slack
	got := w.Get(1).Pos
	if got.HorizontalLen() > perTick {
		t.Fatalf("diagonal step moved %d mm, exceeds per-tick budget %d", got.HorizontalLen(), perTick)
	}
}

// TestBoundsClampKeepsInside drives an actor hard into a wall and asserts it
// stops exactly at the boundary and never escapes.
func TestBoundsClampKeepsInside(t *testing.T) {
	b := Bounds{Min: Vec3{X: -1000, Y: 0, Z: -1000}, Max: Vec3{X: 1000, Y: 0, Z: 1000}}
	w := NewWorld(b)
	w.Add(Entity{ID: 1, Pos: Vec3{X: 900}, MaxSpeed: 9000})
	for i := range 100 {
		w.SetIntent(1, Vec3{X: 500000}) // slam east
		w.Step()
		p := w.Get(1).Pos
		if p.X > b.Max.X || p.X < b.Min.X {
			t.Fatalf("escaped bounds at tick %d: X=%d", i+1, p.X)
		}
	}
	if got := w.Get(1).Pos.X; got != b.Max.X {
		t.Fatalf("did not settle on the east wall: X=%d, want %d", got, b.Max.X)
	}
}

// TestZeroMaxSpeedPins confirms a MaxSpeed of 0 makes an entity immovable
// however large its intent.
func TestZeroMaxSpeedPins(t *testing.T) {
	w := NewWorld(DemoBounds)
	w.Add(Entity{ID: 1, Pos: Vec3{X: 100, Z: 200}, MaxSpeed: 0})
	w.SetIntent(1, Vec3{X: 999999, Z: 999999})
	for range 50 {
		w.Step()
	}
	if got := w.Get(1).Pos; got != (Vec3{X: 100, Z: 200}) {
		t.Fatalf("pinned entity moved to %+v", got)
	}
}

func TestISqrt(t *testing.T) {
	cases := []int64{0, 1, 2, 3, 4, 8, 9, 15, 16, 24, 25, 10_000, 1_000_000, 2_000_000_000_000}
	for _, n := range cases {
		r := isqrt(n)
		if r < 0 || r*r > n || (r+1)*(r+1) <= n {
			t.Fatalf("isqrt(%d) = %d violates floor-sqrt property", n, r)
		}
	}
}

func TestISqrtNegativePanics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("isqrt(-1) did not panic")
		}
	}()
	_ = isqrt(-1)
}

func TestAddDuplicateIDPanics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("adding a duplicate ID did not panic")
		}
	}()
	w := NewWorld(DemoBounds)
	w.Add(Entity{ID: 7})
	w.Add(Entity{ID: 7})
}

func TestNewWorldRejectsInvertedBounds(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("inverted bounds did not panic")
		}
	}()
	NewWorld(Bounds{Min: Vec3{X: 100}, Max: Vec3{X: -100}})
}

func TestAddClampsIntoBounds(t *testing.T) {
	b := Bounds{Min: Vec3{X: -100, Y: 0, Z: -100}, Max: Vec3{X: 100, Y: 0, Z: 100}}
	w := NewWorld(b)
	e := w.Add(Entity{ID: 1, Pos: Vec3{X: 999, Y: 999, Z: -999}})
	if e.Pos != (Vec3{X: 100, Y: 0, Z: -100}) {
		t.Fatalf("Add did not clamp spawn into bounds: %+v", e.Pos)
	}
}
