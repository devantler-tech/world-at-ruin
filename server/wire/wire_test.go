package wire

import (
	"encoding/binary"
	"encoding/hex"
	"errors"
	"hash/fnv"
	"reflect"
	"strings"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/sim"
)

// --- fixed message goldens ---------------------------------------------------
//
// These two literals and their hex encodings pin the byte layout itself — the
// cross-tier fixture the future client-side (GDScript) decoder is written
// against, in the same spirit as the shared cone-cosine fixture (#159). The
// values are chosen to pin the parts prose can get wrong: little-endian order,
// two's-complement negatives, empty-list counts, and multi-entry lists.

var goldenSnapshot = sim.Snapshot{
	Tick:     600,
	Observer: 1,
	Entities: []sim.EntityState{
		{ID: 2, Pos: sim.Vec3{X: -5_000, Y: 0, Z: 12_345}, Radius: 300},
		{ID: 3, Pos: sim.Vec3{X: 0, Y: 4_000, Z: -20_000}, Radius: 400},
	},
}

const goldenSnapshotHex = "010001" + // version 1, kind snapshot
	"5802000000000000" + "0100000000000000" + "02000000" + // tick 600, observer 1, 2 entities
	"0200000000000000" + "78ecffffffffffff" + "0000000000000000" + "3930000000000000" + "2c01000000000000" + // id 2, (-5000, 0, 12345), r 300
	"0300000000000000" + "0000000000000000" + "a00f000000000000" + "e0b1ffffffffffff" + "9001000000000000" // id 3, (0, 4000, -20000), r 400

var goldenDelta = sim.SnapshotDelta{
	Tick: 601,
	Entered: []sim.EntityState{
		{ID: 4, Pos: sim.Vec3{X: 1, Y: -2, Z: 3}, Radius: 500},
	},
	Moved: []sim.EntityState{
		{ID: 2, Pos: sim.Vec3{X: -5_100, Y: 0, Z: 12_400}, Radius: 300},
	},
	Left: []sim.EntityID{3, 7},
}

const goldenDeltaHex = "010002" + // version 1, kind delta
	"5902000000000000" + "01000000" + // tick 601, 1 entered
	"0400000000000000" + "0100000000000000" + "feffffffffffffff" + "0300000000000000" + "f401000000000000" + // id 4, (1, -2, 3), r 500
	"01000000" + // 1 moved
	"0200000000000000" + "14ecffffffffffff" + "0000000000000000" + "7030000000000000" + "2c01000000000000" + // id 2, (-5100, 0, 12400), r 300
	"02000000" + "0300000000000000" + "0700000000000000" // left: 3, 7

func mustDecodeHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("bad hex fixture: %v", err)
	}
	return b
}

func TestGoldenSnapshotBytes(t *testing.T) {
	got, err := EncodeSnapshot(goldenSnapshot)
	if err != nil {
		t.Fatalf("EncodeSnapshot: %v", err)
	}
	if gotHex := hex.EncodeToString(got); gotHex != goldenSnapshotHex {
		t.Fatalf("snapshot byte layout moved — this is a wire-protocol change and needs a Version bump, not a golden refresh.\n got %s\nwant %s", gotHex, goldenSnapshotHex)
	}
	m, err := Decode(got)
	if err != nil {
		t.Fatalf("Decode(golden snapshot): %v", err)
	}
	if m.Kind != KindSnapshot || !reflect.DeepEqual(m.Snapshot, goldenSnapshot) {
		t.Fatalf("decode(encode) mismatch: %+v", m)
	}
}

func TestGoldenDeltaBytes(t *testing.T) {
	got, err := EncodeSnapshotDelta(goldenDelta)
	if err != nil {
		t.Fatalf("EncodeSnapshotDelta: %v", err)
	}
	if gotHex := hex.EncodeToString(got); gotHex != goldenDeltaHex {
		t.Fatalf("delta byte layout moved — this is a wire-protocol change and needs a Version bump, not a golden refresh.\n got %s\nwant %s", gotHex, goldenDeltaHex)
	}
	m, err := Decode(got)
	if err != nil {
		t.Fatalf("Decode(golden delta): %v", err)
	}
	if m.Kind != KindSnapshotDelta || !reflect.DeepEqual(m.Delta, goldenDelta) {
		t.Fatalf("decode(encode) mismatch: %+v", m)
	}
}

