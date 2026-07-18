package sim

// Telegraph resolution is how the authoritative zone decides *who was caught* by
// a shape painted on the ground. It is the combat counterpart to AoI: where
// Interest answers "who can this observer see", a telegraph answers "who is
// standing in this danger right now".
//
// The client already asks this exact question — `client/scripts/telegraph.gd`
// runs the same four predicates so a player can see whether they are standing in
// danger before it lands. Its doc states the load-bearing law: BOTH TIERS ASK
// THE SAME SPATIAL QUESTION AND MUST GET THE SAME ANSWER. If the two diverge,
// the player dodges on screen and is hit on the server — precisely the desync
// telegraphs exist to prevent. So every semantic here mirrors the client
// deliberately: membership is measured on the XZ plane (a telegraph is a mark on
// the ground, so a target's height never changes whether it is caught), every
// edge is INCLUSIVE, the cone's apex counts as inside, a negative extent is
// degenerate and catches nothing, and a degenerate facing falls back to
// world-forward (-Z).
//
// Like the tick core and AoI, resolution is deterministic and integer-only.
// There is no float and no isqrt truncation anywhere in the test: circle and
// ring are exact int64 squared-distance comparisons, while the cone's angular
// test and the rect's projection use exact math/big comparisons for the
// intermediates that outgrow int64. The cone carries its half-angle as a
// PRECOMPUTED SCALED COSINE, so the authoritative path never calls a
// trigonometric function. Resolution is a read-only query over world state and
// is never part of Step, so it cannot move the movement golden hash.
//
// Point-vs-capsule is a deliberate, documented choice: the resolver tests an
// entity's POSITION, exactly as the client's predicates do, because prediction
// and authority must agree. Radius-aware (capsule-extent) resolution is a
// follow-up child, and changing it must change BOTH tiers together.

import "math/big"

// ShapeKind names the four telegraph shapes, mirroring the client's four
// predicates one-for-one.
type ShapeKind uint8

const (
	// ShapeCircle is a filled disc — "the mob casts a circle you must step out of".
	ShapeCircle ShapeKind = iota
	// ShapeRing is an annulus: a danger band with a safe hole in the middle and
	// safety beyond the rim.
	ShapeRing
	// ShapeCone is a sector opening toward the facing — "the telegraph you cast".
	ShapeCone
	// ShapeRect is an oriented beam extending forward from its near edge.
	ShapeRect
)

// CosScale is the fixed-point scale for a cone's half-angle cosine: a caller
// supplies cos(halfAngle)·CosScale as an integer, so the authoritative path
// never evaluates a trigonometric function (which is neither integer nor
// reliably identical across platform math libraries).
//
// QUANTIZATION CONTRACT. The client compares against cos(deg_to_rad(half)) in
// floating point, so the two tiers agree exactly only when the SAME quantized
// cosine is the single source of truth — the ability data must carry this
// integer and the client must consume it, rather than each tier deriving a
// threshold from degrees independently. Wiring that shared value through the
// ability layer is tracked in issue #118 (it is blocked on the ability data of
// #70 actually carrying telegraph shape to both tiers); until then two
// properties keep the difference harmless:
//
//   - Magnitude. One quantum is 1e-6 of cosine, i.e. an angular error of about
//     1e-6/sin(half) rad. For a 45° half-angle that is ~1.4e-6 rad — about
//     0.04 mm of lateral error at a 30 m telegraph, and ~5.7 mm even at the 4 km
//     extent cap. At realistic telegraph sizes it is below the world's own 1 mm
//     resolution, so it cannot move a hit by a representable distance.
//   - Direction of the bias. Authors must round the scaled cosine UP (toward
//     +1), which makes the server's wedge never WIDER than the client's. The
//     residual disagreement then only ever spares a player the client drew as
//     hit, never hits one the client drew as safe — the failure direction a
//     dodge-based game should prefer.
const CosScale = 1_000_000

// maxTelegraphExtentMM bounds a telegraph's linear extents (radius, range,
// length, half-width). Extents are server-authored ability data, not untrusted
// client input, but bounding them keeps every comparison overflow-safe for any
// stored value. The cap (4e6 mm) exceeds any legal zone's ground diagonal — at
// most 2·√2·maxWorldExtentMM ≈ 2.83e6 mm — so a telegraph at the cap can cover
// an entire legal zone.
const maxTelegraphExtentMM = 4 * maxWorldExtentMM

