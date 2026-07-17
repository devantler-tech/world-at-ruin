package sim

import (
	"encoding/binary"
	"hash/fnv"
	"reflect"
	"testing"
)

// TestSnapshotStateAndOrder pins the full snapshot's contents: the replicated
// state (id, position, radius) of exactly the in-interest entities, in
// ascending-ID order, self excluded and out-of-range excluded.
func TestSnapshotStateAndOrder(t *testing.T) {
	w := newObserverWorld(1, 10_000)
	w.Add(Entity{ID: 3, Pos: Vec3{X: 5_000}, Radius: 300})  // 5 m — inside
	w.Add(Entity{ID: 2, Pos: Vec3{X: -4_000}, Radius: 400}) // 4 m — inside
	w.Add(Entity{ID: 4, Pos: Vec3{X: 15_000}, Radius: 500}) // 15 m — outside
	snap := w.Snapshot(1)
	if snap.Observer != 1 || snap.Tick != 0 {
		t.Fatalf("snapshot header = observer %d tick %d, want observer 1 tick 0", snap.Observer, snap.Tick)
	}
	want := []EntityState{
		{ID: 2, Pos: Vec3{X: -4_000}, Radius: 400},
		{ID: 3, Pos: Vec3{X: 5_000}, Radius: 300},
	}
	if !reflect.DeepEqual(snap.Entities, want) {
		t.Fatalf("snapshot entities = %+v, want %+v (ascending, in-interest, self excluded)", snap.Entities, want)
	}
}

// TestSnapshotEmptyForUnknownAndZeroRadius confirms a snapshot for an unknown
// observer, or one that sees nothing, carries no entities (but still a valid
// header).
func TestSnapshotEmptyForUnknownAndZeroRadius(t *testing.T) {
	w := newObserverWorld(1, 0) // zero radius: sees nothing
	w.Add(Entity{ID: 2, Pos: Vec3{X: 1}, Radius: 300})
	if snap := w.Snapshot(1); snap.Entities != nil {
		t.Fatalf("zero-radius observer snapshot had entities: %+v", snap.Entities)
	}
	if snap := w.Snapshot(99); snap.Entities != nil || snap.Observer != 99 {
		t.Fatalf("unknown observer snapshot = %+v, want empty with observer 99", snap)
	}
}

// TestSnapshotInsertionOrderIndependent proves the snapshot is ascending-ID and
// independent of the order entities were added — the determinism requirement.
func TestSnapshotInsertionOrderIndependent(t *testing.T) {
	w := NewWorld(DemoBounds)
	w.Add(Entity{ID: 5, Pos: Vec3{X: 1_000}, InterestRadius: 50_000})
	for _, id := range []EntityID{9, 2, 7, 1, 4} {
		w.Add(Entity{ID: id, Pos: Vec3{X: int64(id) * 100}, Radius: int64(id)})
	}
	snap := w.Snapshot(5)
	var gotIDs []EntityID
	for _, es := range snap.Entities {
		gotIDs = append(gotIDs, es.ID)
	}
	if want := []EntityID{1, 2, 4, 7, 9}; !reflect.DeepEqual(gotIDs, want) {
		t.Fatalf("snapshot IDs = %v, want %v (ascending, insertion-independent)", gotIDs, want)
	}
}

// TestSnapshotTrackerFirstUpdateAllEntered mirrors the AoI tracker's first-call
// contract: every in-interest entity is reported entered (with state), nothing
// moved or left; a second still update produces nothing.
func TestSnapshotTrackerFirstUpdateAllEntered(t *testing.T) {
	w := newObserverWorld(1, 50_000)
	w.Add(Entity{ID: 2, Pos: Vec3{X: 1_000}, Radius: 300})
	w.Add(Entity{ID: 3, Pos: Vec3{X: 2_000}, Radius: 400})
	tr := NewSnapshotTracker(1)

	d := tr.Update(w)
	wantEntered := []EntityState{
		{ID: 2, Pos: Vec3{X: 1_000}, Radius: 300},
		{ID: 3, Pos: Vec3{X: 2_000}, Radius: 400},
	}
	if !reflect.DeepEqual(d.Entered, wantEntered) || d.Moved != nil || d.Left != nil {
		t.Fatalf("first delta = %+v, want only Entered %+v", d, wantEntered)
	}
	if d2 := tr.Update(w); !d2.Empty() {
		t.Fatalf("still world produced a non-empty delta: %+v", d2)
	}
}

