package sim

// Regression tests for authoritative telegraph resolution (issue #88).
//
// The load-bearing law is that the server's answer matches the client's
// prediction (client/scripts/telegraph.gd), so these mirror that library's
// cases deliberately: cardinals, INCLUSIVE edges, behind-the-caster exclusion,
// the ring's safe hole, a rotated beam, and Y-invariance. They also pin what is
// specific to the authoritative tier: ascending-ID resolution, a committed
// golden over a resolution event stream, and the guarantee that resolution — a
// read-only query, never part of Step — leaves the movement golden untouched.

import (
	"encoding/binary"
	"hash/fnv"
	"reflect"
	"testing"
)

// Cosines of the half-angles used below, scaled by CosScale. Precomputed as
// integers because the authoritative path never calls a trig function.
const (
	cos45Scaled  = 707_107   // cos(45°)
	cos60Scaled  = 500_000   // cos(60°)
	cos90Scaled  = 0         // cos(90°)
	cos180Scaled = -CosScale // cos(180°) — degenerates to a full disc
)

// --- Circle ---------------------------------------------------------------

func TestCircleCatchesInsideAndEdgeButNotBeyond(t *testing.T) {
	const r = 10_000
	tg := CircleTelegraph(Vec3{}, r)
	cases := []struct {
		name string
		p    Vec3
		want bool
	}{
		{"centre", Vec3{}, true},
		{"inside", Vec3{X: 5_000}, true},
		{"exactly on the edge", Vec3{X: r}, true},
		{"one mm past the edge", Vec3{X: r + 1}, false},
		{"diagonal inside", Vec3{X: 7_000, Z: 7_000}, true},   // 9.899 m
		{"diagonal outside", Vec3{X: 7_100, Z: 7_100}, false}, // 10.041 m
	}
	for _, c := range cases {
		if got := tg.Catches(c.p); got != c.want {
			t.Errorf("circle r=%d Catches(%v) = %v, want %v (%s)", r, c.p, got, c.want, c.name)
		}
	}
}

// TestCircleIgnoresVertical proves membership is a ground-plane question: a
// target's height never changes whether it is caught, matching the client.
func TestCircleIgnoresVertical(t *testing.T) {
	tg := CircleTelegraph(Vec3{}, 10_000)
	if !tg.Catches(Vec3{X: 5_000, Y: 1_000_000}) {
		t.Error("a horizontally-inside target high above the shape must still be caught")
	}
	if tg.Catches(Vec3{X: 50_000, Y: 0}) {
		t.Error("a horizontally-outside target at the same height must not be caught")
	}
}

// TestNegativeExtentCatchesNothing pins the degenerate case the client also
// honours: a negative extent is not an error, it simply catches nothing.
func TestNegativeExtentCatchesNothing(t *testing.T) {
	for _, tg := range []Telegraph{
		CircleTelegraph(Vec3{}, -1),
		RingTelegraph(Vec3{}, -5_000, -1),
		ConeTelegraph(Vec3{}, Vec3{X: 1_000}, -1, cos60Scaled),
		RectTelegraph(Vec3{}, Vec3{X: 1_000}, -1, 5_000),
		RectTelegraph(Vec3{}, Vec3{X: 1_000}, 10_000, -1),
	} {
		if tg.Catches(Vec3{}) {
			t.Errorf("kind %d with a negative extent must catch nothing, even at its own origin", tg.Kind)
		}
	}
}

// --- Ring -----------------------------------------------------------------

func TestRingHasASafeHoleAndInclusiveBand(t *testing.T) {
	const inner, outer = 5_000, 10_000
	tg := RingTelegraph(Vec3{}, inner, outer)
	cases := []struct {
		name string
		p    Vec3
		want bool
	}{
		{"centre is in the safe hole", Vec3{}, false},
		{"just inside the inner radius is safe", Vec3{X: inner - 1}, false},
		{"exactly on the inner radius is caught", Vec3{X: inner}, true},
		{"mid-band", Vec3{X: 7_500}, true},
		{"exactly on the outer radius is caught", Vec3{X: outer}, true},
		{"one mm beyond the rim is safe", Vec3{X: outer + 1}, false},
	}
	for _, c := range cases {
		if got := tg.Catches(c.p); got != c.want {
			t.Errorf("ring [%d,%d] Catches(%v) = %v, want %v (%s)", inner, outer, c.p, got, c.want, c.name)
		}
	}
}

