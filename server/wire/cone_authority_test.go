package wire

// Cone input authority (issue #1447, ADR 0059).
//
// The server resolves a cone from the shape sim.ConeTelegraph stores, and the
// client paints a cone only when its wire codec and its cast factory both accept
// it. If the server could resolve a cone the client refuses, the danger would be
// invisible. So the server canonicalises at construction, and both wire codecs
// refuse anything that is not canonical.
//
// This test and client/tests/cone_input_authority_test.gd read the SAME
// committed vectors, client/tests/data/cone_input_authority.json, so the two
// tiers cannot drift apart on which raw inputs are acceptable.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/sim"
)

const coneAuthorityFixturePath = "../../client/tests/data/cone_input_authority.json"

type coneAuthorityVec struct {
	X int64 `json:"x"`
	Y int64 `json:"y"`
	Z int64 `json:"z"`
}

func (v coneAuthorityVec) vec() sim.Vec3 { return sim.Vec3{X: v.X, Y: v.Y, Z: v.Z} }

type coneAuthorityCase struct {
	Name             string           `json:"name"`
	Facing           coneAuthorityVec `json:"facing_mm"`
	CosHalf          int64            `json:"cos_half_scaled"`
	WireValid        bool             `json:"wire_valid"`
	CanonicalFacing  coneAuthorityVec `json:"canonical_facing_mm"`
	CanonicalCosHalf int64            `json:"canonical_cos_half_scaled"`
}

// extentAuthorityCase is one circle radius or cone range from the shared extent
// vectors (#1451).
type extentAuthorityCase struct {
	Name      string `json:"name"`
	Kind      string `json:"kind"`
	OuterMM   int64  `json:"outer_mm"`
	WireValid bool   `json:"wire_valid"`
}

// shape builds the raw cast the case describes, with a real heading and an
// in-range threshold for a cone so only the extent decides validity.
func (c extentAuthorityCase) shape(t *testing.T) sim.Telegraph {
	t.Helper()
	switch c.Kind {
	case "circle":
		return sim.Telegraph{Kind: sim.ShapeCircle, Outer: c.OuterMM}
	case "cone":
		return sim.Telegraph{Kind: sim.ShapeCone, Facing: sim.Vec3{Z: -1_000}, Outer: c.OuterMM, CosHalf: 707_107}
	}
	t.Fatalf("%s: unknown extent kind %q", c.Name, c.Kind)
	return sim.Telegraph{}
}

type coneAuthorityFixture struct {
	CosScale    int64                 `json:"cos_scale"`
	RangeMM     int64                 `json:"range_mm"`
	Cases       []coneAuthorityCase   `json:"cases"`
	ExtentCases []extentAuthorityCase `json:"extent_cases"`
}

func loadConeAuthorityFixture(t *testing.T) coneAuthorityFixture {
	t.Helper()
	raw, err := os.ReadFile(filepath.Clean(coneAuthorityFixturePath))
	if err != nil {
		t.Fatalf("cannot read the shared cone authority vectors %s: %v", coneAuthorityFixturePath, err)
	}
	var f coneAuthorityFixture
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("cannot decode the shared cone authority vectors: %v", err)
	}
	return f
}

// TestConeAuthorityVectorsAreSubstantive keeps the shared vectors from passing
// vacuously: they must use this package's scale and cover accepted inputs, an
// out-of-range threshold and a facing with no planar direction.
func TestConeAuthorityVectorsAreSubstantive(t *testing.T) {
	f := loadConeAuthorityFixture(t)
	if f.CosScale != sim.CosScale {
		t.Fatalf("vectors cos_scale = %d, want sim.CosScale %d", f.CosScale, sim.CosScale)
	}
	if f.RangeMM <= 0 {
		t.Fatalf("vectors range_mm = %d, want a positive reach so only facing and threshold decide validity", f.RangeMM)
	}
	var valid, badThreshold, badFacing int
	for _, c := range f.Cases {
		switch {
		case c.WireValid:
			valid++
		case c.CosHalf < -sim.CosScale || c.CosHalf > sim.CosScale:
			badThreshold++
		case c.Facing.X == 0 && c.Facing.Z == 0:
			badFacing++
		}
	}
	if valid == 0 || badThreshold == 0 || badFacing == 0 {
		t.Fatalf("vectors cover valid=%d bad-threshold=%d bad-facing=%d, want every class present", valid, badThreshold, badFacing)
	}
}

// TestConeAuthorityRawInputsMatchTheWireBoundary pins which raw cone inputs the
// server's wire boundary accepts. The client half asserts the same answers for
// its codec and its cast factory.
func TestConeAuthorityRawInputsMatchTheWireBoundary(t *testing.T) {
	f := loadConeAuthorityFixture(t)
	for _, c := range f.Cases {
		raw := sim.Telegraph{Kind: sim.ShapeCone, Facing: c.Facing.vec(), Outer: f.RangeMM, CosHalf: c.CosHalf}
		err := validateCastShape(raw)
		if got := err == nil; got != c.WireValid {
			t.Errorf("%s: wire accepts raw cone = %v (err %v), want %v", c.Name, got, err, c.WireValid)
		}
	}
}