// --- round trips --------------------------------------------------------------

func TestSnapshotRoundTrip(t *testing.T) {
	cases := map[string]sim.Snapshot{
		"empty":        {Tick: 0, Observer: 9},
		"one entity":   {Tick: 7, Observer: 1, Entities: []sim.EntityState{{ID: 5, Pos: sim.Vec3{X: 10, Y: 20, Z: 30}, Radius: 40}}},
		"extreme ints": {Tick: ^uint64(0), Observer: sim.EntityID(^uint64(0)), Entities: []sim.EntityState{{ID: 1, Pos: sim.Vec3{X: -(1 << 62), Y: 1<<62 - 1, Z: -1}, Radius: 1<<62 - 1}}},
	}
	for name, s := range cases {
		t.Run(name, func(t *testing.T) {
			b, err := EncodeSnapshot(s)
			if err != nil {
				t.Fatalf("encode: %v", err)
			}
			m, err := Decode(b)
			if err != nil {
				t.Fatalf("decode: %v", err)
			}
			if m.Kind != KindSnapshot || !reflect.DeepEqual(m.Snapshot, s) {
				t.Fatalf("round trip mismatch:\n got %+v\nwant %+v", m.Snapshot, s)
			}
		})
	}
}

func TestDeltaRoundTrip(t *testing.T) {
	cases := map[string]sim.SnapshotDelta{
		"empty":     {Tick: 3},
		"left only": {Tick: 4, Left: []sim.EntityID{1, 2, 9}},
		"all lists": goldenDelta,
	}
	for name, d := range cases {
		t.Run(name, func(t *testing.T) {
			b, err := EncodeSnapshotDelta(d)
			if err != nil {
				t.Fatalf("encode: %v", err)
			}
			m, err := Decode(b)
			if err != nil {
				t.Fatalf("decode: %v", err)
			}
			if m.Kind != KindSnapshotDelta || !reflect.DeepEqual(m.Delta, d) {
				t.Fatalf("round trip mismatch:\n got %+v\nwant %+v", m.Delta, d)
			}
		})
	}
}

// --- fail-closed decode --------------------------------------------------------

// TestDecodeTruncationNeverPanics feeds every strict prefix of both goldens to
// Decode: each must return an error (truncation can never look valid, because
// the full frame length is implied by the counts) and none may panic.
func TestDecodeTruncationNeverPanics(t *testing.T) {
	for name, full := range map[string][]byte{
		"snapshot": mustDecodeHex(t, goldenSnapshotHex),
		"delta":    mustDecodeHex(t, goldenDeltaHex),
	} {
		for n := range full {
			if _, err := Decode(full[:n]); err == nil {
				t.Fatalf("%s truncated to %d bytes decoded without error", name, n)
			}
		}
	}
}

func TestDecodeVersionCeiling(t *testing.T) {
	for _, version := range []uint16{0, Version + 1, ^uint16(0)} {
		b := mustDecodeHex(t, goldenSnapshotHex)
		binary.LittleEndian.PutUint16(b, version)
		if _, err := Decode(b); !errors.Is(err, ErrVersion) {
			t.Fatalf("version %d: got %v, want ErrVersion", version, err)
		}
	}
}

func TestDecodeUnknownKind(t *testing.T) {
	b := mustDecodeHex(t, goldenSnapshotHex)
	b[2] = 0xEE
	if _, err := Decode(b); !errors.Is(err, ErrKind) {
		t.Fatalf("got %v, want ErrKind", err)
	}
}