// TestSnapshotTrackerMovedThenLeft walks a mover through interest and asserts the
// delta reports exactly one Moved per tick it changes position in range, and a
// single Left when it leaves — and that a stationary in-interest entity never
// appears (the minimality guarantee).
func TestSnapshotTrackerMovedThenLeft(t *testing.T) {
	w := NewWorld(DemoBounds)
	w.Add(Entity{ID: 1, Pos: Vec3{}, InterestRadius: 5_000})
	w.Add(Entity{ID: 2, Pos: Vec3{X: 2_000}, MaxSpeed: 0, Radius: 300})     // stationary, in range
	w.Add(Entity{ID: 3, Pos: Vec3{X: 3_000}, MaxSpeed: 6_000, Radius: 300}) // mover, in range
	tr := NewSnapshotTracker(1)
	tr.Update(w) // prime: both entered

	var moved3, left3 int
	sawStationaryEvent := false
	for range 400 {
		w.SetIntent(3, Vec3{X: 100_000}) // drive east, out of interest
		w.Step()
		d := tr.Update(w)
		for _, es := range d.Moved {
			if es.ID == 3 {
				moved3++
			}
			if es.ID == 2 {
				sawStationaryEvent = true
			}
		}
		for _, es := range d.Entered {
			if es.ID == 2 {
				sawStationaryEvent = true
			}
		}
		for _, id := range d.Left {
			if id == 3 {
				left3++
			}
		}
	}
	if moved3 == 0 {
		t.Fatal("mover in interest produced no Moved events")
	}
	if left3 != 1 {
		t.Fatalf("mover leaving interest produced %d Left events, want 1", left3)
	}
	if sawStationaryEvent {
		t.Fatal("a stationary in-interest entity produced a delta event — delta is not minimal")
	}
}

// --- Golden snapshot-delta stream -----------------------------------------

// snapshotGoldenRadius is the observer's interest radius in the golden scenario
// — the same as the AoI golden, so the demo actors repeatedly cross observer 1's
// boundary while also moving inside it, giving a stream rich in enter, move and
// leave events.
const snapshotGoldenRadius = 12_000

// snapshotGoldenTicks and snapshotGoldenHash pin the exact snapshot-delta event
// stream the demo scenario produces for observer 1. The stream folds in each
// moved entity's position, so unlike the AoI golden (membership only) this pins
// the replicated STATE. Because it derives only from integer positions in a
// stable order, the hash is identical on amd64 and arm64 — the cross-platform
// determinism proof for the replication payload. Changing it is a deliberate,
// reviewed act.
const snapshotGoldenTicks = 600
const snapshotGoldenHash uint64 = 0x90617e7d1146518f

// runSnapshotDemo drives the shared demo scenario for n ticks, tracks observer
// 1's replication snapshot, and folds the per-tick delta (entered/moved/left,
// with moved-entity state) into an order-stable FNV-1a hash. It returns that
// hash and the number of ticks on which any event fired, so the golden cannot
// vacuously pin "nothing ever happened".
func runSnapshotDemo(radius int64, n int) (uint64, int) {
	w := NewDemoWorld()
	w.SetInterestRadius(1, radius)
	tr := NewSnapshotTracker(1)

	h := fnv.New64a()
	var buf [8]byte
	put := func(v uint64) {
		binary.LittleEndian.PutUint64(buf[:], v)
		_, _ = h.Write(buf[:])
	}
	putState := func(es EntityState) {
		put(uint64(es.ID))
		put(uint64(es.Pos.X))
		put(uint64(es.Pos.Y))
		put(uint64(es.Pos.Z))
		put(uint64(es.Radius))
	}

	eventfulTicks := 0
	for i := range n {
		DriveDemoTick(w)
		w.Step()
		d := tr.Update(w)
		if !d.Empty() {
			eventfulTicks++
		}
		put(uint64(i))
		put(uint64(len(d.Entered)))
		for _, es := range d.Entered {
			putState(es)
		}
		put(uint64(len(d.Moved)))
		for _, es := range d.Moved {
			putState(es)
		}
		put(uint64(len(d.Left)))
		for _, id := range d.Left {
			put(uint64(id))
		}
	}
	return h.Sum64(), eventfulTicks
}

func TestSnapshotDemoGoldenDeltaStream(t *testing.T) {
	got, eventful := runSnapshotDemo(snapshotGoldenRadius, snapshotGoldenTicks)
	if eventful == 0 {
		t.Fatal("snapshot golden scenario produced no delta events — the golden would be vacuous")
	}
	if got != snapshotGoldenHash {
		t.Fatalf("snapshot delta-stream hash after %d ticks = %#016x (over %d eventful ticks), want %#016x\n"+
			"if this change to snapshot behaviour is intentional, update snapshotGoldenHash",
			snapshotGoldenTicks, got, eventful, snapshotGoldenHash)
	}
}

// TestMovementGoldenUnaffectedBySnapshot proves the snapshot layer is a
// read-only query: tracking snapshots for the demo actors must not change the
// movement golden hash, because nothing here is read or written by Step.
func TestMovementGoldenUnaffectedBySnapshot(t *testing.T) {
	w := NewDemoWorld()
	for _, a := range demoActors {
		w.SetInterestRadius(a.id, 12_000)
	}
	trackers := make([]*SnapshotTracker, 0, len(demoActors))
	for _, a := range demoActors {
		trackers = append(trackers, NewSnapshotTracker(a.id))
	}
	for range demoGoldenTicks {
		DriveDemoTick(w)
		w.Step()
		for _, tr := range trackers {
			tr.Update(w)
		}
	}
	if got := w.Hash(); got != demoGoldenHash {
		t.Fatalf("tracking snapshots moved the movement golden: %#016x != %#016x", got, demoGoldenHash)
	}
}
