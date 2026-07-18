package sim

// Cross-tier cone agreement (issue #118).
//
// The client and the server must answer "is this point inside this cone?"
// identically — a disagreement is a player dodging on screen and being hit on
// the server. They used to derive the angular threshold independently (the
// server from a precomputed scaled cosine, the client from degrees), so they
// agreed only up to quantization. Now ability data carries ONE integer
// threshold and both tiers consume it.
//
// This test and client/tests/cross_tier_cone_test.gd read the SAME committed
// fixture, whose expectations were produced by an independent high-precision
// oracle rather than by either implementation. So the two tiers are not merely
// checked against each other — each is checked against a third party, which is
// what makes a shared PASS meaningful rather than a shared bug.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// crossTierFixturePath is deliberately the client's data directory: the fixture
// must live somewhere Godot can reach over res:// (the client test runs with
// --path client), and the repo already keeps its committed ledgers there.
const crossTierFixturePath = "../../client/tests/data/cross_tier_cone.json"

type crossTierPoint struct {
	X int64 `json:"x"`
	Y int64 `json:"y"`
	Z int64 `json:"z"`
}

func (p crossTierPoint) vec() Vec3 { return Vec3{X: p.X, Y: p.Y, Z: p.Z} }

type crossTierProbe struct {
	Point  crossTierPoint `json:"point_mm"`
	Expect bool           `json:"expect_caught"`
	Note   string         `json:"note"`
}

type crossTierCone struct {
	Name          string           `json:"name"`
	Apex          crossTierPoint   `json:"apex_mm"`
	Facing        crossTierPoint   `json:"facing_mm"`
	RangeMM       int64            `json:"range_mm"`
	CosHalfScaled int64            `json:"cos_half_scaled"`
	Probes        []crossTierProbe `json:"probes"`
}

type crossTierFixture struct {
	CosScale int64           `json:"cos_scale"`
	Cones    []crossTierCone `json:"cones"`
}

func loadCrossTierFixture(t *testing.T) crossTierFixture {
	t.Helper()
	raw, err := os.ReadFile(filepath.Clean(crossTierFixturePath))
	if err != nil {
		t.Fatalf("cannot read the shared cross-tier fixture %s: %v", crossTierFixturePath, err)
	}
	var f crossTierFixture
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("cannot decode the shared cross-tier fixture: %v", err)
	}
	return f
}

// TestCrossTierConeFixtureIsSubstantive is the non-vacuity floor. A fixture that
// went missing, emptied, or lost its expectations would turn every assertion
// below into a silent pass — the same failure mode the repo's other data-backed
// guards defend against. It also pins that the fixture's scale IS this package's
// CosScale, since a fixture authored at a different scale would compare a
// threshold against the wrong denominator on both tiers at once.
func TestCrossTierConeFixtureIsSubstantive(t *testing.T) {
	f := loadCrossTierFixture(t)

	if f.CosScale != CosScale {
		t.Fatalf("fixture cos_scale = %d, want the package CosScale %d — a mismatched scale silently rescales every threshold", f.CosScale, CosScale)
	}
	if len(f.Cones) < 2 {
		t.Fatalf("fixture declares %d cones, want at least 2 (a wedge and a degenerate full disc)", len(f.Cones))
	}

	var probes, caught int
	for _, c := range f.Cones {
		if len(c.Probes) == 0 {
			t.Errorf("cone %q has no probes", c.Name)
		}
		for _, p := range c.Probes {
			probes++
			if p.Expect {
				caught++
			}
		}
	}
	if probes < 10 {
		t.Fatalf("fixture has %d probes, want at least 10", probes)
	}
	// Both outcomes must be represented, or a predicate stuck at a constant
	// would satisfy the whole fixture.
	if caught == 0 || caught == probes {
		t.Fatalf("fixture probes are all %v (%d/%d) — it cannot distinguish a correct predicate from a constant", caught > 0, caught, probes)
	}
}

