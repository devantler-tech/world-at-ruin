package wire

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/sim"
)

type castStreamFixture struct {
	Observer uint64               `json:"observer"`
	Caster   uint64               `json:"caster"`
	Frames   []streamFixtureFrame `json:"frames"`
	EndState *castStreamEndState  `json:"end_state"`
}

type castStreamEndState struct {
	Tick  uint64        `json:"tick"`
	Casts []fixtureCast `json:"casts"`
}

type fixtureCast struct {
	Caster      uint64 `json:"caster"`
	Kind        uint8  `json:"kind"`
	OriginX     int64  `json:"origin_x"`
	OriginY     int64  `json:"origin_y"`
	OriginZ     int64  `json:"origin_z"`
	FacingX     int64  `json:"facing_x"`
	FacingY     int64  `json:"facing_y"`
	FacingZ     int64  `json:"facing_z"`
	Outer       int64  `json:"outer"`
	Inner       int64  `json:"inner"`
	HalfWidth   int64  `json:"half_width"`
	CosHalf     int64  `json:"cos_half"`
	StartTick   uint64 `json:"start_tick"`
	ResolveTick uint64 `json:"resolve_tick"`
}

type wireFixtureWithCastStream struct {
	CastStream *castStreamFixture `json:"cast_stream"`
}

func fixtureCastFromSim(c sim.ActiveCast) fixtureCast {
	return fixtureCast{
		Caster: uint64(c.Caster), Kind: uint8(c.Shape.Kind),
		OriginX: c.Shape.Origin.X, OriginY: c.Shape.Origin.Y, OriginZ: c.Shape.Origin.Z,
		FacingX: c.Shape.Facing.X, FacingY: c.Shape.Facing.Y, FacingZ: c.Shape.Facing.Z,
		Outer: c.Shape.Outer, Inner: c.Shape.Inner, HalfWidth: c.Shape.HalfWidth, CosHalf: c.Shape.CosHalf,
		StartTick: c.StartTick, ResolveTick: c.ResolveTick,
	}
}

func runCastStreamScenario(t *testing.T) castStreamFixture {
	t.Helper()
	const observer = sim.EntityID(1)
	const caster = sim.EntityID(100)
	w := sim.NewWorld(sim.DemoBounds)
	w.Add(sim.Entity{ID: observer, Pos: sim.Vec3{}, Radius: 400, InterestRadius: 5_000})
	w.Add(sim.Entity{ID: caster, Pos: sim.Vec3{X: 2_000}, Radius: 300})
	w.AddMob(caster, sim.MobParams{
		AggroRadiusMM: 10_000, CastTicks: 3, CooldownTicks: 600, CircleRadiusMM: 1_500,
	})

	var frames []streamFixtureFrame
	encodeSnapshot := func(s sim.Snapshot) {
		b, err := EncodeSnapshot(s)
		if err != nil {
			t.Fatalf("encode cast snapshot at tick %d: %v", s.Tick, err)
		}
		frames = append(frames, streamFixtureFrame{Kind: "snapshot", Hex: hex.EncodeToString(b)})
	}
	encodeDelta := func(d sim.SnapshotDelta) {
		b, err := EncodeSnapshotDelta(d)
		if err != nil {
			t.Fatalf("encode cast delta at tick %d: %v", d.Tick, err)
		}
		frames = append(frames, streamFixtureFrame{Kind: "delta", Hex: hex.EncodeToString(b)})
	}

	encodeSnapshot(w.Snapshot(observer))
	tracker := sim.NewSnapshotTracker(observer)
	tracker.Update(w)
	for range 4 {
		w.Step()
		if d := tracker.Update(w); !d.Empty() {
			encodeDelta(d)
		}
	}

	end := w.Snapshot(observer)
	out := castStreamFixture{
		Observer: uint64(observer), Caster: uint64(caster), Frames: frames,
		EndState: &castStreamEndState{Tick: end.Tick, Casts: []fixtureCast{}},
	}
	for _, cast := range end.Casts {
		out.EndState.Casts = append(out.EndState.Casts, fixtureCastFromSim(cast))
	}
	return out
}

func TestCrossTierCastStreamFixture(t *testing.T) {
	record := runCastStreamScenario(t)
	if len(record.Frames) != 3 {
		t.Fatalf("cast stream emitted %d frames, want join + start + end", len(record.Frames))
	}
	started, ended := 0, 0
	for i, frame := range record.Frames {
		raw, err := hex.DecodeString(frame.Hex)
		if err != nil {
			t.Fatalf("frame %d hex: %v", i, err)
		}
		message, err := Decode(raw)
		if err != nil {
			t.Fatalf("frame %d decode: %v", i, err)
		}
		if message.Version != Version {
			t.Fatalf("frame %d version = %d, want %d", i, message.Version, Version)
		}
		started += len(message.Delta.StartedCasts)
		ended += len(message.Delta.EndedCasts)
	}
	if started != 1 || ended != 1 {
		t.Fatalf("cast lifecycle under-pinned: starts=%d ends=%d", started, ended)
	}

	if os.Getenv("WAR_RECORD_CAST_STREAM") != "" {
		out, err := json.MarshalIndent(record, "  ", "  ")
		if err != nil {
			t.Fatalf("marshal cast stream: %v", err)
		}
		fmt.Printf("CAST STREAM FIXTURE RECORD:\n%s\n", out)
		return
	}

	raw, err := os.ReadFile(wireFixturePath)
	if err != nil {
		t.Fatalf("read shared fixture: %v", err)
	}
	var fixture wireFixtureWithCastStream
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatalf("parse shared fixture: %v", err)
	}
	if fixture.CastStream == nil {
		t.Fatal("shared fixture has no cast_stream section")
	}
	if !reflect.DeepEqual(*fixture.CastStream, record) {
		t.Fatalf("cast_stream fixture diverges from the authoritative tracker + v2 encoder:\n got %+v\nwant %+v", *fixture.CastStream, record)
	}
}
