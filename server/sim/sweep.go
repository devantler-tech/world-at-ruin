package sim

import "math/big"

// Swept (continuous) collision on the movement-integration path.
//
// Separation (separation.go) resolves the overlap of *post-movement* positions:
// it looks at where actors ended up this tick and pushes any overlapping pair
// apart. It is therefore blind to an actor that moves fast enough to pass
// entirely through another between two ticks — neither the actor's start nor its
// end position overlaps the other, so the overlap pass never fires. That is the
// classic discrete-collision *tunneling* gap (flagged by Codex review on #56,
// tracked as #66).
//
// The fix lives here, in Step's integration rather than in the de-overlap pass:
// before an actor is committed to its post-step position, its straight-line
// path this tick is swept against the other actors, and if that path would cross
// through one, the actor is stopped at first contact instead of teleporting out
// the far side.
//
// It is a strict no-op at every movement speed the game has today. An actor
// whose per-tick step is shorter than the chord it would have to cut through a
// capsule cannot tunnel it — it can at most enter and be caught by separation —
// so the sweep never fires for realistic walking speed, and it changes neither
// the demo movement golden nor the separation golden (asserted by
// sweep_test.go). It engages only for the high-speed movement (a dash/charge)
// that a later Phase 2 combat child will add. #66 exists to put this guard in
// place *before* that movement does, because the product law has no undo: an
// actor must never be able to skip a collision by moving quickly.
//
// Design constraints, identical to the rest of the sim:
//
//   - Integer-only and host-independent. The geometry is exact-integer. The few
//     intermediate quantities that can exceed int64 (a squared dot product, the
//     discriminant, the final interpolation) are computed with math/big, which
//     is exact integer arithmetic — never floating point — so the stop position
//     is bit-identical on every architecture, exactly as isqrt replaces
//     math.Sqrt elsewhere. math/big is stdlib, so this adds no dependency.
//   - Deterministic and order-independent. Every actor is swept against a single
//     immutable snapshot of the pre-step positions, taken before any actor
//     moves, so the clamp each mover receives is a pure function of that
//     snapshot — independent of the order actors are integrated in, and of Go
//     map iteration order (obstacles are visited in ascending EntityID order).
//   - Sweep-vs-static, then separate. An obstacle is treated as stationary at
//     its snapshot position for the sweep. The mover is thereby guaranteed not to
//     pass *through* an obstacle's snapshot capsule; any residual overlap once
//     both have actually moved is left to the deterministic separation pass. So
//     a fast actor can never tunnel another, which is the whole guarantee, and
//     the settled de-overlap behaviour is unchanged.
//   - Conservative. The stop is a lower bound on the true first contact,
//     truncated toward the start, so the actor always halts at or before the
//     capsule surface (within separationSlopMM — the same touching tolerance
//     separation itself treats as resolved), never having crossed it.

// sweptStop returns the position to which the mover id's integrated target for
// this tick is shortened so that its straight-line ground-plane path does not
// pass through any other actor's snapshot capsule. from is the mover's pre-step
// position (snap[id]); target is its bounds-clamped integrated destination; ra
// is its capsule radius; earlyOut2 is the squared per-tick displacement at or
// below which no actor present can tunnel (see Step). It returns target
// unchanged whenever no crossing would occur — which is the case at every speed
// the game has today.
func (w *World) sweptStop(id EntityID, snap map[EntityID]Vec3, target Vec3, ra, earlyOut2 int64) Vec3 {
	from := snap[id]
	dx := target.X - from.X
	dz := target.Z - from.Z
	if dx == 0 && dz == 0 {
		return target // no ground-plane movement — nothing horizontal to sweep
	}
	if dx*dx+dz*dz <= earlyOut2 {
		return target // step too short to tunnel any capsule present (the case today)
	}

	// A genuine fast mover. Sweep its path against every other actor's snapshot
	// capsule, in ascending-ID order, and keep the earliest contact. Scanning all
	// other actors is O(n); it runs only for a mover whose step exceeds earlyOut2,
	// of which there are none until a high-speed ability lands, so it is off the
	// hot path today. Grid-accelerating this query for a zone full of
	// simultaneously-dashing actors is a later refinement, tied to the separation
	// broad phase (#64); it is deliberately not done here.
	var best *big.Rat // earliest contact fraction in [0,1]; nil ⇒ no contact
	for _, oid := range w.order {
		if oid == id {
			continue
		}
		t := firstContactFrac(from, target, ra, snap[oid], w.ents[oid].Radius)
		if t == nil {
			continue
		}
		if best == nil || t.Cmp(best) < 0 {
			best = t
		}
	}
	if best == nil {
		return target
	}

	// Stop at from + best·(target-from) on the ground plane, truncating the
	// displacement toward the start so the actor halts on the outside of the
	// capsule. Vertical motion is unaffected: capsules are vertical, so overlap —
	// and therefore tunneling — is purely a ground-plane question.
	return Vec3{
		X: from.X + fracMulTrunc(best, dx),
		Y: target.Y,
		Z: from.Z + fracMulTrunc(best, dz),
	}
}

