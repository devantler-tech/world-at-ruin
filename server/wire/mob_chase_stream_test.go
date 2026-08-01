package wire

// Cross-tier mob-chase evidence (issue #357).
//
// The ordinary replication fixture proves that a populated table renders, but
// its entities are static and are applied directly to the store. This fixture
// starts with the real authoritative World, advances the registered mob through
// Step, snapshots that state through the shipped wire encoder, and gives the
// client a frame sequence it folds through ZoneConnection before rendering.
//
// Regenerating is a deliberate, reviewed act:
//
//	WAR_RECORD_MOB_CHASE_STREAM=1 go test ./wire/ -run TestMobChaseStreamFixture -v
//
// prints the exact JSON to place in the shared fixture's `mob_chase` section.

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/sim"
)

const (
	mobChaseObserver    = sim.EntityID(1)
	mobChaseTarget      = sim.EntityID(2)
	mobChaseMob         = sim.EntityID(100)
	mobChaseInterestMM  = 20_000
	mobChaseAggroMM     = 10_000
	mobChaseCastRangeMM = 2_000
	mobChaseSpeedMM     = 3_000
	mobChaseCastTicks   = 6
)

var (
	mobChaseObserverPos = sim.Vec3{X: -15_000, Z: -12_000}
	mobChaseTargetPos   = sim.Vec3{X: -1_000, Z: -13_500}
	mobChaseStartPos    = sim.Vec3{X: -7_000, Z: -11_000}
)

type mobChaseFixtureFrame struct {
	Tick  uint64 `json:"tick"`
	Phase string `json:"phase"`
	Hex   string `json:"hex"`
}

type mobChaseFixture struct {
	Observer          uint64                 `json:"observer"`
	Mob               uint64                 `json:"mob"`
	Target            uint64                 `json:"target"`
	CastRangeMM       int64                  `json:"cast_range_mm"`
	Frames            []mobChaseFixtureFrame `json:"frames"`
	StationaryControl mobChaseFixtureFrame   `json:"stationary_control"`
}

type wireFixtureWithMobChase struct {
	MobChase *mobChaseFixture `json:"mob_chase"`
}

func newMobChaseFixtureWorld(chaseSpeed int64) *sim.World {
	w := sim.NewWorld(sim.DemoBounds)
	w.Add(sim.Entity{
		ID:             mobChaseObserver,
		Pos:            mobChaseObserverPos,
		Radius:         400,
		InterestRadius: mobChaseInterestMM,
	})
	w.Add(sim.Entity{ID: mobChaseTarget, Pos: mobChaseTargetPos, Radius: 400})
	w.Add(sim.Entity{ID: mobChaseMob, Pos: mobChaseStartPos, Radius: 400, MaxSpeed: mobChaseSpeedMM})
	w.AddMob(mobChaseMob, sim.MobParams{
		AggroRadiusMM:  mobChaseAggroMM,
		CastRangeMM:    mobChaseCastRangeMM,
		ChaseSpeedMM:   chaseSpeed,
		CastTicks:      mobChaseCastTicks,
		CooldownTicks:  600,
		CircleRadiusMM: 1_500,
	})
	return w
}

func encodeMobChaseFrame(t *testing.T, w *sim.World, phase string) mobChaseFixtureFrame {
	t.Helper()
	encoded, err := EncodeSnapshotVersion(w.Snapshot(mobChaseObserver), LegacyVersion)
	if err != nil {
		t.Fatalf("encode %s frame at tick %d: %v", phase, w.Tick, err)
	}
	decoded, err := Decode(encoded)
	if err != nil {
		t.Fatalf("decode-verify %s frame at tick %d: %v", phase, w.Tick, err)
	}
	if decoded.Kind != KindSnapshot {
		t.Fatalf("%s frame at tick %d encoded as kind %d, want snapshot", phase, w.Tick, decoded.Kind)
	}
	return mobChaseFixtureFrame{Tick: w.Tick, Phase: phase, Hex: hex.EncodeToString(encoded)}
}