func TestDecodeTrailingBytes(t *testing.T) {
	b := append(mustDecodeHex(t, goldenDeltaHex), 0x00)
	if _, err := Decode(b); !errors.Is(err, ErrTrailing) {
		t.Fatalf("got %v, want ErrTrailing", err)
	}
}

// TestDecodeCountCap proves a hostile length prefix is refused as ErrCount
// before any length check or allocation — even when the claimed count (times
// the entry size) would dwarf the actual buffer.
func TestDecodeCountCap(t *testing.T) {
	for _, count := range []uint32{MaxEntities + 1, ^uint32(0)} {
		var b []byte
		b = binary.LittleEndian.AppendUint16(b, Version)
		b = append(b, KindSnapshot)
		b = binary.LittleEndian.AppendUint64(b, 1)     // tick
		b = binary.LittleEndian.AppendUint64(b, 1)     // observer
		b = binary.LittleEndian.AppendUint32(b, count) // hostile count
		if _, err := Decode(b); !errors.Is(err, ErrCount) {
			t.Fatalf("count %d: got %v, want ErrCount", count, err)
		}
	}
}

// TestOrderEnforcedBothSides proves the ascending-ID contract is refused on
// encode AND decode — never silently repaired on either side.
func TestOrderEnforcedBothSides(t *testing.T) {
	dup := sim.Snapshot{Tick: 1, Observer: 1, Entities: []sim.EntityState{{ID: 2}, {ID: 2}}}
	if _, err := EncodeSnapshot(dup); !errors.Is(err, ErrOrder) {
		t.Fatalf("encode duplicate IDs: got %v, want ErrOrder", err)
	}
	descending := sim.SnapshotDelta{Tick: 1, Left: []sim.EntityID{9, 3}}
	if _, err := EncodeSnapshotDelta(descending); !errors.Is(err, ErrOrder) {
		t.Fatalf("encode descending Left: got %v, want ErrOrder", err)
	}

	// Craft the descending bytes by hand (the encoder refuses to produce them).
	var b []byte
	b = binary.LittleEndian.AppendUint16(b, Version)
	b = append(b, KindSnapshotDelta)
	b = binary.LittleEndian.AppendUint64(b, 1) // tick
	b = binary.LittleEndian.AppendUint32(b, 0) // entered
	b = binary.LittleEndian.AppendUint32(b, 0) // moved
	b = binary.LittleEndian.AppendUint32(b, 2) // left
	b = binary.LittleEndian.AppendUint64(b, 9)
	b = binary.LittleEndian.AppendUint64(b, 3)
	if _, err := Decode(b); !errors.Is(err, ErrOrder) {
		t.Fatalf("decode descending Left: got %v, want ErrOrder", err)
	}
}

// TestDeltaDisjointEnforcedBothSides proves an EntityID appearing in two of a
// delta's lists is refused on encode AND decode.
func TestDeltaDisjointEnforcedBothSides(t *testing.T) {
	overlap := sim.SnapshotDelta{
		Tick:    1,
		Entered: []sim.EntityState{{ID: 3}},
		Left:    []sim.EntityID{3},
	}
	if _, err := EncodeSnapshotDelta(overlap); !errors.Is(err, ErrOverlap) {
		t.Fatalf("encode overlap: got %v, want ErrOverlap", err)
	}

	var b []byte
	b = binary.LittleEndian.AppendUint16(b, Version)
	b = append(b, KindSnapshotDelta)
	b = binary.LittleEndian.AppendUint64(b, 1) // tick
	b = binary.LittleEndian.AppendUint32(b, 1) // entered: entity 3
	b = binary.LittleEndian.AppendUint64(b, 3)
	b = binary.LittleEndian.AppendUint64(b, 0)
	b = binary.LittleEndian.AppendUint64(b, 0)
	b = binary.LittleEndian.AppendUint64(b, 0)
	b = binary.LittleEndian.AppendUint64(b, 0)
	b = binary.LittleEndian.AppendUint32(b, 0) // moved
	b = binary.LittleEndian.AppendUint32(b, 1) // left: entity 3 again
	b = binary.LittleEndian.AppendUint64(b, 3)
	if _, err := Decode(b); !errors.Is(err, ErrOverlap) {
		t.Fatalf("decode overlap: got %v, want ErrOverlap", err)
	}
}

