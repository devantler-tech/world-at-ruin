package sim

import (
	"encoding/binary"
	"hash/fnv"
	"math"
	"reflect"
	"testing"
)

// newObserverWorld returns a fresh demo-bounded world with a single observer at
// the origin whose interest radius is r, ready for other entities to be added.
func newObserverWorld(observer EntityID, r int64) *World {
	w := NewWorld(DemoBounds)
	w.Add(Entity{ID: observer, Pos: Vec3{}, InterestRadius: r})
	return w
}

func TestInterestExcludesSelfAndOutOfRange(t *testing.T) {
	w := newObserverWorld(1, 10_000)
	w.Add(Entity{ID: 2, Pos: Vec3{X: 5_000}})  // 5 m away — inside
	w.Add(Entity{ID: 3, Pos: Vec3{X: 15_000}}) // 15 m away — outside
	w.Add(Entity{ID: 4, Pos: Vec3{Z: -9_999}}) // 9.999 m away — inside
	got := w.Interest(1)
	want := []EntityID{2, 4}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Interest(1) = %v, want %v (self excluded, out-of-range excluded)", got, want)
	}
}

// TestInterestBoundaryInclusive pins that an entity exactly at the radius is in
// interest and one a single millimetre beyond is not.
func TestInterestBoundaryInclusive(t *testing.T) {
	const r = 10_000
	w := newObserverWorld(1, r)
	w.Add(Entity{ID: 2, Pos: Vec3{X: r}})     // exactly on the boundary — inside
	w.Add(Entity{ID: 3, Pos: Vec3{X: r + 1}}) // one mm past — outside
	if got := w.Interest(1); !reflect.DeepEqual(got, []EntityID{2}) {
		t.Fatalf("boundary-inclusive Interest(1) = %v, want [2]", got)
	}
}

// TestInterestIgnoresVertical proves AoI is a ground-plane quantity: a large
// vertical separation never removes an entity that is horizontally in range, and
// zero vertical separation never rescues one that is horizontally out of range.
func TestInterestIgnoresVertical(t *testing.T) {
	w := newObserverWorld(1, 1_000)
	// Horizontally inside (500 mm), maximally separated vertically (top of the
	// 4 m-tall demo bounds): still in interest.
	w.Add(Entity{ID: 2, Pos: Vec3{X: 500, Y: 4_000}})
	// Horizontally outside (2 m), same ground height: still out of interest.
	w.Add(Entity{ID: 3, Pos: Vec3{X: 2_000, Y: 0}})
	if got := w.Interest(1); !reflect.DeepEqual(got, []EntityID{2}) {
		t.Fatalf("vertical axis affected interest: Interest(1) = %v, want [2]", got)
	}
}

func TestInterestZeroRadiusSeesNothing(t *testing.T) {
	w := newObserverWorld(1, 0)
	w.Add(Entity{ID: 2, Pos: Vec3{X: 1}})
	if got := w.Interest(1); got != nil {
		t.Fatalf("zero-radius observer saw %v, want nil", got)
	}
}

func TestInterestUnknownObserverEmpty(t *testing.T) {
	w := newObserverWorld(1, 10_000)
	w.Add(Entity{ID: 2, Pos: Vec3{X: 1_000}})
	if got := w.Interest(99); got != nil {
		t.Fatalf("unknown observer returned %v, want nil", got)
	}
}

// TestInterestAscendingOrderInsertionIndependent proves the interest set is
// returned in ascending-ID order regardless of the order entities were added —
// the determinism requirement, the AoI analogue of the step's stable order.
func TestInterestAscendingOrderInsertionIndependent(t *testing.T) {
	w := NewWorld(DemoBounds)
	w.Add(Entity{ID: 5, Pos: Vec3{X: 1_000}, InterestRadius: 50_000})
	// Add the neighbours in deliberately non-ascending order.
	for _, id := range []EntityID{9, 2, 7, 1, 4} {
		w.Add(Entity{ID: id, Pos: Vec3{X: int64(id) * 100}})
	}
	got := w.Interest(5)
	want := []EntityID{1, 2, 4, 7, 9}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Interest not ascending/insertion-independent: %v, want %v", got, want)
	}
}