// A facing is deliberately NOT bounded. Clipping its components independently
// would ROTATE the direction — (4e6, 0, 1e6) clipped to (2e6, 0, 1e6) is a
// different heading — so the authoritative shape would point somewhere the
// client's normalised facing does not, which is the very desync this file
// exists to prevent. Instead the facing is used verbatim and the products it
// appears in are evaluated in math/big, which cannot overflow whatever the
// caller passes. Only the ORIGIN and the query point are bounded (see
// planarOrigin and the guard at the top of Catches), which is what keeps the
// cheap int64 distance path safe.

// Telegraph is a shape painted on the ground, awaiting resolution. Build one
// with a constructor rather than by hand: the constructors bound the origin and
// the extents, which is what makes the cheap int64 comparisons in Catches
// overflow-safe. The FACING is deliberately left unbounded — clipping it would
// rotate the shape (see the note above planarFacing) — so the products it
// appears in are evaluated in math/big instead. Fields not used by a Kind are
// ignored.
type Telegraph struct {
	Kind ShapeKind

	// Origin is the shape's anchor: the centre of a circle or ring, the apex of
	// a cone, or the centre of a rect's NEAR edge (the caster end).
	Origin Vec3

	// Facing is the planar direction a cone opens toward or a rect extends
	// along. It need not be normalised. A degenerate (zero) facing falls back to
	// world-forward (-Z), matching the client. Ignored by circle and ring.
	Facing Vec3

	// Outer is the circle's radius, the ring's outer radius, the cone's range,
	// or the rect's length, in mm.
	Outer int64

	// Inner is the ring's inner radius in mm. Ignored by the other shapes.
	Inner int64

	// HalfWidth is the rect's extent to EACH side of its facing, in mm.
	HalfWidth int64

	// CosHalf is the cone's cos(halfAngle)·CosScale, in [-CosScale, CosScale].
	// The half-angle spans to EACH side of the facing, so the full opening is
	// twice it; CosHalf = -CosScale (half-angle 180°) degenerates to a full disc
	// of Outer, matching the client's clamp.
	CosHalf int64
}

// CircleTelegraph returns a filled disc of radius mm around center.
func CircleTelegraph(center Vec3, radius int64) Telegraph {
	return Telegraph{Kind: ShapeCircle, Origin: planarOrigin(center), Outer: clampExtent(radius)}
}

// RingTelegraph returns an annulus around center between the two radii. The
// radii may be given in either order; a negative inner is treated as zero (a
// filled disc), matching the client.
func RingTelegraph(center Vec3, inner, outer int64) Telegraph {
	lo, hi := inner, outer
	if lo > hi {
		lo, hi = hi, lo
	}
	if lo < 0 {
		lo = 0
	}
	return Telegraph{Kind: ShapeRing, Origin: planarOrigin(center), Inner: clampExtent(lo), Outer: clampExtent(hi)}
}

// ConeTelegraph returns a sector with its apex at apex, opening toward facing,
// reaching rangeMM, and spanning the half-angle whose cosine is
// cosHalfScaled/CosScale to each side of the facing.
func ConeTelegraph(apex, facing Vec3, rangeMM, cosHalfScaled int64) Telegraph {
	return Telegraph{
		Kind:    ShapeCone,
		Origin:  planarOrigin(apex),
		Facing:  planarFacing(facing),
		Outer:   clampExtent(rangeMM),
		CosHalf: clampAxis(cosHalfScaled, -CosScale, CosScale),
	}
}

// RectTelegraph returns an oriented beam whose near edge is centred on origin,
// extending length mm along facing and halfWidth mm to each side.
func RectTelegraph(origin, facing Vec3, length, halfWidth int64) Telegraph {
	return Telegraph{
		Kind:      ShapeRect,
		Origin:    planarOrigin(origin),
		Facing:    planarFacing(facing),
		Outer:     clampExtent(length),
		HalfWidth: clampExtent(halfWidth),
	}
}

// clampExtent bounds a linear extent into [-maxTelegraphExtentMM,
// maxTelegraphExtentMM]. Negative values survive clamping because a negative
// extent is meaningful: it is the degenerate "catches nothing" case the client
// also honours.
func clampExtent(v int64) int64 {
	return clampAxis(v, -maxTelegraphExtentMM, maxTelegraphExtentMM)
}