func TestEncodeCountCap(t *testing.T) {
	es := make([]sim.EntityState, MaxEntities+1)
	for i := range es {
		es[i].ID = sim.EntityID(i + 1)
	}
	if _, err := EncodeSnapshot(sim.Snapshot{Entities: es}); !errors.Is(err, ErrCount) {
		t.Fatalf("got %v, want ErrCount", err)
	}
}

// --- live-stream golden ---------------------------------------------------------
//
// The demo scenario (the same one the AoI and snapshot goldens drive, same
// radius and tick count) is run through the tracker, every non-empty delta is
// wire-encoded, decode-verified, and folded into an FNV-1a hash. This pins the
// codec OVER the live simulation — the full pipeline a transport will run —
// and moves only when the sim's delta stream moves (a deliberate, reviewed act
// that already moves snapshotGoldenHash) or when the byte layout changes (a
// protocol change, caught by the fixed goldens above too).

const wireStreamGoldenRadius = 12_000
const wireStreamGoldenTicks = 600
const wireStreamGoldenHash uint64 = 0xc033ed7fb2a5f7b6

func TestDemoGoldenWireStream(t *testing.T) {
	w := sim.NewDemoWorld()
	w.SetInterestRadius(1, wireStreamGoldenRadius)
	tr := sim.NewSnapshotTracker(1)

	h := fnv.New64a()
	eventful := 0
	for range wireStreamGoldenTicks {
		sim.DriveDemoTick(w)
		w.Step()
		d := tr.Update(w)
		if d.Empty() {
			continue
		}
		eventful++
		b, err := EncodeSnapshotDelta(d)
		if err != nil {
			t.Fatalf("tick %d: encode: %v", w.Tick, err)
		}
		m, err := Decode(b)
		if err != nil {
			t.Fatalf("tick %d: decode: %v", w.Tick, err)
		}
		if !reflect.DeepEqual(m.Delta, d) {
			t.Fatalf("tick %d: round trip diverged", w.Tick)
		}
		_, _ = h.Write(b)
	}
	if eventful == 0 {
		t.Fatal("wire stream golden scenario produced no deltas — the golden would be vacuous")
	}

	// The join payload runs through the same pipeline: encode and verify the
	// final full snapshot, folding it into the same hash.
	s := w.Snapshot(1)
	if len(s.Entities) == 0 {
		t.Fatal("final full snapshot is empty — the join-payload half of the golden would be vacuous")
	}
	b, err := EncodeSnapshot(s)
	if err != nil {
		t.Fatalf("encode full snapshot: %v", err)
	}
	m, err := Decode(b)
	if err != nil {
		t.Fatalf("decode full snapshot: %v", err)
	}
	if !reflect.DeepEqual(m.Snapshot, s) {
		t.Fatal("full snapshot round trip diverged")
	}
	_, _ = h.Write(b)

	if got := h.Sum64(); got != wireStreamGoldenHash {
		t.Fatalf("wire stream over %d ticks hashed %#016x (eventful ticks: %d), want %#016x — "+
			"if the sim's delta stream or the wire layout changed intentionally, update wireStreamGoldenHash",
			wireStreamGoldenTicks, got, eventful, wireStreamGoldenHash)
	}
}

// TestErrorTextNamesTheList pins that refusals identify which list offended —
// the difference between a debuggable frame rejection and a mystery.
func TestErrorTextNamesTheList(t *testing.T) {
	_, err := EncodeSnapshotDelta(sim.SnapshotDelta{Left: []sim.EntityID{5, 5}})
	if err == nil || !strings.Contains(err.Error(), "left") {
		t.Fatalf("error should name the offending list: %v", err)
	}
}