// TestInterestRadiusClampedOnAdd covers both ends of the ingestion clamp: a
// pathological huge radius is capped (and must not overflow the squared-distance
// comparison), and a negative radius becomes zero.
func TestInterestRadiusClampedOnAdd(t *testing.T) {
	w := NewWorld(DemoBounds)
	huge := w.Add(Entity{ID: 1, Pos: Vec3{}, InterestRadius: math.MaxInt64})
	if huge.InterestRadius != maxInterestRadiusMM {
		t.Fatalf("huge InterestRadius not clamped: got %d, want %d", huge.InterestRadius, maxInterestRadiusMM)
	}
	// A neighbour on the far corner of the zone must still be seen (the cap
	// exceeds the zone diagonal) and the query must not panic on overflow.
	w.Add(Entity{ID: 2, Pos: DemoBounds.Max})
	if got := w.Interest(1); !reflect.DeepEqual(got, []EntityID{2}) {
		t.Fatalf("capped-radius observer did not see the far corner: %v", got)
	}

	neg := w.Add(Entity{ID: 3, Pos: Vec3{X: -1_000}, InterestRadius: -42})
	if neg.InterestRadius != 0 {
		t.Fatalf("negative InterestRadius not clamped to 0: got %d", neg.InterestRadius)
	}
}

func TestSetInterestRadiusClampsAndIgnoresUnknown(t *testing.T) {
	w := NewWorld(DemoBounds)
	e := w.Add(Entity{ID: 1})
	w.SetInterestRadius(1, math.MaxInt64)
	if e.InterestRadius != maxInterestRadiusMM {
		t.Fatalf("SetInterestRadius did not clamp: got %d, want %d", e.InterestRadius, maxInterestRadiusMM)
	}
	w.SetInterestRadius(1, -1)
	if e.InterestRadius != 0 {
		t.Fatalf("SetInterestRadius did not clamp negative to 0: got %d", e.InterestRadius)
	}
	w.SetInterestRadius(404, 5_000) // no-op, must not panic
}

// TestInterestSymmetricEqualRadius: with equal interest radii, A sees B exactly
// when B sees A — a sanity invariant that catches an asymmetric distance bug.
func TestInterestSymmetricEqualRadius(t *testing.T) {
	for _, sep := range []int64{9_999, 10_000, 10_001} {
		w := NewWorld(DemoBounds)
		w.Add(Entity{ID: 1, Pos: Vec3{X: -sep / 2}, InterestRadius: 10_000})
		w.Add(Entity{ID: 2, Pos: Vec3{X: sep / 2}, InterestRadius: 10_000})
		aSeesB := len(w.Interest(1)) == 1
		bSeesA := len(w.Interest(2)) == 1
		if aSeesB != bSeesA {
			t.Fatalf("interest asymmetric at separation %d: 1→2=%v, 2→1=%v", sep, aSeesB, bSeesA)
		}
	}
}

func TestInterestTrackerFirstUpdateAllEntered(t *testing.T) {
	w := newObserverWorld(1, 50_000)
	w.Add(Entity{ID: 2, Pos: Vec3{X: 1_000}})
	w.Add(Entity{ID: 3, Pos: Vec3{X: 2_000}})
	tr := NewInterestTracker(1)
	entered, left := tr.Update(w)
	if !reflect.DeepEqual(entered, []EntityID{2, 3}) || left != nil {
		t.Fatalf("first Update = entered %v, left %v; want entered [2 3], left nil", entered, left)
	}
	// A second Update with no movement yields no events.
	entered, left = tr.Update(w)
	if entered != nil || left != nil {
		t.Fatalf("stable Update produced events: entered %v, left %v", entered, left)
	}
}