// TestRingAcceptsRadiiInEitherOrderAndClampsNegativeInner mirrors the client's
// tolerance: the radii may be swapped, and a negative inner means a filled disc.
func TestRingAcceptsRadiiInEitherOrderAndClampsNegativeInner(t *testing.T) {
	swapped := RingTelegraph(Vec3{}, 10_000, 5_000)
	if !swapped.Catches(Vec3{X: 7_500}) || swapped.Catches(Vec3{X: 2_000}) {
		t.Error("a ring given its radii in either order must behave identically")
	}
	filled := RingTelegraph(Vec3{}, -5_000, 10_000)
	if !filled.Catches(Vec3{}) {
		t.Error("a negative inner radius must degenerate to a filled disc (centre caught)")
	}
}

// --- Cone -----------------------------------------------------------------

func TestConeCatchesForwardWedgeOnly(t *testing.T) {
	const reach = 10_000
	// Apex at the origin, opening toward +X, 60° to each side.
	tg := ConeTelegraph(Vec3{}, Vec3{X: 1_000}, reach, cos60Scaled)
	cases := []struct {
		name string
		p    Vec3
		want bool
	}{
		{"the apex itself is inside", Vec3{}, true},
		{"straight ahead", Vec3{X: 5_000}, true},
		{"exactly at reach, straight ahead", Vec3{X: reach}, true},
		{"one mm past reach", Vec3{X: reach + 1}, false},
		{"45° off the facing is within 60°", Vec3{X: 3_000, Z: 3_000}, true},
		{"90° off the facing is outside 60°", Vec3{Z: 3_000}, false},
		{"directly behind the caster", Vec3{X: -3_000}, false},
	}
	for _, c := range cases {
		if got := tg.Catches(c.p); got != c.want {
			t.Errorf("cone(60°, reach %d) Catches(%v) = %v, want %v (%s)", reach, c.p, got, c.want, c.name)
		}
	}
}

// TestConeAngularEdgeIsInclusive uses a 90° half-angle, whose boundary is exact
// in integer arithmetic (the perpendicular has a dot product of exactly zero),
// so the inclusive-edge law can be pinned without any rounding slack.
func TestConeAngularEdgeIsInclusive(t *testing.T) {
	tg := ConeTelegraph(Vec3{}, Vec3{X: 1_000}, 10_000, cos90Scaled)
	if !tg.Catches(Vec3{Z: 5_000}) {
		t.Error("exactly on a 90° cone's angular edge must be caught (edges are inclusive)")
	}
	if !tg.Catches(Vec3{Z: -5_000}) {
		t.Error("the other angular edge must be caught too")
	}
	if tg.Catches(Vec3{X: -1, Z: 5_000}) {
		t.Error("one mm behind the angular edge must be safe")
	}
}

// TestConeAt180DegreesIsAFullDisc mirrors the client's clamp: the widest cone
// degenerates to a disc of its reach.
func TestConeAt180DegreesIsAFullDisc(t *testing.T) {
	tg := ConeTelegraph(Vec3{}, Vec3{X: 1_000}, 10_000, cos180Scaled)
	for _, p := range []Vec3{{X: 5_000}, {X: -5_000}, {Z: 5_000}, {Z: -5_000}} {
		if !tg.Catches(p) {
			t.Errorf("a 180° cone must catch %v in every direction within reach", p)
		}
	}
	if tg.Catches(Vec3{X: -10_001}) {
		t.Error("a 180° cone must still respect its reach")
	}
}

// TestConeDegenerateFacingFallsBackToWorldForward pins the same fallback the
// client makes, so a zero facing yields a deterministic shape rather than a NaN.
func TestConeDegenerateFacingFallsBackToWorldForward(t *testing.T) {
	tg := ConeTelegraph(Vec3{}, Vec3{}, 10_000, cos45Scaled)
	if !tg.Catches(Vec3{Z: -5_000}) {
		t.Error("a degenerate facing must open toward world-forward (-Z)")
	}
	if tg.Catches(Vec3{Z: 5_000}) {
		t.Error("a degenerate facing must not open backward (+Z)")
	}
}

// TestConeRotatedFacingTracksTheDirection proves the wedge follows an arbitrary
// unnormalised facing rather than a hard-coded axis.
func TestConeRotatedFacingTracksTheDirection(t *testing.T) {
	// Facing -Z, a deliberately large unnormalised vector.
	tg := ConeTelegraph(Vec3{}, Vec3{Z: -750_000}, 10_000, cos45Scaled)
	if !tg.Catches(Vec3{Z: -5_000}) {
		t.Error("straight along a -Z facing must be caught")
	}
	if tg.Catches(Vec3{X: 5_000}) {
		t.Error("90° off a -Z facing must be outside a 45° cone")
	}
}

