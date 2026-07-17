package sim

// Capsule-vs-capsule separation: the authoritative rule that two actors never
// occupy the same space. It is the one spatial guarantee a client cannot be
// trusted to make for itself, so the server owns it — and it is a prerequisite
// for everything with spatial extent above it (Phase 2 telegraph overlap and
// melee reach, area-of-interest culling).
//
// Design constraints it honours, same as the rest of the sim:
//
//   - Integer-only, no floating point — the push is computed by integer scaling
//     of the separation axis, so it is bit-identical on every host.
//   - No physics engine. This is positional de-overlap (a geometric constraint
//     solve), not impulse-based rigid-body dynamics: each overlapping pair is
//     pushed apart by half its penetration. Capsule kinematics only.
//   - Order-independent and deterministic. Each relaxation pass reads the
//     positions frozen at the start of the pass and writes the accumulated
//     displacements at the end, iterating pairs in ascending-ID order, so the
//     result never depends on entity insertion order or Go map iteration order.

// separationIterations bounds the relaxation passes run per tick. A single pass
// fully resolves any isolated pair; extra passes let a dense cluster converge
// within one tick, while the fixed cap keeps the step's cost — and its result —
// deterministic. A pass that moves nothing ends the loop early, so the common
// case (nothing overlapping) costs one pair scan and no position writes, which
// is what keeps separation a true no-op when actors are already apart.
const separationIterations = 4

// separate resolves capsule overlap by simultaneous relaxation. Each pass
// accumulates every overlapping pair's half-penetration push into a per-entity
// displacement, then applies them all at once and re-clamps into the navmesh
// bounds. Reading start-of-pass positions and writing end-of-pass makes the
// result independent of the order pairs are visited (hence of insertion order),
// which the determinism law requires.
func (w *World) separate() {
	n := len(w.order)
	if n < 2 {
		return
	}
	delta := make([]Vec3, n)
	for range separationIterations {
		for i := range delta {
			delta[i] = Vec3{}
		}
		moved := false
		for i := range n {
			a := w.ents[w.order[i]]
			for j := i + 1; j < n; j++ {
				b := w.ents[w.order[j]]
				pa, pb := separationPush(a, b)
				if pa != (Vec3{}) || pb != (Vec3{}) {
					delta[i] = delta[i].Add(pa)
					delta[j] = delta[j].Add(pb)
					moved = true
				}
			}
		}
		if !moved {
			return
		}
		for i, id := range w.order {
			e := w.ents[id]
			e.Pos = w.bounds.clamp(e.Pos.Add(delta[i]))
		}
	}
}

// separationPush returns the horizontal displacement to move a and b apart so
// their capsules no longer overlap, split as half the penetration each. It
// reads only the ground-plane (XZ) distance — capsules are vertical, so overlap
// is a horizontal question — and never touches the vertical axis. The returned
// vectors are zero when the pair is not overlapping (touching is allowed).
//
// Determinism details that matter:
//   - The odd millimetre of an odd penetration is given to the higher-ID
//     entity, so the total displacement closes the gap to exactly the radius
//     sum regardless of which entity is "a".
//   - When the two are exactly coincident (distance 0) the separation axis is
//     undefined, so it is chosen deterministically from the IDs (higher ID east
//     along +X, lower ID west) rather than from anything order-dependent.
//
// Overflow safety: Radius is bounded to maxRadiusMM on ingestion and positions
// to maxWorldExtentMM, so the radius sum (<=2e5) and the scale product
// d.component*magnitude (<=2e6 * 2e5 = 4e11) both stay far below the int64
// ceiling.
func separationPush(a, b *Entity) (Vec3, Vec3) {
	rsum := a.Radius + b.Radius
	if rsum <= 0 {
		return Vec3{}, Vec3{} // point capsules have no extent to separate
	}
	d := Vec3{X: a.Pos.X - b.Pos.X, Z: a.Pos.Z - b.Pos.Z}
	dist := d.HorizontalLen()
	if dist >= rsum {
		return Vec3{}, Vec3{} // not overlapping
	}
	pen := rsum - dist
	half := pen / 2
	extra := pen - 2*half // 0 or 1, awarded to the higher-ID entity

	aMag, bMag := half, half
	if a.ID > b.ID {
		aMag += extra
	} else {
		bMag += extra
	}

	if dist == 0 {
		// Coincident: pick the axis from the IDs so the result is stable.
		if a.ID > b.ID {
			return Vec3{X: aMag}, Vec3{X: -bMag}
		}
		return Vec3{X: -aMag}, Vec3{X: bMag}
	}
	// a moves along +d, b along -d, each scaled to its own magnitude.
	return scaleHorizontal(d, aMag, dist), scaleHorizontal(d, -bMag, dist)
}

// scaleHorizontal returns the ground-plane vector d/|d| * mag in integer
// millimetres, where dist == d.HorizontalLen() (> 0) is passed in to avoid
// recomputing it. Integer division truncates toward zero — deterministically.
// A negative mag flips the direction, which is how the two sides of a pair are
// pushed opposite ways. The vertical axis is never part of a separation.
func scaleHorizontal(d Vec3, mag, dist int64) Vec3 {
	return Vec3{
		X: d.X * mag / dist,
		Z: d.Z * mag / dist,
	}
}