// firstContactFrac returns the fraction t ∈ [0,1] of the ground-plane segment
// from→target at which a mover of radius ra first makes meaningful contact with
// a stationary capsule (centre, rb), or nil if the segment does not pass through
// that capsule (so the mover should move freely to target).
//
// "Meaningful contact" is defined against the effective radius rEff = ra+rb −
// separationSlopMM: the depth at which separation itself would act. A path that
// only grazes to within the slop is not a collision separation would resolve, so
// it is not a tunnel to prevent — and treating it as one would perturb the
// settled goldens. The mover is caught only when its path enters the rEff disk
// having started and ended outside it — i.e. it would cross clean through — and
// is then stopped at the rEff surface (penetration ≈ slop, which separation
// treats as already resolved).
func firstContactFrac(from, target Vec3, ra int64, center Vec3, rb int64) *big.Rat {
	rEff := ra + rb - separationSlopMM
	if rEff <= 0 {
		return nil // combined radius within the slop — no overlap separation would ever resolve
	}
	rEff2 := rEff * rEff

	dx := target.X - from.X
	dz := target.Z - from.Z
	a0 := dx*dx + dz*dz // path length² on the ground plane
	if a0 == 0 {
		return nil // no ground-plane movement — no path to sweep (also guards the a0 divisor below)
	}

	// f = from − centre. The path is P(t) = from + t·(dx,dz), t ∈ [0,1].
	fx := from.X - center.X
	fz := from.Z - center.Z
	c0 := fx*fx + fz*fz // |P(0) − centre|²
	if c0 <= rEff2 {
		return nil // already within contact distance at the start — separation's job, not a tunnel
	}
	tx := target.X - center.X
	tz := target.Z - center.Z
	e0 := tx*tx + tz*tz // |P(1) − centre|²
	if e0 <= rEff2 {
		return nil // ends within contact distance — a plain approach, resolved by separation
	}

	// The squared distance |P(t) − centre|² = a0·t² + 2·fd·t + c0 is minimised at
	// t* = −fd/a0. A crossing with both endpoints outside requires the closest
	// approach to fall strictly inside the segment, i.e. 0 < t* < 1 ⟺ −a0 < fd < 0.
	fd := fx*dx + fz*dz // f·d
	if fd >= 0 {
		return nil // moving away from the centre — closest approach is the (outside) start
	}
	if fd <= -a0 {
		return nil // closest approach at/after the end — nearest point in [0,1] is the (outside) end
	}

	// Contact solves a0·t² + 2·fd·t + (c0 − rEff²) = 0, whose entry (smaller) root
	// is t = (−fd − √(fd² − a0·(c0 − rEff²))) / a0. Both fd² and a0·(c0−rEff²) can
	// exceed int64, so the discriminant is formed with exact big-integer
	// arithmetic (never float — determinism).
	cc := c0 - rEff2 // > 0
	fdBig := big.NewInt(fd)
	disc := new(big.Int).Mul(fdBig, fdBig)                           // fd²
	disc.Sub(disc, new(big.Int).Mul(big.NewInt(a0), big.NewInt(cc))) // fd² − a0·cc
	if disc.Sign() <= 0 {
		return nil // the path stays outside the rEff disk (tangent or miss) — no crossing
	}

	// Use ⌈√disc⌉ so the numerator −fd−⌈√disc⌉ is no larger than the true
	// −fd−√disc: the resulting fraction is a lower bound on the true entry, so the
	// mover stops at or before first contact — on the outside.
	s := new(big.Int).Sqrt(disc) // ⌊√disc⌋
	if new(big.Int).Mul(s, s).Cmp(disc) != 0 {
		s.Add(s, big.NewInt(1)) // ⌈√disc⌉
	}
	sc := s.Int64() // fits int64: disc ≤ ~6.4e25 ⇒ √disc ≤ ~8e12
	num := -fd - sc // −fd > 0 (fd < 0)
	if num <= 0 {
		// The conservative entry rounds to at/behind the start: the mover begins
		// essentially at the contact surface, so it is blocked outright this tick.
		// Stopping at the start is safe (definitely outside) — return t = 0.
		return big.NewRat(0, 1)
	}
	return big.NewRat(num, a0) // a0 > 0
}

// fracMulTrunc returns ⌊r·delta⌋ truncated toward zero, as an int64. r is a
// contact fraction in [0,1] and delta a ground-plane displacement bounded to
// ±2·maxWorldExtentMM, so the product fits an int64 after the division; the
// intermediate numerator can exceed int64, so the multiply/divide is done with
// math/big. Truncating toward zero shortens the displacement, which keeps the
// stopped position on the start side of true contact.
func fracMulTrunc(r *big.Rat, delta int64) int64 {
	n := new(big.Int).Mul(r.Num(), big.NewInt(delta))
	n.Quo(n, r.Denom()) // toward zero
	return n.Int64()
}

// minPositiveRadius returns the smallest strictly-positive capsule radius in the
// world, or 0 if no actor has extent. It is a lower bound on the combined radius
// of any pair that can collide (a pair's r_a+r_b is at least the smaller of the
// two, and at least this when one side is a point capsule), which is what the
// swept early-out is sized against.
func minPositiveRadius(w *World) int64 {
	var m int64
	for _, id := range w.order {
		if r := w.ents[id].Radius; r > 0 && (m == 0 || r < m) {
			m = r
		}
	}
	return m
}
