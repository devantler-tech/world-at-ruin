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
//     pushed apart until its penetration is within separationSlopMM. Capsule
//     kinematics only.
//   - Order-independent and deterministic. Pairs are resolved in ascending-ID
//     order every pass, and entities are stored and iterated by ID, so the
//     result never depends on entity insertion order or Go map iteration order
//     — the determinism law's requirement — even though each resolve is applied
//     immediately (Gauss-Seidel), which converges faster than a simultaneous
//     pass and lets a blocked push transfer to the movable side within the pair.
//
// Separation is a *convergent relaxation*, not a hard single-tick guarantee for
// arbitrary crowd density. An isolated pair (including a pair against a wall) is
// resolved within one tick; a dense pile-up — many actors packed inside one
// body's radius — spreads out over a few ticks, because bounded per-tick effort
// is the price of never stalling the single authoritative loop. Fully unpacking
// an arbitrarily dense crowd in one tick would need an unbounded number of
// passes, which is neither affordable nor necessary: a transient overlap in a
// pile-up is self-correcting and imperceptible.

// separationIterations bounds the relaxation passes run per tick, keeping the
// step's cost — and its result — deterministic and independent of how bad a
// pile-up is. A pass that moves nothing ends the loop early, so the common case
// (nothing overlapping) costs one pair scan and no writes, which is what keeps
// separation a true no-op when actors are already apart. Eight passes clears a
// moderate crowd within one tick and a dense one within a few (see the crowd
// convergence test).
const separationIterations = 8

// separationSlopMM is the penetration tolerance: a pair overlapping by no more
// than this is treated as resolved and left alone. A small positive slop is
// standard in positional solvers (e.g. Box2D's b2_linearSlop ≈ 5 mm) — it stops
// an integer solver from chasing the last sub-perceptible millimetre of a
// diagonal or multi-contact overlap forever (integer scaling truncates each
// push slightly short, so a packed equilibrium otherwise settles a few mm
// overlapped and never quite closes). At 8 mm it is under 1% of a typical actor
// diameter — invisible in play, and a bounded, named quantity rather than an
// emergent rounding artefact.
const separationSlopMM = 8

// separate resolves capsule overlap. Each pass walks the actors in ascending-ID
// order and pushes overlapping pairs apart (see resolvePair), applying each fix
// immediately so later pairs in the same pass see it. Because the traversal
// order is fixed by entity ID — never insertion or map order — two worlds fed
// identical inputs settle to identical state, which the determinism law requires.
//
// Rather than scan all n·(n-1)/2 pairs each pass, it consults a spatial-hash
// broad phase (broadphase.go): for each actor a, only the actors in a's 3×3 cell
// neighbourhood with a greater ID are offered to resolvePair, in ascending-ID
// order. The cell is sized so any pair overlapping when the grid is built is
// always a candidate — the pruned pairs are exactly the ones resolvePair would
// leave untouched — so separation stays deterministic, insertion-order
// independent and convergent at ~O(n) instead of O(n²) cost for a realistic
// actor density (see broadphase.go for what is and is not preserved versus a
// naive full scan).
func (w *World) separate() {
	n := len(w.order)
	if n < 2 {
		return
	}
	cell := separationCellMM(w)
	var candidates []EntityID
	for range separationIterations {
		moved := false
		grid := newSepGrid(w, cell)
		for i := range n {
			a := w.ents[w.order[i]]
			candidates = grid.neighbours(a, candidates)
			for _, bID := range candidates {
				if w.resolvePair(a, w.ents[bID]) {
					moved = true
				}
			}
		}
		if !moved {
			return
		}
	}
}

// resolvePair pushes a and b apart so their capsules no longer overlap, and
// reports whether it moved anything. It splits the penetration half to each
// side, but — and this is the invariant that ordinary wall collisions depend on
// — when one side's push is blocked by the navmesh bounds, the blocked part is
// transferred to the other side, so a capsule pinned against a zone edge does
// not leave its partner overlapping it. Overlap is a ground-plane (XZ) question
// (capsules are vertical), so the vertical axis is never moved.
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
func (w *World) resolvePair(a, b *Entity) bool {
	rsum := a.Radius + b.Radius
	if rsum <= 0 {
		return false // point capsules have no extent to separate
	}
	d := Vec3{X: a.Pos.X - b.Pos.X, Z: a.Pos.Z - b.Pos.Z}
	dist := d.HorizontalLen()
	pen := rsum - dist
	if pen <= separationSlopMM {
		return false // apart, touching, or within the penetration tolerance
	}
	half := pen / 2        // floor half → the lower-ID side
	ceilHalf := pen - half // ceil half (the odd mm) → the higher-ID side

	// ua, ub are the intended (pre-clamp) moves: a along +d, b along -d.
	var ua, ub Vec3
	if dist == 0 {
		// Coincident: the separation axis is undefined, so choose it
		// deterministically. Prefer the roomier bounds axis — two actors
		// coincident in a thin corridor must separate along its long axis, not
		// into the near walls (picking the cramped axis would leave them stuck
		// even with the blocked-push transfer). Direction is set by ID (higher
		// ID positive, lower ID negative — opposite ways) so the result never
		// depends on iteration order; the transfer handles any remaining wall on
		// the chosen axis.
		aMag, bMag := -half, ceilHalf // a is the lower ID (ascending pairs)
		if a.ID > b.ID {
			aMag, bMag = ceilHalf, -half
		}
		if w.bounds.Max.X-w.bounds.Min.X >= w.bounds.Max.Z-w.bounds.Min.Z {
			ua, ub = Vec3{X: aMag}, Vec3{X: bMag}
		} else {
			ua, ub = Vec3{Z: aMag}, Vec3{Z: bMag}
		}
	} else {
		aMag, bMag := half, ceilHalf
		if a.ID > b.ID {
			aMag, bMag = ceilHalf, half
		}
		ua = scaleHorizontal(d, aMag, dist)
		ub = scaleHorizontal(d, -bMag, dist)
	}

	// Apply with bounds clamping, transferring any push a bound blocks to the
	// other side so the pair still fully separates against a wall.
	wantA := a.Pos.Add(ua)
	newA := w.bounds.clamp(wantA)
	blockedA := wantA.Sub(newA) // the part of a's move the bound rejected

	// b takes its own push plus whatever a could not move (subtracting a's
	// blocked +d displacement pushes b further along -d).
	wantB := b.Pos.Add(ub).Sub(blockedA)
	newB := w.bounds.clamp(wantB)
	blockedB := wantB.Sub(newB)

	// If b is also blocked (both pinned, e.g. a corner narrower than the pair),
	// hand the remainder back to a. Anything still unresolved is a genuinely
	// impossible placement and is left for the next pass / tick.
	if blockedB != (Vec3{}) {
		newA = w.bounds.clamp(newA.Sub(blockedB))
	}

	a.Pos, b.Pos = newA, newB
	return true
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
