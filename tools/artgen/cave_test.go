package artgen

import "testing"

func TestCaveIsDeterministic(t *testing.T) {
	a := Cave(CaveParams{Seed: 42, Radius: 8})
	b := Cave(CaveParams{Seed: 42, Radius: 8})
	if a.Manifest() != b.Manifest() {
		t.Fatalf("same seed produced different manifests:\n%s\n%s", a.Manifest(), b.Manifest())
	}
}

func TestSeedsProduceDifferentCaves(t *testing.T) {
	a := Cave(CaveParams{Seed: 42, Radius: 8})
	b := Cave(CaveParams{Seed: 43, Radius: 8})
	if a.Manifest() == b.Manifest() {
		t.Fatalf("different seeds produced identical manifests: %s", a.Manifest())
	}
}

func TestCaveHasAnEntrance(t *testing.T) {
	full := Icosphere(5)
	cave := Cave(CaveParams{Seed: 42, Radius: 8})
	if len(cave.Tris) >= len(full.Tris) {
		t.Fatalf("no entrance cut: cave has %d tris, sphere has %d", len(cave.Tris), len(full.Tris))
	}
	if len(cave.Verts) == 0 || len(cave.Tris) == 0 {
		t.Fatal("empty cave")
	}
}

func TestFloorBandIsFlattened(t *testing.T) {
	p := CaveParams{Seed: 42, Radius: 8}
	cave := Cave(p)
	floorZ := -0.55 * p.Radius
	// No vertex may sit meaningfully below the rumpled floor band.
	limit := floorZ - 0.08*p.Radius*2 // fbm(±1) amplitude bound over 4 octaves < 2
	for _, v := range cave.Verts {
		if v.Z < limit {
			t.Fatalf("vertex below the floor band: z=%f < %f", v.Z, limit)
		}
	}
}
