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

// TestSweptFlagGatesBehaviour is the feature-flag contract: with the flag OFF
// (the default, under which every settled golden is pinned) a fast mover tunnels
// clean through a stationary actor — the discrete-collision gap #66 exists to
// close — and with the flag ON the same mover is stopped on the near side.
func TestSweptFlagGatesBehaviour(t *testing.T) {
	const (
		r        = int64(300)
		bx       = int64(2_500) // stationary obstacle
		maxSpeed = int64(150_000)
	)
	build := func(swept bool) *World {
		w := NewWorld(wideBounds)
		w.SweptCollision = swept
		w.Add(Entity{ID: 1, Pos: Vec3{}, MaxSpeed: maxSpeed, Radius: r})
		w.Add(Entity{ID: 2, Pos: Vec3{X: bx}, MaxSpeed: 0, Radius: r})
		w.SetIntent(1, Vec3{X: maxSpeed}) // 5 000 mm/tick, well past the obstacle
		w.Step()
		return w
	}

	off := build(false)
	if x := off.Get(1).Pos.X; x <= bx {
		t.Fatalf("flag OFF should reproduce the tunnel: charger at X=%d, expected past the obstacle at %d", x, bx)
	}

	on := build(true)
	a, b := on.Get(1).Pos, on.Get(2).Pos
	if a.X >= b.X {
		t.Fatalf("flag ON tunneled: charger at X=%d, at/past the obstacle at X=%d", a.X, b.X)
	}
	const rsum = 2 * 300
	if got := horizDist2(a, b); got < rsum*rsum-2*rsum { // allow the ~mm of integer slack
		t.Fatalf("flag ON crossed the contact surface: gap²=%d, want ≈ rsum²=%d (a=%v b=%v)", got, rsum*rsum, a, b)
	}
	if b.X != bx {
		t.Fatalf("stationary obstacle moved to X=%d, want %d", b.X, bx)
	}
}

// TestSweptMutualApproach covers Codex finding #1: when BOTH actors move, a
// static-obstacle sweep would let them swap places (each target sits where the
// other started). Relative motion must catch it — they meet at contact, mid-way,
// and never cross.
func TestSweptMutualApproach(t *testing.T) {
	w := NewWorld(wideBounds)
	w.SweptCollision = true
	w.Add(Entity{ID: 1, Pos: Vec3{X: 0}, MaxSpeed: 150_000, Radius: 300})
	w.Add(Entity{ID: 2, Pos: Vec3{X: 5_000}, MaxSpeed: 150_000, Radius: 300})
	w.SetIntent(1, Vec3{X: 150_000})  // →
	w.SetIntent(2, Vec3{X: -150_000}) // ←
	w.Step()
	a, b := w.Get(1).Pos, w.Get(2).Pos
	if a.X >= b.X {
		t.Fatalf("actors passed through each other: 1 at X=%d, 2 at X=%d", a.X, b.X)
	}
	const rsum = 600
	if got := horizDist2(a, b); got < rsum*rsum-2*rsum {
		t.Fatalf("mutual approach crossed contact: gap²=%d, want ≈ %d (a=%v b=%v)", got, rsum*rsum, a, b)
	}
}

// TestSweptCrossedCentreEndpointInside covers Codex finding #6: a fast mover
// whose target lies *inside* the obstacle but *beyond its centre* must be caught
// at first contact on the near side — not waved through to be pushed out the far
// side by separation.
func TestSweptCrossedCentreEndpointInside(t *testing.T) {
	w := NewWorld(wideBounds)
	w.SweptCollision = true
	w.Add(Entity{ID: 1, Pos: Vec3{X: 0}, MaxSpeed: 90_000, Radius: 300}) // 3 000 mm/tick
	w.Add(Entity{ID: 2, Pos: Vec3{X: 2_500}, MaxSpeed: 0, Radius: 300})
	w.SetIntent(1, Vec3{X: 90_000}) // target X=3000: past the centre at 2500, still inside rsum
	w.Step()
	if x := w.Get(1).Pos.X; x >= 2_500 {
		t.Fatalf("mover crossed the obstacle centre: X=%d, want stopped on the near side (< 2500)", x)
	}
}

// TestSweptInitialOverlapDirectional covers Codex finding #5: an actor that
// begins overlapping another may move *apart* freely, but a fast move *through*
// it must be blocked (it would otherwise exit the far side before separation
// runs).
func TestSweptInitialOverlapDirectional(t *testing.T) {
	// Start overlapping: gap 400 < rsum 600.
	build := func(intentX int64) *World {
		w := NewWorld(wideBounds)
		w.SweptCollision = true
		w.Add(Entity{ID: 1, Pos: Vec3{X: 0}, MaxSpeed: 150_000, Radius: 300})
		w.Add(Entity{ID: 2, Pos: Vec3{X: 400}, MaxSpeed: 0, Radius: 300})
		w.SetIntent(1, Vec3{X: intentX})
		w.Step()
		return w
	}
	// Moving away (−X): allowed — the mover reaches its full step.
	away := build(-150_000)
	if x := away.Get(1).Pos.X; x != -5_000 {
		t.Fatalf("overlapped mover moving apart was blocked: X=%d, want -5000", x)
	}
	// Moving through (+X, toward and past the obstacle): blocked — must not exit
	// the far side.
	through := build(150_000)
	if x := through.Get(1).Pos.X; x >= 400 {
		t.Fatalf("overlapped mover tunneled through: X=%d, want held on the near side (< 400)", x)
	}
}

