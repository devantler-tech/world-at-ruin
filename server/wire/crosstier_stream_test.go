package wire

// Cross-tier STREAM golden (issue #198).
//
// The message goldens above pin the byte layout of one snapshot and one delta
// in isolation; this fixture pins STREAM SEMANTICS — the frame sequence a
// client actually receives across a join, per-tick deltas, and a mid-stream
// resync — so the client's replica store (client/scripts/replica_store.gd) can
// prove it folds real server output into the exact end state the server
// considers authoritative. Both tiers assert the SAME committed fixture
// section (`stream` in client/tests/data/wire_goldens.json): this side proves
// the shipped tracker + encoder emit exactly the fixture's frames from the
// scripted scenario below and that the fixture's end state equals the world's
// authoritative view; the client side proves folding those frames yields that
// same end state. Neither tier can drift without both suites moving together.
//
// The scenario is purpose-built (the demo world's timeline has no compact
// window containing an enter, a move AND a leave) and mirrors the zonesock
// lifecycle verbatim: join snapshot + tracker prime exactly as Hub.attach
// does; empty deltas skipped exactly as Hub.pump does; the mid-stream resync
// re-snapshots and re-primes exactly as Hub.send's overflow path does. The
// window also pins the interest boundary as INCLUSIVE cross-tier: the leaver
// stands at exactly the interest radius for one tick (still replicated)
// before stepping beyond it.
//
// Regenerating (a deliberate, reviewed act — stream semantics are contract):
// WAR_RECORD_STREAM=1 go test ./wire/ -run TestCrossTierStreamFixture -v
// prints the fixture JSON to paste into the `stream` section.

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/sim"
)

// The scripted scenario. All integers, all deterministic: displacement per
// tick is intent/TickHz mm, so the drifter moves 100 mm/tick and the two
// boundary-crossers 1000 mm/tick.
const (
	streamObserver     = sim.EntityID(1)
	streamInterestMM   = 10_000
	streamDrifterID    = sim.EntityID(2) // in interest throughout; moves 100 mm/tick, stops before the final tick
	streamLeaverID     = sim.EntityID(3) // starts in interest, walks out (left)
	streamEntererID    = sim.EntityID(4) // starts outside, walks in (entered)
	streamResyncAfter  = 4               // ticks before the mid-stream resync
	streamTicksTotal   = 5
	streamDrifterSpeed = 3_000  // mm/s -> 100 mm/tick
	streamCrosserSpeed = 30_000 // mm/s -> 1000 mm/tick
)

type streamFixtureFrame struct {
	Kind string `json:"kind"`
	Hex  string `json:"hex"`
}

type streamFixture struct {
	Observer uint64               `json:"observer"`
	Frames   []streamFixtureFrame `json:"frames"`
	EndState *wireFixtureSnapshot `json:"end_state"`
}

type wireFixtureWithStream struct {
	Stream *streamFixture `json:"stream"`
}

// runStreamScenario drives the scripted scenario through the shipped tracker
// and encoder, returning every frame a client would receive plus the world's
// final authoritative snapshot for the observer.
func runStreamScenario(t *testing.T) ([]streamFixtureFrame, sim.Snapshot) {
	t.Helper()
	w := sim.NewWorld(sim.DemoBounds)
	w.Add(sim.Entity{ID: streamObserver, Pos: sim.Vec3{}, Radius: 400, InterestRadius: streamInterestMM})
	w.Add(sim.Entity{ID: streamDrifterID, Pos: sim.Vec3{X: 5_000}, Radius: 300, MaxSpeed: streamDrifterSpeed})
	w.Add(sim.Entity{ID: streamLeaverID, Pos: sim.Vec3{X: 9_000}, Radius: 350, MaxSpeed: streamCrosserSpeed})
	w.Add(sim.Entity{ID: streamEntererID, Pos: sim.Vec3{X: -13_000}, Radius: 500, MaxSpeed: streamCrosserSpeed})

	var frames []streamFixtureFrame
	encode := func(kind string, b []byte, err error) {
		if err != nil {
			t.Fatalf("encode %s at tick %d: %v", kind, w.Tick, err)
		}
		m, err := Decode(b)
		if err != nil {
			t.Fatalf("decode-verify %s at tick %d: %v", kind, w.Tick, err)
		}
		_ = m
		frames = append(frames, streamFixtureFrame{Kind: kind, Hex: hex.EncodeToString(b)})
	}

	// Join: exactly Hub.attach — full snapshot, then prime the tracker so the
	// first delta is relative to the join payload.
	join := w.Snapshot(streamObserver)
	b, err := EncodeSnapshot(join)
	encode("snapshot", b, err)
	tr := sim.NewSnapshotTracker(streamObserver)
	tr.Update(w)

	for tick := 1; tick <= streamTicksTotal; tick++ {
		w.SetIntent(streamLeaverID, sim.Vec3{X: streamCrosserSpeed})
		w.SetIntent(streamEntererID, sim.Vec3{X: streamCrosserSpeed})
		if tick < streamTicksTotal {
			w.SetIntent(streamDrifterID, sim.Vec3{X: streamDrifterSpeed})
		} else {
			// The final tick proves an unchanged in-interest entity appears in
			// no list: the drifter stands still while the enterer keeps moving.
			w.SetIntent(streamDrifterID, sim.Vec3{})
		}
		w.Step()
		d := tr.Update(w)
		if tick == streamResyncAfter {
			// Exactly Hub.send's overflow path: the delta that overflowed the
			// queue is DROPPED (never delivered), and the peer gets one fresh
			// full snapshot at the same tick instead, with the tracker
			// re-primed so later deltas are relative to the resync. This is
			// why applied ticks strictly ascend on the client: the resync's
			// tick is the dropped delta's, always past the last delivered
			// frame.
			resync := w.Snapshot(streamObserver)
			b, err := EncodeSnapshot(resync)
			encode("snapshot", b, err)
			tr = sim.NewSnapshotTracker(streamObserver)
			tr.Update(w)
		} else if !d.Empty() { // exactly Hub.pump: empty deltas are never sent
			b, err := EncodeSnapshotDelta(d)
			encode("delta", b, err)
		}
	}
	return frames, w.Snapshot(streamObserver)
}

