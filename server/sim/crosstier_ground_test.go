package sim

import (
	"encoding/json"
	"os"
	"testing"
)

// TestCrossTierGroundPositions requires every committed client observation to
// match the actual one-actor authoritative step, rather than a copied formula.
func TestCrossTierGroundPositions(t *testing.T) {
	raw, err := os.ReadFile("../../client/tests/data/ground_step_goldens.json")
	if err != nil {
		t.Fatal("shared ground-step observations are missing:", err)
	}
	var fixture struct {
		Version int
		Cases   []struct {
			Name string
			Spec struct {
				Speed int64 `json:"max_speed_mm_s"`
				MinX  int64 `json:"min_x"`
				MinY  int64 `json:"min_y"`
				MinZ  int64 `json:"min_z"`
				MaxX  int64 `json:"max_x"`
				MaxY  int64 `json:"max_y"`
				MaxZ  int64 `json:"max_z"`
			}
			Initial   Vec3
			Inputs    []Vec3
			Positions []Vec3
		}
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	if fixture.Version != 1 || len(fixture.Cases) != 10 {
		t.Fatal("shared position scenario set is incomplete")
	}
	for _, row := range fixture.Cases {
		t.Run(row.Name, func(t *testing.T) {
			if len(row.Inputs) == 0 || len(row.Inputs) != len(row.Positions) {
				t.Fatal("missing per-tick observations")
			}
			world := NewWorld(Bounds{Min: Vec3{row.Spec.MinX, row.Spec.MinY, row.Spec.MinZ}, Max: Vec3{row.Spec.MaxX, row.Spec.MaxY, row.Spec.MaxZ}})
			entity := world.Add(Entity{ID: 1, Pos: row.Initial, MaxSpeed: row.Spec.Speed})
			for i, input := range row.Inputs {
				world.SetIntent(entity.ID, input)
				world.Step()
				if entity.Pos != row.Positions[i] || world.Tick != uint64(i+1) {
					t.Fatalf("tick %d: got %+v, want %+v", i+1, entity.Pos, row.Positions[i])
				}
			}
		})
	}
}