// planarFacing drops a facing's vertical component — a telegraph opens along
// the ground, never up. The magnitude is left untouched: only the DIRECTION is
// ever read, and preserving it exactly is what keeps the server's shape aligned
// with the client's normalised one.
func planarFacing(f Vec3) Vec3 {
	return Vec3{X: f.X, Z: f.Z}
}

// planarOrigin clamps a telegraph's anchor into the legal world box. This is
// what restores horizontalDist2's documented precondition ("overflow-safe for
// any two in-bounds positions"): with a bounded origin and the bounded query
// point enforced by Catches, every delta component is at most
// 2·maxWorldExtentMM, so each squared planar distance stays at most 8e12 —
// far below the int64 ceiling. Without it a far-flung origin wraps dx·dx and a
// 1 mm circle 10 000 km away catches the world centre. The vertical component
// is carried through untouched because membership never reads it.
func planarOrigin(v Vec3) Vec3 {
	return Vec3{
		X: clampAxis(v.X, -maxWorldExtentMM, maxWorldExtentMM),
		Y: v.Y,
		Z: clampAxis(v.Z, -maxWorldExtentMM, maxWorldExtentMM),
	}
}

// planarDir returns the facing to test against, substituting world-forward (-Z)
// for a degenerate (zero) planar facing so a shape is always well-defined —
// the same fallback the client makes.
func planarDir(f Vec3) Vec3 {
	if f.X == 0 && f.Z == 0 {
		return Vec3{Z: -1}
	}
	return Vec3{X: f.X, Z: f.Z}
}

// planarDot returns the exact planar dot product a·b as a big.Int. One operand
// is usually the unbounded facing (see the note above planarFacing), so this
// product can outgrow int64; math/big keeps it exact and host-independent for
// any caller input, where a float would not be.
func planarDot(a, b Vec3) *big.Int {
	return new(big.Int).Add(
		new(big.Int).Mul(big.NewInt(a.X), big.NewInt(b.X)),
		new(big.Int).Mul(big.NewInt(a.Z), big.NewInt(b.Z)),
	)
}

// Catches reports whether the point p is inside the telegraph. Membership is
// planar: p's vertical component is ignored, so a tall or hovering target at the
// same footprint is caught the same way. Every edge is inclusive.
func (t Telegraph) Catches(p Vec3) bool {
	// A point outside the legal world box is never caught. Every entity position
	// is already clamped into that box, so this never fires for a real query —
	// it exists so a caller passing a computed or out-of-range point gets a
	// correct `false` instead of wrapped arithmetic. Together with planarOrigin
	// this is what bounds every delta to 2·maxWorldExtentMM and keeps the int64
	// products below in range.
	if p.X < -maxWorldExtentMM || p.X > maxWorldExtentMM ||
		p.Z < -maxWorldExtentMM || p.Z > maxWorldExtentMM {
		return false
	}
	switch t.Kind {
	case ShapeCircle:
		if t.Outer < 0 {
			return false
		}
		// Exact int64: both operands are bounded (see the two extent consts), so
		// d2 <= 8e12 and Outer² <= 1.6e13 stay far below the int64 ceiling.
		return horizontalDist2(t.Origin, p) <= t.Outer*t.Outer
	case ShapeRing:
		if t.Outer < 0 {
			return false
		}
		d2 := horizontalDist2(t.Origin, p)
		return d2 >= t.Inner*t.Inner && d2 <= t.Outer*t.Outer
	case ShapeCone:
		return t.catchesCone(p)
	case ShapeRect:
		return t.catchesRect(p)
	}
	return false
}