func TestConeIgnoresVertical(t *testing.T) {
	tg := ConeTelegraph(Vec3{}, Vec3{X: 1_000}, 10_000, cos60Scaled)
	if !tg.Catches(Vec3{X: 5_000, Y: -900_000}) {
		t.Error("a horizontally-inside target far below must still be caught")
	}
}

// --- Rect (beam) ----------------------------------------------------------

func TestRectIsABeamFromItsNearEdge(t *testing.T) {
	const length, halfWidth = 20_000, 2_000
	tg := RectTelegraph(Vec3{}, Vec3{X: 1_000}, length, halfWidth)
	cases := []struct {
		name string
		p    Vec3
		want bool
	}{
		{"on the near edge", Vec3{}, true},
		{"along the beam", Vec3{X: 10_000}, true},
		{"exactly at the far end", Vec3{X: length}, true},
		{"one mm past the far end", Vec3{X: length + 1}, false},
		{"one mm behind the near edge", Vec3{X: -1}, false},
		{"exactly on the side edge", Vec3{X: 10_000, Z: halfWidth}, true},
		{"exactly on the other side edge", Vec3{X: 10_000, Z: -halfWidth}, true},
		{"one mm outside the side edge", Vec3{X: 10_000, Z: halfWidth + 1}, false},
	}
	for _, c := range cases {
		if got := tg.Catches(c.p); got != c.want {
			t.Errorf("rect(%d x ±%d) Catches(%v) = %v, want %v (%s)", length, halfWidth, c.p, got, c.want, c.name)
		}
	}
}

// TestRectRotatedBeamTracksTheFacing pins that the beam's width is measured
// perpendicular to an arbitrary facing, not to a world axis.
func TestRectRotatedBeamTracksTheFacing(t *testing.T) {
	// Facing +Z with an unnormalised vector; the beam's width now spans X.
	tg := RectTelegraph(Vec3{}, Vec3{Z: 3_000}, 20_000, 2_000)
	if !tg.Catches(Vec3{Z: 10_000}) {
		t.Error("along a +Z facing must be caught")
	}
	if !tg.Catches(Vec3{X: 2_000, Z: 10_000}) {
		t.Error("exactly on the rotated beam's side edge must be caught")
	}
	if tg.Catches(Vec3{X: 2_001, Z: 10_000}) {
		t.Error("one mm outside the rotated beam must be safe")
	}
	if tg.Catches(Vec3{Z: -1}) {
		t.Error("behind a +Z facing's near edge must be safe")
	}
}

func TestRectIgnoresVertical(t *testing.T) {
	tg := RectTelegraph(Vec3{}, Vec3{X: 1_000}, 20_000, 2_000)
	if !tg.Catches(Vec3{X: 10_000, Y: 500_000}) {
		t.Error("a horizontally-inside target high above the beam must still be caught")
	}
}

// --- World.Caught ---------------------------------------------------------

// TestCaughtReturnsAscendingIDs pins the determinism law: the caught set is
// ordered by EntityID, independent of insertion or map iteration order.
func TestCaughtReturnsAscendingIDs(t *testing.T) {
	w := NewWorld(DemoBounds)
	// Added out of order on purpose.
	w.Add(Entity{ID: 7, Pos: Vec3{X: 1_000}})
	w.Add(Entity{ID: 2, Pos: Vec3{X: 2_000}})
	w.Add(Entity{ID: 5, Pos: Vec3{X: 3_000}})
	w.Add(Entity{ID: 9, Pos: Vec3{X: 90_000}}) // far outside
	got := w.Caught(CircleTelegraph(Vec3{}, 10_000))
	want := []EntityID{2, 5, 7}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Caught = %v, want %v (ascending, out-of-range excluded)", got, want)
	}
}

// TestCaughtIncludesTheCaster documents that geometry does not filter: caster
// and faction rules belong to the ability layer that owns the cast.
func TestCaughtIncludesTheCaster(t *testing.T) {
	w := NewWorld(DemoBounds)
	w.Add(Entity{ID: 1, Pos: Vec3{}})
	if got := w.Caught(CircleTelegraph(Vec3{}, 5_000)); !reflect.DeepEqual(got, []EntityID{1}) {
		t.Fatalf("Caught = %v, want [1] — the caster is not filtered by geometry", got)
	}
}

