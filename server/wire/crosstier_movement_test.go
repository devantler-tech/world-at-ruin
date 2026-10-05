package wire

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/sim"
)

// TestCrossTierMovementGoldens binds the Go encoders and decoder to the literal
// movement vectors consumed independently by the Godot client.
func TestCrossTierMovementGoldens(t *testing.T) {
	raw, err := os.ReadFile("../../client/tests/data/movement_goldens.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Intents []struct {
			Sequence uint64
			X, Z     int16
			Sprint   bool
			Hex      string
		}
		Acks []struct {
			Hex   string
			Value struct {
				Sequence uint64 `json:"applied_sequence"`
				Tick     uint64
				X, Y, Z  int64
			}
		}
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Intents) != 3 || len(fixture.Acks) != 2 {
		t.Fatal("missing shared movement vectors")
	}
	for _, row := range fixture.Intents {
		want := MovementIntent{Sequence: row.Sequence, X: row.X, Z: row.Z, Sprint: row.Sprint}
		b, err := EncodeIntent(want)
		if err != nil || hex.EncodeToString(b) != row.Hex {
			t.Fatalf("intent fixture mismatch: %v %x", err, b)
		}
		decoded, err := Decode(b)
		if err != nil || decoded.Intent != want {
			t.Fatalf("intent fixture decode: %v %+v", err, decoded)
		}
	}
	for _, row := range fixture.Acks {
		want := MovementAck{AppliedSequence: row.Value.Sequence, Tick: row.Value.Tick, Pos: sim.Vec3{X: row.Value.X, Y: row.Value.Y, Z: row.Value.Z}}
		b, err := EncodeMovementAck(want)
		if err != nil || hex.EncodeToString(b) != row.Hex {
			t.Fatalf("ACK fixture mismatch: %v %x", err, b)
		}
		decoded, err := Decode(b)
		if err != nil || decoded.Ack != want {
			t.Fatalf("ACK fixture decode: %v %+v", err, decoded)
		}
	}
}