// TestCrossTierStreamFixture proves the committed stream fixture is exactly
// what the shipped pipeline emits, and that its end state is the server's
// authoritative view — the anchor the client replica store folds against.
func TestCrossTierStreamFixture(t *testing.T) {
	frames, end := runStreamScenario(t)

	// The scenario must exercise every delta surface the store applies, or
	// the fixture would under-pin the contract it exists to anchor.
	var entered, moved, left, resyncs int
	for i, f := range frames {
		raw, err := hex.DecodeString(f.Hex)
		if err != nil {
			t.Fatalf("frame %d: %v", i, err)
		}
		m, err := Decode(raw)
		if err != nil {
			t.Fatalf("frame %d: %v", i, err)
		}
		switch m.Kind {
		case KindSnapshot:
			if i > 0 {
				resyncs++
			}
		case KindSnapshotDelta:
			entered += len(m.Delta.Entered)
			moved += len(m.Delta.Moved)
			left += len(m.Delta.Left)
		}
	}
	if entered == 0 || moved == 0 || left == 0 || resyncs == 0 {
		t.Fatalf("scenario under-pins the stream contract: entered=%d moved=%d left=%d resyncs=%d — every kind must appear", entered, moved, left, resyncs)
	}

	if os.Getenv("WAR_RECORD_STREAM") != "" {
		record := streamFixture{
			Observer: uint64(streamObserver),
			Frames:   frames,
			EndState: snapshotToFixture(end),
		}
		out, err := json.MarshalIndent(record, "  ", "  ")
		if err != nil {
			t.Fatalf("marshal record: %v", err)
		}
		fmt.Printf("STREAM FIXTURE RECORD:\n%s\n", out)
		return
	}

	raw, err := os.ReadFile(wireFixturePath)
	if err != nil {
		t.Fatalf("reading shared fixture: %v", err)
	}
	var f wireFixtureWithStream
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("parsing shared fixture: %v", err)
	}
	if f.Stream == nil {
		t.Fatal("shared fixture has no 'stream' section — the client store contract has no anchor")
	}
	if f.Stream.Observer != uint64(streamObserver) {
		t.Fatalf("fixture stream observer = %d, want %d", f.Stream.Observer, streamObserver)
	}
	if !reflect.DeepEqual(f.Stream.Frames, frames) {
		t.Fatalf("fixture stream frames diverge from the shipped pipeline's output — stream semantics moved, which is a wire-contract change to review, never a silent refresh.\n got %d frames, fixture %d", len(frames), len(f.Stream.Frames))
	}
	if f.Stream.EndState == nil {
		t.Fatal("fixture stream has no end_state")
	}
	if !reflect.DeepEqual(f.Stream.EndState, snapshotToFixture(end)) {
		t.Fatalf("fixture end_state = %+v, want the authoritative view %+v", f.Stream.EndState, snapshotToFixture(end))
	}
}

// snapshotToFixture converts an authoritative sim snapshot into the fixture's
// JSON shape.
func snapshotToFixture(s sim.Snapshot) *wireFixtureSnapshot {
	out := &wireFixtureSnapshot{Tick: s.Tick, Observer: uint64(s.Observer)}
	for _, e := range s.Entities {
		out.Entities = append(out.Entities, wireFixtureEntity{
			ID: uint64(e.ID), X: e.Pos.X, Y: e.Pos.Y, Z: e.Pos.Z, Radius: e.Radius,
		})
	}
	return out
}