// TestCrossTierConeAgreement is the server half of the shared contract: every
// probe must resolve exactly as the independent oracle says. The client half
// asserts the same expectations against the same file, so a green pair proves
// the two tiers agree by way of both agreeing with a third party.
func TestCrossTierConeAgreement(t *testing.T) {
	f := loadCrossTierFixture(t)

	for _, c := range f.Cones {
		t.Run(c.Name, func(t *testing.T) {
			tg := ConeTelegraph(c.Apex.vec(), c.Facing.vec(), c.RangeMM, c.CosHalfScaled)
			for _, p := range c.Probes {
				got := tg.Catches(p.Point.vec())
				if got != p.Expect {
					t.Errorf("cone %q probe (%d,%d,%d) [%s]: Catches = %v, want %v",
						c.Name, p.Point.X, p.Point.Y, p.Point.Z, p.Note, got, p.Expect)
				}
			}
		})
	}
}

// TestConeThresholdIsConsumedNotDerived guards the property that makes the
// shared integer worth carrying: the resolver must read the threshold it is
// GIVEN, not re-derive one. Feeding two different thresholds to the same
// geometry has to change the answer for a point between them — if it did not,
// the field would be decorative and a client/server divergence could hide
// behind a green fixture.
func TestConeThresholdIsConsumedNotDerived(t *testing.T) {
	apex := Vec3{}
	facing := Vec3{Z: -1000}
	// ~31 degrees off the axis: inside a 45-degree wedge, outside a 15-degree one.
	probe := Vec3{X: 12000, Z: -20000}

	wide := ConeTelegraph(apex, facing, 30000, 707107)   // cos 45 deg
	narrow := ConeTelegraph(apex, facing, 30000, 965926) // cos 15 deg

	if !wide.Catches(probe) {
		t.Errorf("the 45-degree wedge must catch a point ~31 degrees off axis")
	}
	if narrow.Catches(probe) {
		t.Errorf("the 15-degree wedge must NOT catch a point ~31 degrees off axis — the threshold is being ignored")
	}
}

// TestConeCeilRoundingNeverWidensTheServerWedge pins the DIRECTION of the
// authoring-time rounding, which is the safety property behind the whole
// contract. The client converts degrees with a ceil (toward +1); a larger
// cosine is a NARROWER wedge, so the shared threshold can never describe a
// wedge wider than the exact angle an author wrote.
//
// The consequence is asymmetric on purpose: a residual sub-quantum
// disagreement can only ever spare a player the client drew as hit, never hit
// one it drew as safe. Here that is visible at exactly 45 degrees — the point
// on the true edge falls OUTSIDE the quantized wedge.
func TestConeCeilRoundingNeverWidensTheServerWedge(t *testing.T) {
	// cos(45 deg) = 0.707106781..., so the ceil at CosScale is 707107 — strictly
	// greater than the exact cosine, hence a strictly narrower wedge.
	const ceilAt45 = 707107
	if float64(ceilAt45)/CosScale <= 0.7071067811865476 {
		t.Fatalf("707107/%d must exceed cos(45 deg); rounding is not toward +1", CosScale)
	}

	tg := ConeTelegraph(Vec3{}, Vec3{Z: -1000}, 30000, ceilAt45)
	// Exactly on the 45-degree ray: equal X and -Z components.
	onTheExactEdge := Vec3{X: 14000, Z: -14000}
	if tg.Catches(onTheExactEdge) {
		t.Errorf("a point on the exact 45-degree ray must fall OUTSIDE the ceil-quantized wedge — the bias must narrow, never widen")
	}
	// A floor-rounded threshold would have caught it, which is the failure this
	// direction rules out.
	if !ConeTelegraph(Vec3{}, Vec3{Z: -1000}, 30000, 707106).Catches(onTheExactEdge) {
		t.Errorf("sanity: the floor-rounded threshold 707106 should catch the exact-edge point, else this test proves nothing about rounding direction")
	}
}