// TestInterestTrackerEnterThenLeave walks a mover through an observer's interest
// and asserts exactly one enter event then exactly one leave event, at the
// boundary crossings — the "nothing appears from nowhere" contract.
func TestInterestTrackerEnterThenLeave(t *testing.T) {
	w := NewWorld(DemoBounds)
	w.Add(Entity{ID: 1, Pos: Vec3{}, InterestRadius: 5_000})
	// Mover starts well outside interest (10 m east) and walks due west across
	// the observer and back out.
	w.Add(Entity{ID: 2, Pos: Vec3{X: 10_000}, MaxSpeed: 4_000})
	tr := NewInterestTracker(1)
	tr.Update(w) // prime: mover is outside, nothing entered

	var enters, leaves int
	for range 400 {
		w.SetIntent(2, Vec3{X: -100_000}) // slam west
		w.Step()
		entered, left := tr.Update(w)
		enters += len(entered)
		leaves += len(left)
	}
	// Crossed in once (enter) and, continuing west past the observer, out once
	// (leave). It ends pinned on the west wall, still outside interest.
	if enters != 1 || leaves != 1 {
		t.Fatalf("expected one enter and one leave, got enters=%d leaves=%d", enters, leaves)
	}
	if got := w.Interest(1); got != nil {
		t.Fatalf("mover should have left interest, but Interest(1) = %v", got)
	}
}

// --- Golden AoI event log -------------------------------------------------

// aoiGoldenRadius is the observer's interest radius in the golden scenario.
// Chosen so the three demo actors repeatedly cross observer 1's boundary as
// they walk their cardinal legs, producing a non-trivial enter/leave stream.
const aoiGoldenRadius = 12_000

// aoiGoldenTicks and aoiGoldenHash pin the exact enter/leave event stream the
// demo scenario produces for observer 1 over aoiGoldenTicks ticks. Because the
// stream is derived only from integer positions in a stable order, this hash is
// identical on amd64 and arm64 — so the test proves AoI's cross-platform
// determinism just as demoGoldenHash proves the movement core's. Changing it is
// a deliberate, reviewed act.
const aoiGoldenTicks = 600
const aoiGoldenHash uint64 = 0xcf86e62aabe5ffa4

// runAoIDemo drives the shared demo scenario for n ticks, tracks observer 1's
// area-of-interest, and folds the per-tick enter/leave events into an order-
// stable FNV-1a hash. It returns that hash and the number of ticks on which any
// event fired (so the golden cannot vacuously pin "nothing ever happened").
func runAoIDemo(radius int64, n int) (uint64, int) {
	w := NewDemoWorld()
	w.SetInterestRadius(1, radius)
	tr := NewInterestTracker(1)

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
		entered, left := tr.Update(w)
		if len(entered) > 0 || len(left) > 0 {
			eventfulTicks++
		}
		put(uint64(i))
		put(uint64(len(entered)))
		for _, id := range entered {
			put(uint64(id))
		}
		put(uint64(len(left)))
		for _, id := range left {
			put(uint64(id))
		}
	}
	return h.Sum64(), eventfulTicks
}

func TestAoIDemoGoldenEventLog(t *testing.T) {
	got, eventful := runAoIDemo(aoiGoldenRadius, aoiGoldenTicks)
	if eventful == 0 {
		t.Fatal("AoI golden scenario produced no enter/leave events — the golden would be vacuous")
	}
	if got != aoiGoldenHash {
		t.Fatalf("AoI event-log hash after %d ticks = %#016x (over %d eventful ticks), want %#016x\n"+
			"if this change to AoI behaviour is intentional, update aoiGoldenHash",
			aoiGoldenTicks, got, eventful, aoiGoldenHash)
	}
}

// TestMovementGoldenUnaffectedByInterest proves AoI is a read-only query: giving
// the demo actors interest radii must not change the movement golden hash,
// because InterestRadius is neither hashed nor read by Step.
func TestMovementGoldenUnaffectedByInterest(t *testing.T) {
	w := NewDemoWorld()
	for _, a := range demoActors {
		w.SetInterestRadius(a.id, 12_000)
	}
	for range demoGoldenTicks {
		DriveDemoTick(w)
		w.Step()
	}
	if got := w.Hash(); got != demoGoldenHash {
		t.Fatalf("setting interest radii moved the movement golden: %#016x != %#016x", got, demoGoldenHash)
	}
}