// TestSweptMultiBodyPropagation covers the multi-body propagation finding: when
// one mover is stopped short, a follower swept against that mover must be
// re-tested against its *shortened* trajectory. A single pass would clamp the
// follower against a leader that "kept going" and place it beyond where the
// leader actually stopped — a crossing separation cannot repair, because the
// final endpoints do not overlap.
func TestSweptMultiBodyPropagation(t *testing.T) {
	w := NewWorld(wideBounds)
	w.SweptCollision = true
	// Leader: big and fast, stopped early by the small static post.
	w.Add(Entity{ID: 1, Pos: Vec3{X: 0}, MaxSpeed: 150_000, Radius: 500})
	// Follower: comes from far west along a parallel lane, misses the post but
	// must not overrun the leader.
	w.Add(Entity{ID: 2, Pos: Vec3{X: -5_000, Z: 500}, MaxSpeed: 300_000, Radius: 100})
	// Static post: stops the leader at X ≈ 2500-600 = 1900.
	w.Add(Entity{ID: 3, Pos: Vec3{X: 2_500}, MaxSpeed: 0, Radius: 100})
	w.SetIntent(1, Vec3{X: 150_000})
	w.SetIntent(2, Vec3{X: 300_000})
	w.Step()

	leader, follower := w.Get(1).Pos, w.Get(2).Pos
	if leader.X >= 2_500 {
		t.Fatalf("leader was not stopped by the post: X=%d", leader.X)
	}
	// The follower must be stopped behind the leader's ACTUAL stop, not swept
	// against the leader's original 5 000 mm target.
	if follower.X > leader.X {
		t.Fatalf("follower overran the stopped leader: follower X=%d, leader X=%d", follower.X, leader.X)
	}
	const rsum = 500 + 100
	if got := horizDist2(leader, follower); got < rsum*rsum-8*rsum {
		t.Fatalf("follower crossed into the leader: gap²=%d, want ≈ %d (leader=%v follower=%v)",
			got, rsum*rsum, leader, follower)
	}
}

// TestSweptDeterministicAndOrderIndependent: with the flag on, the result is
// bit-identical across runs and independent of insertion order — the
// determinism law.
func TestSweptDeterministicAndOrderIndependent(t *testing.T) {
	build := func(order []EntityID) *World {
		w := NewWorld(wideBounds)
		w.SweptCollision = true
		pos := map[EntityID]Vec3{
			1: {X: -8_000}, 2: {X: 0}, 3: {X: 0, Z: 1_500}, 4: {X: 3_000, Z: -800},
		}
		spd := map[EntityID]int64{1: 300_000, 2: 2_000, 3: 2_000, 4: 120_000}
		for _, id := range order {
			w.Add(Entity{ID: id, Pos: pos[id], MaxSpeed: spd[id], Radius: 300})
		}
		return w
	}
	a := build([]EntityID{1, 2, 3, 4})
	b := build([]EntityID{4, 2, 1, 3})
	for i := range 200 {
		for _, w := range []*World{a, b} {
			w.SetIntent(1, Vec3{X: 300_000})
			w.SetIntent(2, Vec3{Z: 2_000})
			w.SetIntent(3, Vec3{Z: -2_000})
			w.SetIntent(4, Vec3{X: -120_000})
			w.Step()
		}
		if a.Hash() != b.Hash() {
			t.Fatalf("swept sim diverged at tick %d: %#016x != %#016x", i+1, a.Hash(), b.Hash())
		}
	}
}

