package zonesock

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/internal/groundgoldens"
	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/devantler-tech/world-at-ruin/server/wire"
)

// TestCrossTierDirectionVelocity checks fixture vectors with the production wire converter.
func TestCrossTierDirectionVelocity(t *testing.T) {
	raw, err := os.ReadFile("../../client/tests/data/ground_step_goldens.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture groundgoldens.Fixture
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	if fixture.Version != 1 || len(fixture.Directions) != 6 {
		t.Fatal("shared direction scenario set is incomplete")
	}
	for _, row := range fixture.Directions {
		i := wire.MovementIntent{Sequence: 1, X: row.Sample.X, Z: row.Sample.Z, Sprint: row.Sample.Sprint}
		want := sim.Vec3{X: row.Velocity.X, Y: row.Velocity.Y, Z: row.Velocity.Z}
		if _, err := wire.EncodeIntent(i); err != nil {
			t.Fatal("noncanonical direction fixture:", err)
		}
		if got := movementVelocity(i, row.Spec.MaxSpeedMMPerS); got != want {
			t.Fatalf("direction %+v at cap %d: got %+v, want %+v", i, row.Spec.MaxSpeedMMPerS, got, want)
		}
	}
}
