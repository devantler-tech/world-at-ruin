package wire

import (
	"encoding/binary"
	"encoding/hex"
	"errors"
	"reflect"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/sim"
)

func TestVersionTwoCarriesCastsAndVersionOneRemainsByteIdentical(t *testing.T) {
	snapshot := goldenSnapshot
	snapshot.Casts = []sim.ActiveCast{{
		Caster:      2,
		Shape:       sim.CircleTelegraph(sim.Vec3{X: -5_000, Z: 12_345}, 2_000),
		StartTick:   599,
		ResolveTick: 610,
	}}

	v1, err := EncodeSnapshotVersion(snapshot, LegacyVersion)
	if err != nil {
		t.Fatalf("encode v1 compatibility snapshot: %v", err)
	}
	if got := hex.EncodeToString(v1); got != goldenSnapshotHex {
		t.Fatalf("v1 bytes moved while adding v2:\n got %s\nwant %s", got, goldenSnapshotHex)
	}
	v1Message, err := Decode(v1)
	if err != nil {
		t.Fatalf("decode retained v1: %v", err)
	}
	if v1Message.Version != LegacyVersion || len(v1Message.Snapshot.Casts) != 0 {
		t.Fatalf("retained v1 decoded as %+v, want entity-only version %d", v1Message, LegacyVersion)
	}

	v2, err := EncodeSnapshot(snapshot)
	if err != nil {
		t.Fatalf("encode v2 snapshot: %v", err)
	}
	v2Message, err := Decode(v2)
	if err != nil {
		t.Fatalf("decode v2 snapshot: %v", err)
	}
	if v2Message.Version != Version || !reflect.DeepEqual(v2Message.Snapshot, snapshot) {
		t.Fatalf("v2 snapshot round trip = %+v, want %+v", v2Message, snapshot)
	}
}

func TestVersionTwoCarriesCastLifecycleDelta(t *testing.T) {
	delta := goldenDelta
	delta.StartedCasts = []sim.ActiveCast{{
		Caster:      2,
		Shape:       sim.ConeTelegraph(sim.Vec3{X: -5_100, Z: 12_400}, sim.Vec3{X: 4, Z: -3}, 3_000, 707_107),
		StartTick:   600,
		ResolveTick: 620,
	}}
	delta.EndedCasts = []sim.EntityID{3}

	b, err := EncodeSnapshotDelta(delta)
	if err != nil {
		t.Fatalf("encode v2 delta: %v", err)
	}
	m, err := Decode(b)
	if err != nil {
		t.Fatalf("decode v2 delta: %v", err)
	}
	if m.Version != Version || !reflect.DeepEqual(m.Delta, delta) {
		t.Fatalf("v2 delta round trip = %+v, want %+v", m, delta)
	}

	v1, err := EncodeSnapshotDeltaVersion(delta, LegacyVersion)
	if err != nil {
		t.Fatalf("encode retained v1 delta: %v", err)
	}
	if got := hex.EncodeToString(v1); got != goldenDeltaHex {
		t.Fatalf("v1 delta bytes moved while adding v2:\n got %s\nwant %s", got, goldenDeltaHex)
	}
}

func TestCastValidationFailsClosedOnBothSides(t *testing.T) {
	valid := sim.Snapshot{
		Tick:     5,
		Observer: 1,
		Entities: []sim.EntityState{{ID: 2, Radius: 300}},
		Casts: []sim.ActiveCast{{
			Caster: 2, Shape: sim.RectTelegraph(sim.Vec3{}, sim.Vec3{Z: -1}, 2_000, 500), StartTick: 4, ResolveTick: 8,
		}},
	}

	badTiming := valid
	badTiming.Casts = append([]sim.ActiveCast(nil), valid.Casts...)
	badTiming.Casts[0].ResolveTick = badTiming.Casts[0].StartTick
	if _, err := EncodeSnapshot(badTiming); !errors.Is(err, ErrCastTiming) {
		t.Fatalf("encode bad cast timing: got %v, want ErrCastTiming", err)
	}

	badShape := valid
	badShape.Casts = append([]sim.ActiveCast(nil), valid.Casts...)
	badShape.Casts[0].Shape.Kind = sim.ShapeKind(99)
	if _, err := EncodeSnapshot(badShape); !errors.Is(err, ErrCastShape) {
		t.Fatalf("encode bad cast shape: got %v, want ErrCastShape", err)
	}

	missingCaster := valid
	missingCaster.Casts = append([]sim.ActiveCast(nil), valid.Casts...)
	missingCaster.Casts[0].Caster = 3
	if _, err := EncodeSnapshot(missingCaster); !errors.Is(err, ErrCastCaster) {
		t.Fatalf("encode cast outside snapshot: got %v, want ErrCastCaster", err)
	}

	b, err := EncodeSnapshot(valid)
	if err != nil {
		t.Fatalf("encode valid control: %v", err)
	}
	castCountOffset := headerSize + tickSize + observerSize + countSize + len(valid.Entities)*entityStateSize
	castOffset := castCountOffset + countSize
	b[castOffset+idSize] = 99 // shape kind follows caster ID
	if _, err := Decode(b); !errors.Is(err, ErrCastShape) {
		t.Fatalf("decode bad cast shape: got %v, want ErrCastShape", err)
	}

	b, err = EncodeSnapshot(valid)
	if err != nil {
		t.Fatalf("encode second valid control: %v", err)
	}
	binary.LittleEndian.PutUint32(b[castCountOffset:], MaxCasts+1)
	if _, err := Decode(b); !errors.Is(err, ErrCount) {
		t.Fatalf("decode hostile cast count: got %v, want ErrCount", err)
	}
}
