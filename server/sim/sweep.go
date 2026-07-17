package sim

import "math/big"

// Swept (continuous) collision on the movement-integration path.
//
// Separation (separation.go) resolves the overlap of *post-movement* positions:
// it looks at where actors ended up this tick and pushes any overlapping pair
// apart. It is therefore blind to an actor that moves fast enough to pass
// entirely through another between two ticks — neither its start nor its end
// position overlaps the other, so the overlap pass never fires — and worse,
// separation can *complete* such a crossing: an actor that stepped past another's
// centre in one tick is pushed further along its travel, out the far side,
// rather than back. That is the classic discrete-collision *tunneling* gap
// (flagged by Codex review on #56, tracked as #66).
//
// The fix is a swept pass in Step's integration: a mover is stopped at the first
// moment its capsule would touch another while the two are approaching, instead
// of being committed to a destination it could only reach by passing through.
//
// Feature-flag-first (World.SweptCollision, default off). Stopping an actor at
// first contact is a genuine change to how contact resolves — stop-at-contact
// rather than overlap-then-separate — so it ships behind a default-off flag and
// is validated in both states (sweep_test.go). With the flag off the movement
// pass is byte-identical to the original, so every settled golden is unchanged.
// No actor in the game moves fast enough to tunnel today (#66 exists to arm the
// guard *before* the high-speed movement — a dash/charge — that a later Phase 2
// combat child adds); that child flips the flag on after validating it, the
// standard decouple-deploy-from-release step. The product law has no undo, so
// the guard must exist before the movement that needs it.
//
// Design constraints, identical to the rest of the sim:
//
//   - Integer-only and host-independent. The geometry is exact-integer; the few
//     intermediate quantities that can exceed int64 (the discriminant, the final
//     interpolation) use math/big, which is exact integer arithmetic — never
//     floating point — so the result is bit-identical on every architecture,
//     exactly as isqrt replaces math.Sqrt elsewhere. math/big is stdlib, so this
//     adds no dependency.
//   - Relative motion, so it is correct when BOTH actors move. Each mover is
//     tested against the other actors' actual travel this tick (start→target),
//     not a static snapshot — two actors swapping places at speed are caught and
//     meet at contact rather than passing through each other.
//   - Deterministic and order-independent. Every clamp is a pure function of one
//     immutable snapshot of the whole field's start and target positions, taken
//     before any actor is committed, and obstacles are visited in ascending
//     EntityID order.
//   - Never-cross, residual to separation. A mover is stopped at or before first
//     contact (a conservative lower bound on the contact time, truncated toward
//     the start), so it never passes through another; any small residual overlap
//     once every actor has been placed is left to the deterministic separation
//     pass, exactly as before.

// integrateSwept is the movement pass used when World.SweptCollision is on. It
// integrates every actor's clamped intent into a target, then places each actor
// at the first point along its path where it would contact another — so a fast
// actor stops at a wall of bodies instead of tunneling through them.
func (w *World) integrateSwept() {
	n := len(w.order)
	// Snapshot every actor's start and integrated target up front. Each mover's
	// clamp then depends only on this immutable snapshot of the whole field's
	// motion — never on the order actors are placed in, and never on a position
	// already mutated this tick.
	starts := make(map[EntityID]Vec3, n)
	targets := make(map[EntityID]Vec3, n)
	for _, id := range w.order {
		e := w.ents[id]
		starts[id] = e.Pos
		v := clampSpeed(e.Intent, e.MaxSpeed)
		// mm/s / (ticks/s) = mm/tick.
		disp := Vec3{X: v.X / TickHz, Y: v.Y / TickHz, Z: v.Z / TickHz}
		targets[id] = w.bounds.clamp(e.Pos.Add(disp))
	}
	for _, id := range w.order {
		w.ents[id].Pos = w.sweptClamp(id, starts, targets)
	}
}

// sweptClamp returns where mover id should be placed this tick: its integrated
// target, shortened along its own path to the earliest contact with any other
// actor's swept capsule. It scans the other actors in ascending-ID order and
// keeps the earliest contact.
//
// The scan is O(n) per mover. That is acceptable while swept collision is armed
// only for the rare high-speed mover; grid-accelerating it (via the separation
// broad phase, broadphase.go) for a zone full of simultaneously-dashing actors
// is a later refinement tied to #64, deliberately not done here.
func (w *World) sweptClamp(id EntityID, starts, targets map[EntityID]Vec3) Vec3 {
	from, to := starts[id], targets[id]
	ri := w.ents[id].Radius
	var best *big.Rat // earliest contact fraction in [0,1]; nil ⇒ no contact
	for _, oid := range w.order {
		if oid == id {
			continue
		}
		t := firstContactFrac(from, to, ri, starts[oid], targets[oid], w.ents[oid].Radius)
		if t == nil {
			continue
		}
		if best == nil || t.Cmp(best) < 0 {
			best = t
		}
	}
	if best == nil {
		return to
	}
	// Place the mover at from + best·(to−from) on the ground plane, truncating the
	// displacement toward the start so it halts at or before contact — never
	// having crossed. Vertical motion is unaffected: capsules are vertical, so
	// contact is a ground-plane question.
	return Vec3{
		X: from.X + fracMulTrunc(best, to.X-from.X),
		Y: to.Y,
		Z: from.Z + fracMulTrunc(best, to.Z-from.Z),
	}
}