// TestConeTelegraphEmitsOnlyCanonicalCones pins the authority side: whatever the
// input, the cone the server stores — and therefore resolves and sends — is the
// canonical one, and the wire accepts it.
func TestConeTelegraphEmitsOnlyCanonicalCones(t *testing.T) {
	f := loadConeAuthorityFixture(t)
	for _, c := range f.Cases {
		tg := sim.ConeTelegraph(sim.Vec3{}, c.Facing.vec(), f.RangeMM, c.CosHalf)
		if tg.Facing != c.CanonicalFacing.vec() || tg.CosHalf != c.CanonicalCosHalf {
			t.Errorf("%s: ConeTelegraph stored facing %+v threshold %d, want %+v and %d",
				c.Name, tg.Facing, tg.CosHalf, c.CanonicalFacing.vec(), c.CanonicalCosHalf)
		}
		if err := validateCastShape(tg); err != nil {
			t.Errorf("%s: the server's own cone is refused by its wire boundary: %v", c.Name, err)
		}
	}
}

// TestCanonicalFacingResolvesLikeTheFallback proves canonicalising a degenerate
// facing changes no membership answer: the stored world-forward facing catches
// exactly what the previous zero facing caught through the resolution fallback.
func TestCanonicalFacingResolvesLikeTheFallback(t *testing.T) {
	const reach = 3000
	canonical := sim.ConeTelegraph(sim.Vec3{}, sim.Vec3{}, reach, 707_107)
	fallback := sim.Telegraph{Kind: sim.ShapeCone, Outer: reach, CosHalf: 707_107}
	probes := []sim.Vec3{
		{Z: -1_000}, {Z: 1_000}, {X: 1_000}, {X: -1_000},
		{X: 500, Z: -1_000}, {X: 1_500, Z: -1_000}, {Z: -2_999}, {Z: -3_001},
	}
	var caught int
	for _, p := range probes {
		got, want := canonical.Catches(p), fallback.Catches(p)
		if got != want {
			t.Errorf("probe %+v: canonical cone catches = %v, zero-facing fallback = %v", p, got, want)
		}
		if got {
			caught++
		}
	}
	if caught == 0 || caught == len(probes) {
		t.Fatalf("probes caught %d of %d — they cannot tell a wedge from a constant", caught, len(probes))
	}
}

// TestExtentAuthorityMatchesTheWireBoundary pins which circle radii and cone
// ranges the server's wire boundary accepts (#1451). The client half asserts the
// same answers for its codec and its cast factory. The vectors must hold a
// positive, a zero and a negative extent for both kinds.
func TestExtentAuthorityMatchesTheWireBoundary(t *testing.T) {
	covered := map[string]bool{}
	for _, c := range loadConeAuthorityFixture(t).ExtentCases {
		err := validateCastShape(c.shape(t))
		if got := err == nil; got != c.WireValid {
			t.Errorf("%s: wire accepts %s extent %d = %v (err %v), want %v", c.Name, c.Kind, c.OuterMM, got, err, c.WireValid)
		}
		switch {
		case c.WireValid && c.OuterMM > 0:
			covered[c.Kind+"/positive"] = true
		case !c.WireValid && c.OuterMM == 0:
			covered[c.Kind+"/zero"] = true
		case !c.WireValid && c.OuterMM < 0:
			covered[c.Kind+"/negative"] = true
		}
	}
	for _, class := range []string{"circle/positive", "circle/zero", "circle/negative", "cone/positive", "cone/zero", "cone/negative"} {
		if !covered[class] {
			t.Errorf("extent vectors have no %s case", class)
		}
	}
}

// TestMobPaintsExactlyTheWireValidRadii ties the authority to the same vectors:
// a mob starts a circle exactly when both tiers accept its radius, and the
// circle it starts passes the wire, so the server never resolves a warning the
// client refuses to paint.
func TestMobPaintsExactlyTheWireValidRadii(t *testing.T) {
	for _, c := range loadConeAuthorityFixture(t).ExtentCases {
		if c.Kind != "circle" {
			continue
		}
		w := sim.NewWorld(sim.DemoBounds)
		w.Add(sim.Entity{ID: 1, Pos: sim.Vec3{X: 1_000}})
		w.Add(sim.Entity{ID: 100, Radius: 300})
		w.AddMob(100, sim.MobParams{AggroRadiusMM: 10_000, CastTicks: 3, CircleRadiusMM: c.OuterMM})
		w.Step()
		casts := w.ActiveCasts()
		if started := len(casts) > 0; started != c.WireValid {
			t.Errorf("%s: mob with radius %d started a cast = %v, want %v", c.Name, c.OuterMM, started, c.WireValid)
		}
		for _, cast := range casts {
			if err := validateCastShape(cast.Shape); err != nil {
				t.Errorf("%s: the mob's own circle is refused by the wire: %v", c.Name, err)
			}
		}
	}
}