// catchesCone tests membership in a sector. The angular comparison is exact and
// integer-only: rather than normalising (which needs a square root and would
// truncate), it compares the SQUARES of both sides of
//
//	dot·CosScale  >=  CosHalf·√(len2·dirLen2)
//
// which removes the root entirely. Squaring flips the inequality when both
// sides are negative, so the four sign cases are handled explicitly. The squared
// operands reach ~6.4e37, far past int64, so the comparison is done in math/big
// — exact and host-independent, unlike a float.
func (t Telegraph) catchesCone(p Vec3) bool {
	if t.Outer < 0 {
		return false
	}
	to := Vec3{X: p.X - t.Origin.X, Z: p.Z - t.Origin.Z}
	len2 := to.X*to.X + to.Z*to.Z
	// Out of range: the range edge is inclusive.
	if len2 > t.Outer*t.Outer {
		return false
	}
	// On the apex: fully inside, rather than asking for a direction that does
	// not exist. Mirrors the client's near-zero-distance short circuit.
	if len2 == 0 {
		return true
	}
	dir := planarDir(t.Facing)
	// The facing is unbounded on purpose (bounding it would rotate it), so every
	// product it appears in is evaluated in math/big — exact for any caller input.
	dot := planarDot(to, dir)
	sign := dot.Sign()
	// A half-angle of at least 90° (CosHalf <= 0) admits everything in the
	// forward half-plane outright; a half-angle under 90° (CosHalf > 0) excludes
	// the entire backward half-plane outright.
	if sign >= 0 && t.CosHalf <= 0 {
		return true
	}
	if sign < 0 && t.CosHalf > 0 {
		return false
	}
	// lhs = (dot·CosScale)², rhs = CosHalf²·len2·dirLen2.
	lhs := new(big.Int).Mul(dot, big.NewInt(CosScale))
	lhs.Mul(lhs, lhs)
	rhs := new(big.Int).Mul(big.NewInt(t.CosHalf), big.NewInt(t.CosHalf))
	rhs.Mul(rhs, big.NewInt(len2))
	rhs.Mul(rhs, planarDot(dir, dir))
	if sign >= 0 {
		// Both sides non-negative: the inequality survives squaring as-is.
		return lhs.Cmp(rhs) >= 0
	}
	// Both sides negative: squaring reverses the comparison.
	return lhs.Cmp(rhs) <= 0
}

// catchesRect tests membership in an oriented beam. Working with an
// unnormalised facing, the along-axis and across-axis extents both come out
// scaled by |dir|, so each bound is compared in squared form to avoid a square
// root:
//
//	0 <= along <= Outer·|dir|      and      |cross| <= HalfWidth·|dir|
//
// Both squared comparisons reach ~1.3e26, past int64, so they are done exactly
// in math/big.
func (t Telegraph) catchesRect(p Vec3) bool {
	if t.Outer < 0 || t.HalfWidth < 0 {
		return false
	}
	dir := planarDir(t.Facing)
	to := Vec3{X: p.X - t.Origin.X, Z: p.Z - t.Origin.Z}
	// The facing is unbounded on purpose (bounding it would rotate it), so every
	// product it appears in is evaluated in math/big — exact for any caller input.
	dirLen2 := planarDot(dir, dir)
	// Projection along the facing, scaled by |dir|. Points behind the near edge
	// (the caster end) are outside.
	along := planarDot(to, dir)
	if along.Sign() < 0 {
		return false
	}
	// along² <= Outer²·dirLen2 — valid squared form because along >= 0.
	alongSq := new(big.Int).Mul(along, along)
	alongMax := new(big.Int).Mul(big.NewInt(t.Outer), big.NewInt(t.Outer))
	alongMax.Mul(alongMax, dirLen2)
	if alongSq.Cmp(alongMax) > 0 {
		return false
	}
	// Perpendicular extent, also scaled by |dir|; its sign is the side of the
	// beam, so only the magnitude matters.
	cross := new(big.Int).Sub(
		new(big.Int).Mul(big.NewInt(to.X), big.NewInt(dir.Z)),
		new(big.Int).Mul(big.NewInt(to.Z), big.NewInt(dir.X)),
	)
	crossSq := new(big.Int).Mul(cross, cross)
	crossMax := new(big.Int).Mul(big.NewInt(t.HalfWidth), big.NewInt(t.HalfWidth))
	crossMax.Mul(crossMax, dirLen2)
	return crossSq.Cmp(crossMax) <= 0
}

// Caught returns the IDs of every entity standing inside the telegraph — the
// set the server would apply the effect to. The result is in ascending EntityID
// order, so it is deterministic and independent of map iteration order, the same
// requirement the tick step and Interest uphold. It is a read-only query: it
// never mutates the world and is never called from Step, so it cannot move the
// movement golden hash.
//
// Every entity is tested, including whoever cast the telegraph — caster and
// faction filtering belong to the ability layer that owns the cast, not to the
// geometry.
func (w *World) Caught(t Telegraph) []EntityID {
	var out []EntityID
	// w.order is maintained ascending, so out is ascending without a re-sort.
	for _, id := range w.order {
		if t.Catches(w.ents[id].Pos) {
			out = append(out, id)
		}
	}
	return out
}
