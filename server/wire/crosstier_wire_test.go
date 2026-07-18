package wire

// Cross-tier wire goldens (issue #178).
//
// The package's own golden tests pin the byte layout in Go; the client's
// decoder (client/scripts/wire_codec.gd) must read exactly the same bytes to
// exactly the same values. Both tiers therefore assert ONE committed fixture,
// client/tests/data/wire_goldens.json — this test proves the shipped codec
// agrees with the fixture in BOTH directions (encode(values) == hex and
// decode(hex) == values) and that the fixture's hex is byte-identical to the
// in-package golden constants, so neither the fixture nor either tier can
// drift without tests moving together. The same shared-fixture pattern as the
// cross-tier cone agreement (#159, client/tests/data/cross_tier_cone.json).

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/sim"
)

// wireFixturePath is deliberately the client's data directory: the fixture
// must live somewhere Godot can reach over res:// (the client test runs with
// --path client), matching the cross-tier cone fixture's placement.
var wireFixturePath = filepath.Join("..", "..", "client", "tests", "data", "wire_goldens.json")

type wireFixtureEntity struct {
	ID     uint64 `json:"id"`
	X      int64  `json:"x"`
	Y      int64  `json:"y"`
	Z      int64  `json:"z"`
	Radius int64  `json:"radius"`
}

type wireFixtureSnapshot struct {
	Tick     uint64              `json:"tick"`
	Observer uint64              `json:"observer"`
	Entities []wireFixtureEntity `json:"entities"`
}

type wireFixtureDelta struct {
	Tick    uint64              `json:"tick"`
	Entered []wireFixtureEntity `json:"entered"`
	Moved   []wireFixtureEntity `json:"moved"`
	Left    []uint64            `json:"left"`
}

type wireFixtureMessage struct {
	Name     string               `json:"name"`
	Kind     string               `json:"kind"`
	Hex      string               `json:"hex"`
	Snapshot *wireFixtureSnapshot `json:"snapshot"`
	Delta    *wireFixtureDelta    `json:"delta"`
}

type wireFixture struct {
	Messages []wireFixtureMessage `json:"messages"`
}

func loadWireFixture(t *testing.T) wireFixture {
	t.Helper()
	raw, err := os.ReadFile(wireFixturePath)
	if err != nil {
		t.Fatalf("reading shared fixture: %v", err)
	}
	var f wireFixture
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("parsing shared fixture: %v", err)
	}
	return f
}

func fixtureStates(entities []wireFixtureEntity) []sim.EntityState {
	if len(entities) == 0 {
		return nil
	}
	out := make([]sim.EntityState, len(entities))
	for i, e := range entities {
		out[i] = sim.EntityState{
			ID:     sim.EntityID(e.ID),
			Pos:    sim.Vec3{X: e.X, Y: e.Y, Z: e.Z},
			Radius: e.Radius,
		}
	}
	return out
}

func fixtureIDs(ids []uint64) []sim.EntityID {
	if len(ids) == 0 {
		return nil
	}
	out := make([]sim.EntityID, len(ids))
	for i, id := range ids {
		out[i] = sim.EntityID(id)
	}
	return out
}

// TestWireFixtureAgreesWithCodec is the Go half of the cross-tier contract:
// for each fixture message, the shipped encoder must produce exactly the
// fixture's bytes from the fixture's values, and the shipped decoder must read
// them back to the same values. The client test asserts the decoding half in
// GDScript against the same file.
func TestWireFixtureAgreesWithCodec(t *testing.T) {
	f := loadWireFixture(t)
	if len(f.Messages) != 2 {
		t.Fatalf("fixture carries %d messages, want exactly 2 (snapshot + delta)", len(f.Messages))
	}
	seen := map[string]bool{}
	for _, m := range f.Messages {
		seen[m.Kind] = true
		switch m.Kind {
		case "snapshot":
			if m.Snapshot == nil {
				t.Fatalf("message %q has kind snapshot but no snapshot values", m.Name)
			}
			want := sim.Snapshot{
				Tick:     m.Snapshot.Tick,
				Observer: sim.EntityID(m.Snapshot.Observer),
				Entities: fixtureStates(m.Snapshot.Entities),
			}
			encoded, err := EncodeSnapshot(want)
			if err != nil {
				t.Fatalf("encoding fixture snapshot: %v", err)
			}
			if got := hex.EncodeToString(encoded); got != m.Hex {
				t.Fatalf("fixture snapshot hex does not match the shipped codec —\n got %s\nwant %s\nthe fixture and the wire layout must move together, deliberately", got, m.Hex)
			}
			decoded, err := Decode(encoded)
			if err != nil {
				t.Fatalf("decoding fixture snapshot bytes: %v", err)
			}
			if decoded.Kind != KindSnapshot || !reflect.DeepEqual(decoded.Snapshot, want) {
				t.Fatalf("fixture snapshot round-trip mismatch: %+v", decoded)
			}
		case "delta":
			if m.Delta == nil {
				t.Fatalf("message %q has kind delta but no delta values", m.Name)
			}
			want := sim.SnapshotDelta{
				Tick:    m.Delta.Tick,
				Entered: fixtureStates(m.Delta.Entered),
				Moved:   fixtureStates(m.Delta.Moved),
				Left:    fixtureIDs(m.Delta.Left),
			}
			encoded, err := EncodeSnapshotDelta(want)
			if err != nil {
				t.Fatalf("encoding fixture delta: %v", err)
			}
			if got := hex.EncodeToString(encoded); got != m.Hex {
				t.Fatalf("fixture delta hex does not match the shipped codec —\n got %s\nwant %s\nthe fixture and the wire layout must move together, deliberately", got, m.Hex)
			}
			decoded, err := Decode(encoded)
			if err != nil {
				t.Fatalf("decoding fixture delta bytes: %v", err)
			}
			if decoded.Kind != KindSnapshotDelta || !reflect.DeepEqual(decoded.Delta, want) {
				t.Fatalf("fixture delta round-trip mismatch: %+v", decoded)
			}
		default:
			t.Fatalf("message %q has unknown kind %q", m.Name, m.Kind)
		}
	}
	if !seen["snapshot"] || !seen["delta"] {
		t.Fatalf("fixture must carry one snapshot and one delta golden, saw %v", seen)
	}
}

// TestWireFixtureMatchesPackageGoldens pins the fixture's hex to the
// in-package golden constants byte-for-byte, so the shared file and the Go
// test literals cannot drift apart silently (a layout change must edit both,
// visibly, alongside a Version bump).
func TestWireFixtureMatchesPackageGoldens(t *testing.T) {
	f := loadWireFixture(t)
	want := map[string]string{
		"snapshot": goldenSnapshotHex,
		"delta":    goldenDeltaHex,
	}
	for _, m := range f.Messages {
		expected, ok := want[m.Kind]
		if !ok {
			t.Fatalf("message %q has unexpected kind %q", m.Name, m.Kind)
		}
		if m.Hex != expected {
			t.Fatalf("fixture %s hex diverges from the package golden —\n got %s\nwant %s", m.Kind, m.Hex, expected)
		}
	}
}