func TestCaughtIsEmptyWhenNothingIsInside(t *testing.T) {
	w := NewWorld(DemoBounds)
	w.Add(Entity{ID: 1, Pos: Vec3{X: 50_000}})
	if got := w.Caught(CircleTelegraph(Vec3{}, 1_000)); len(got) != 0 {
		t.Fatalf("Caught = %v, want empty", got)
	}
}

// --- Golden resolution stream ---------------------------------------------

// telegraphGoldenTicks and telegraphGoldenHash pin the exact stream of caught
// sets that a fixed battery of telegraphs produces over the demo scenario.
// Because the stream is derived only from integer positions resolved in a stable
// order, this hash is identical on amd64 and arm64 — so it proves resolution's
// cross-platform determinism just as demoGoldenHash proves the movement core's.
// Changing it is a deliberate, reviewed act.
const telegraphGoldenTicks = 600
const telegraphGoldenHash uint64 = 0xb6abcf9a798b239a

// goldenBattery is the fixed set of telegraphs resolved every tick: a disc at
// the origin, a 60° cone opening along +X, and a beam along +Z — one of each
// angular family, so a regression in any of the three shows up in the hash.
func goldenBattery() []Telegraph {
	return []Telegraph{
		CircleTelegraph(Vec3{}, 12_000),
		ConeTelegraph(Vec3{}, Vec3{X: 1_000}, 20_000, cos60Scaled),
		RectTelegraph(Vec3{}, Vec3{Z: 1_000}, 25_000, 4_000),
	}
}

// runTelegraphDemo drives the shared demo scenario for n ticks, resolves the
// golden battery each tick, and folds the caught sets into an order-stable
// FNV-1a hash. It returns that hash and the number of ticks on which any
// telegraph caught anyone, so the golden cannot vacuously pin "nothing was ever
// caught".
func runTelegraphDemo(n int) (uint64, int) {
	w := NewDemoWorld()
	battery := goldenBattery()

	h := fnv.New64a()
	var buf [8]byte
	put := func(v uint64) {
		binary.LittleEndian.PutUint64(buf[:], v)
		_, _ = h.Write(buf[:])
	}

	eventfulTicks := 0
	for i := range n {
		DriveDemoTick(w)
		w.Step()
		caughtAny := false
		put(uint64(i))
		for _, tg := range battery {
			caught := w.Caught(tg)
			if len(caught) > 0 {
				caughtAny = true
			}
			put(uint64(len(caught)))
			for _, id := range caught {
				put(uint64(id))
			}
		}
		if caughtAny {
			eventfulTicks++
		}
	}
	return h.Sum64(), eventfulTicks
}

func TestTelegraphDemoGoldenResolutionStream(t *testing.T) {
	got, eventful := runTelegraphDemo(telegraphGoldenTicks)
	if eventful == 0 {
		t.Fatal("telegraph golden scenario caught nobody on any tick — the golden would be vacuous")
	}
	if got != telegraphGoldenHash {
		t.Fatalf("telegraph resolution hash after %d ticks = %#016x (over %d eventful ticks), want %#016x\n"+
			"if this change to resolution behaviour is intentional, update telegraphGoldenHash",
			telegraphGoldenTicks, got, eventful, telegraphGoldenHash)
	}
}

// TestTelegraphResolutionIsDeterministic runs the same scenario twice and
// requires an identical stream — the property the authoritative tier depends on.
func TestTelegraphResolutionIsDeterministic(t *testing.T) {
	a, _ := runTelegraphDemo(120)
	b, _ := runTelegraphDemo(120)
	if a != b {
		t.Fatalf("two identical runs disagreed: %#016x != %#016x", a, b)
	}
}

// TestMovementGoldenUnaffectedByResolution proves resolution is a read-only
// query: resolving telegraphs every tick must not change the movement golden,
// because Caught never mutates the world and is never part of Step. This is the
// same guarantee AoI upholds.
func TestMovementGoldenUnaffectedByResolution(t *testing.T) {
	w := NewDemoWorld()
	battery := goldenBattery()
	for range demoGoldenTicks {
		DriveDemoTick(w)
		w.Step()
		for _, tg := range battery {
			_ = w.Caught(tg)
		}
	}
	if got := w.Hash(); got != demoGoldenHash {
		t.Fatalf("resolving telegraphs moved the movement golden: %#016x != %#016x", got, demoGoldenHash)
	}
}