func runMobChaseFixture(t *testing.T) mobChaseFixture {
	t.Helper()
	w := newMobChaseFixtureWorld(mobChaseSpeedMM)
	frames := []mobChaseFixtureFrame{encodeMobChaseFrame(t, w, "approach")}
	castStartTick := uint64(0)

	for range 120 {
		w.Step()
		casts := w.ActiveCasts()
		if len(casts) > 0 {
			if castStartTick == 0 {
				castStartTick = w.Tick
				frames = append(frames, encodeMobChaseFrame(t, w, "cast_start"))
			} else if w.Tick-castStartTick <= 2 {
				frames = append(frames, encodeMobChaseFrame(t, w, "cast_hold"))
			}
			if w.Tick-castStartTick >= 2 {
				break
			}
			continue
		}
		if w.Tick%10 == 0 {
			frames = append(frames, encodeMobChaseFrame(t, w, "approach"))
		}
	}
	if castStartTick == 0 {
		t.Fatal("authoritative fixture never reached a cast")
	}

	stationary := newMobChaseFixtureWorld(0)
	stationary.Step()
	if casts := stationary.ActiveCasts(); len(casts) != 1 {
		t.Fatalf("zero-speed control did not preserve the stationary cast: %+v", casts)
	}

	return mobChaseFixture{
		Observer:          uint64(mobChaseObserver),
		Mob:               uint64(mobChaseMob),
		Target:            uint64(mobChaseTarget),
		CastRangeMM:       mobChaseCastRangeMM,
		Frames:            frames,
		StationaryControl: encodeMobChaseFrame(t, stationary, "stationary_control"),
	}
}

func snapshotEntity(t *testing.T, frame mobChaseFixtureFrame, id sim.EntityID) sim.EntityState {
	t.Helper()
	raw, err := hex.DecodeString(frame.Hex)
	if err != nil {
		t.Fatalf("%s frame at tick %d is not hex: %v", frame.Phase, frame.Tick, err)
	}
	decoded, err := Decode(raw)
	if err != nil {
		t.Fatalf("%s frame at tick %d does not decode: %v", frame.Phase, frame.Tick, err)
	}
	for _, entity := range decoded.Snapshot.Entities {
		if entity.ID == id {
			return entity
		}
	}
	t.Fatalf("%s frame at tick %d has no entity %d", frame.Phase, frame.Tick, id)
	return sim.EntityState{}
}

func TestMobChaseStreamFixture(t *testing.T) {
	record := runMobChaseFixture(t)
	if len(record.Frames) < 6 {
		t.Fatalf("fixture has only %d frames; it must show an approach plus a held cast", len(record.Frames))
	}

	var previousDistance2 int64
	var castPos *sim.Vec3
	var approachFrames, heldFrames int
	for i, frame := range record.Frames {
		mob := snapshotEntity(t, frame, mobChaseMob)
		target := snapshotEntity(t, frame, mobChaseTarget)
		delta := mob.Pos.Sub(target.Pos)
		distance2 := delta.X*delta.X + delta.Z*delta.Z
		switch frame.Phase {
		case "approach":
			approachFrames++
			if i > 0 && distance2 >= previousDistance2 {
				t.Fatalf("approach frame %d did not close: distance² %d after %d", i, distance2, previousDistance2)
			}
		case "cast_start", "cast_hold":
			if distance2 > (mobChaseCastRangeMM+mob.Radius+target.Radius)*(mobChaseCastRangeMM+mob.Radius+target.Radius) {
				t.Fatalf("%s frame is outside cast range: distance² %d", frame.Phase, distance2)
			}
			if castPos == nil {
				pos := mob.Pos
				castPos = &pos
			} else if mob.Pos != *castPos {
				t.Fatalf("mob drifted during cast: %+v -> %+v", *castPos, mob.Pos)
			}
			if frame.Phase == "cast_hold" {
				heldFrames++
			}
		default:
			t.Fatalf("fixture frame %d has unknown phase %q", i, frame.Phase)
		}
		previousDistance2 = distance2
	}
	if approachFrames < 3 || heldFrames < 2 {
		t.Fatalf("fixture under-evidences the motion: approach=%d held=%d", approachFrames, heldFrames)
	}

	controlMob := snapshotEntity(t, record.StationaryControl, mobChaseMob)
	if controlMob.Pos != mobChaseStartPos {
		t.Fatalf("stationary control moved from %+v to %+v", mobChaseStartPos, controlMob.Pos)
	}

	if os.Getenv("WAR_RECORD_MOB_CHASE_STREAM") != "" {
		out, err := json.MarshalIndent(record, "  ", "  ")
		if err != nil {
			t.Fatalf("marshal record: %v", err)
		}
		fmt.Printf("MOB CHASE FIXTURE RECORD:\n%s\n", out)
		return
	}

	raw := readWireFixture(t)
	var fixture wireFixtureWithMobChase
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatalf("parsing shared fixture: %v", err)
	}
	if fixture.MobChase == nil {
		t.Fatal("shared fixture has no 'mob_chase' section — the default chase has no cross-tier evidence")
	}
	if !reflect.DeepEqual(*fixture.MobChase, record) {
		t.Fatal("shared mob_chase fixture diverges from the authoritative tick and encoder")
	}
}