// firstContactFrac returns the fraction t ∈ [0,1] of mover i's path (iFrom→iTo,
// radius ri) at which i first makes *closing* contact with actor j (jFrom→jTo,
// radius rj) — the earliest instant during the tick that the two capsules touch
// while approaching. It returns nil when they do not touch while approaching
// this tick, so i may move freely.
//
// It works in the pair's relative frame, so it is correct when both actors move:
// with A = i−j at the tick's start and B their relative displacement over the
// tick, the squared gap |A + t·B|² is a parabola in t, and contact is where it
// meets rsum². The smaller (entry) root is always the closing one. An actor that
// begins already overlapping (|A| ≤ rsum) is allowed to move apart but not to
// close further — otherwise it is delegated to separation, as before.
func firstContactFrac(iFrom, iTo Vec3, ri int64, jFrom, jTo Vec3, rj int64) *big.Rat {
	rsum := ri + rj
	if rsum <= 0 {
		return nil // no combined extent — nothing to collide
	}
	// A = relative position at t=0 (i − j); B = relative displacement over the tick.
	ax := iFrom.X - jFrom.X
	az := iFrom.Z - jFrom.Z
	bx := (iTo.X - iFrom.X) - (jTo.X - jFrom.X)
	bz := (iTo.Z - iFrom.Z) - (jTo.Z - jFrom.Z)
	a := bx*bx + bz*bz             // |B|² — relative speed², squared mm per tick
	ab := ax*bx + az*bz            // A·B — negative iff the pair is closing at t=0
	c := ax*ax + az*az - rsum*rsum // |A|² − rsum²

	if c <= 0 {
		// Already in contact at the tick's start. Let it move apart (or tangent);
		// block only a move that closes further, which would drive it through.
		if ab >= 0 {
			return nil
		}
		return big.NewRat(0, 1) // closing while overlapped ⇒ hold position this tick
	}
	if a == 0 {
		return nil // no relative motion ⇒ gap is constant ⇒ no new contact
	}
	if ab >= 0 {
		return nil // separating (or tangent) at the start ⇒ closest approach is at t≤0
	}

	// |A + t·B|² − rsum² = a·t² + 2·ab·t + c. Contact is a root of that quadratic;
	// the discriminant/4 is ab² − a·c (which can exceed int64, so use big).
	discQ := new(big.Int).Sub(
		new(big.Int).Mul(big.NewInt(ab), big.NewInt(ab)),
		new(big.Int).Mul(big.NewInt(a), big.NewInt(c)),
	)
	if discQ.Sign() <= 0 {
		return nil // the relative path stays outside rsum (tangent or miss)
	}
	// Contact falls within THIS tick only if the parabola reaches ≤ 0 for some
	// t ∈ (0,1]: either the endpoint is in contact (q(1) ≤ 0) or the closest
	// approach is before t=1 (t* = −ab/a < 1 ⇔ a+ab > 0).
	q1 := a + 2*ab + c
	if q1 > 0 && a+ab <= 0 {
		return nil // closest approach is at/after t=1 and the endpoint is clear
	}

	// Entry (closing) root: t = (−ab − √discQ)/a. Using ⌈√discQ⌉ makes the
	// numerator no larger than the true one, so t is a lower bound on true
	// contact — the mover stops at or before it, on the near side.
	num := -ab - ceilSqrt(discQ) // −ab > 0 (ab < 0 here)
	if num <= 0 {
		return big.NewRat(0, 1) // contact rounds to at/behind the start ⇒ hold
	}
	if num > a {
		num = a // clamp the conservative rounding to t ≤ 1
	}
	return big.NewRat(num, a)
}

// ceilSqrt returns ⌈√n⌉ for n ≥ 0 as an int64, using math/big's exact integer
// square root (⌊√n⌋) and rounding up when n is not a perfect square. It is exact
// and host-independent — the discriminant it takes is bounded well within an
// int64 square root, so the result fits an int64.
func ceilSqrt(n *big.Int) int64 {
	s := new(big.Int).Sqrt(n) // ⌊√n⌋
	if new(big.Int).Mul(s, s).Cmp(n) != 0 {
		s.Add(s, big.NewInt(1))
	}
	return s.Int64()
}

// fracMulTrunc returns ⌊r·delta⌋ truncated toward zero, as an int64. r is a
// contact fraction in [0,1] and delta a ground-plane displacement bounded to
// ±2·maxWorldExtentMM, so the quotient fits an int64; the intermediate numerator
// can exceed int64, so the multiply/divide uses math/big. Truncating toward zero
// shortens the displacement, keeping the placed position on the start side of
// true contact.
func fracMulTrunc(r *big.Rat, delta int64) int64 {
	n := new(big.Int).Mul(r.Num(), big.NewInt(delta))
	n.Quo(n, r.Denom()) // toward zero
	return n.Int64()
}
