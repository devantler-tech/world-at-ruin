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

type coneAuthorityFixture struct {
	CosScale int64               `json:"cos_scale"`
	RangeMM  int64               `json:"range_mm"`
	Cases    []coneAuthorityCase `json:"cases"`
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