// TestSweptGoldenHash pins a deterministic swept scenario cross-platform, the
// same discipline as the demo and AoI goldens: integer-only arithmetic makes the
// hash identical on every architecture, so a change to swept behaviour must be a
// deliberate, reviewed act.
func TestSweptGoldenHash(t *testing.T) {
	const ticks = 400
	const want uint64 = 0x5e7555d35e293f6f
	run := func(swept bool) *World {
		w := NewWorld(wideBounds)
		w.SweptCollision = swept
		// A fast shuttling charger crossing a slow line of actors.
		w.Add(Entity{ID: 1, Pos: Vec3{X: -9_000}, MaxSpeed: 240_000, Radius: 300})
		w.Add(Entity{ID: 2, Pos: Vec3{X: 0}, MaxSpeed: 3_000, Radius: 350})
		w.Add(Entity{ID: 3, Pos: Vec3{X: 1_200, Z: 900}, MaxSpeed: 3_000, Radius: 350})
		w.Add(Entity{ID: 4, Pos: Vec3{X: 2_400, Z: -900}, MaxSpeed: 3_000, Radius: 400})
		for i := range ticks {
			dir := int64(240_000)
			if (i/60)%2 == 1 {
				dir = -dir // reverse the charger every 60 ticks so it recrosses the line
			}
			w.SetIntent(1, Vec3{X: dir})
			w.SetIntent(2, Vec3{Z: 3_000})
			w.SetIntent(3, Vec3{Z: -3_000})
			w.SetIntent(4, Vec3{X: 3_000})
			w.Step()
		}
		return w
	}
	got := run(true).Hash()
	if got != want {
		t.Fatalf("swept scenario hash after %d ticks = %#016x, want %#016x\n"+
			"if this change to swept behaviour is intentional, update the golden", ticks, got, want)
	}
	// The golden is only meaningful if swept collision actually shapes the run:
	// the same scenario with the flag off must land somewhere different.
	if off := run(false).Hash(); off == want {
		t.Fatalf("swept and non-swept runs are identical (%#016x) — the golden scenario does not exercise the sweep", off)
	}
}

// TestFirstContactFrac exercises the swept narrow phase directly, in the pair's
// relative frame.
func TestFirstContactFrac(t *testing.T) {
	const r = int64(300)
	fast := Vec3{X: 5_000} // a 5 m eastward step for the mover
	stay := Vec3{}         // a stationary obstacle displacement

	tests := []struct {
		name                   string
		iFrom, iTo, jFrom, jTo Vec3
		wantHit                bool
		wantHold               bool // hit whose expected clamp is t=0 (hold at start)
	}{
		{name: "head-on, obstacle static", iFrom: Vec3{}, iTo: fast, jFrom: Vec3{X: 2_500}, jTo: Vec3{X: 2_500}, wantHit: true},
		{name: "mutual approach", iFrom: Vec3{}, iTo: fast, jFrom: Vec3{X: 5_000}, jTo: Vec3{}, wantHit: true},
		{name: "moving away", iFrom: Vec3{X: 1_000}, iTo: Vec3{X: 6_000}, jFrom: Vec3{}, jTo: Vec3{}, wantHit: false},
		{name: "parallel miss", iFrom: Vec3{}, iTo: fast, jFrom: Vec3{X: 2_500, Z: 2_000}, jTo: Vec3{X: 2_500, Z: 2_000}, wantHit: false},
		{name: "no relative motion (same velocity)", iFrom: Vec3{}, iTo: fast, jFrom: Vec3{X: 700}, jTo: Vec3{X: 5_700}, wantHit: false},
		{name: "start overlapped, closing", iFrom: Vec3{}, iTo: fast, jFrom: Vec3{X: 400}, jTo: stay, wantHit: true, wantHold: true},
		{name: "start overlapped, separating", iFrom: Vec3{X: 3_200}, iTo: Vec3{X: 8_000}, jFrom: Vec3{X: 2_800}, jTo: Vec3{X: 2_800}, wantHit: false},
		{name: "contact only next tick", iFrom: Vec3{}, iTo: Vec3{X: 500}, jFrom: Vec3{X: 5_000}, jTo: Vec3{X: 5_000}, wantHit: false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			frac := firstContactFrac(tc.iFrom, tc.iTo, r, tc.jFrom, tc.jTo, r)
			if (frac != nil) != tc.wantHit {
				t.Fatalf("firstContactFrac hit=%v, want %v (frac=%v)", frac != nil, tc.wantHit, frac)
			}
			if frac == nil {
				return
			}
			if tc.wantHold {
				// An actor already overlapping and closing holds at t=0 — separation
				// then resolves the pre-existing overlap; the sweep only forbids it
				// from closing further this tick.
				if frac.Sign() != 0 {
					t.Fatalf("expected a hold (t=0) for an overlapped closing mover, got %v", frac)
				}
				return
			}
			// Otherwise the clamped mover must be at or before true contact: the
			// relative gap at the clamp fraction is not inside the contact surface by
			// more than the few mm of integer slack.
			dix := tc.iTo.X - tc.iFrom.X
			diz := tc.iTo.Z - tc.iFrom.Z
			djx := tc.jTo.X - tc.jFrom.X
			djz := tc.jTo.Z - tc.jFrom.Z
			iAt := Vec3{X: tc.iFrom.X + fracMulTrunc(frac, dix), Z: tc.iFrom.Z + fracMulTrunc(frac, diz)}
			jAt := Vec3{X: tc.jFrom.X + fracMulTrunc(frac, djx), Z: tc.jFrom.Z + fracMulTrunc(frac, djz)}
			const rsum = 2 * 300
			if got := horizDist2(iAt, jAt); got < rsum*rsum-4*rsum {
				t.Fatalf("clamp is inside the contact surface: gap²=%d, want ≈ %d", got, rsum*rsum)
			}
		})
	}
}
