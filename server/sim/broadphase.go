package sim

// Broad phase for capsule separation: a uniform spatial hash over the ground
// plane (XZ) that turns the per-tick de-overlap from O(n²) into ~O(n) for
// realistically-distributed actors — without changing the deterministic result.
//
// Why a broad phase at all. separate() (separation.go) is a convergent
// relaxation: up to separationIterations passes per tick, and each pass must
// find every overlapping pair. The straightforward way — scan all n·(n-1)/2
// pairs each pass — is fine at skeleton scale (tens of actors) but is quadratic:
// a dense zone of thousands of capsule actors would spend a large fraction of
// the single authoritative tick budget in that scan (flagged by Codex on #56).
// A spatial hash offers only the pairs that can actually touch, so the narrow
// phase (resolvePair) runs on ~O(n) candidate pairs for a realistic density.
//
// The load-bearing safety invariant — it never prunes a pair that must resolve.
// Two capsules overlap only when their ground-plane centres are closer than
// r_a+r_b, which is at most 2·maxRadius. Sizing a cell to exactly that maximum
// interaction distance means any overlapping pair's centres fall in the same
// cell or an immediately adjacent one, so at the moment the grid is built every
// genuinely-overlapping pair is among the 3×3-neighbourhood candidates. The
// pairs the hash prunes are strictly farther apart than any capsule-radius sum,
// so resolvePair would have returned false (no move) for them anyway. The grid
// is rebuilt from live positions at the start of every pass, so this holds pass
// after pass. (Verified structurally in broadphase_test.go: no overlapping pair
// is ever pruned.)
//
// What it preserves — every guarantee the sim actually promises. The surviving
// candidates are handed to resolvePair in ascending-EntityID order — each pair
// resolved once, on the lower-ID member's turn, higher-ID partners ascending —
// and the whole computation is a pure function of the actors' positions, IDs and
// radii: integer-only floor-division cell keys (host-independent) and candidates
// merged from already-ascending buckets, never taken in Go map-iteration order.
// So separation stays deterministic (same inputs → same output on every host),
// insertion-order independent, convergent, and it holds the committed golden
// clusters bit-for-bit (separationGoldenHash, demoGoldenHash).
//
// What it deliberately does not promise — a byte-match with the naive O(n²)
// scan for an arbitrarily dense pile. Because a pass moves actors immediately
// (Gauss-Seidel), a chained push can carry a third actor across a cell boundary
// into a pair that was more than one cell apart when the pass began; the full
// scan, which re-tests every pair against live positions, would catch that pair
// in the same pass, whereas the grid picks it up on the next pass's fresh grid.
// A very dense crowd therefore settles to a different — but equally valid,
// equally deterministic — non-overlapping arrangement, over the same handful of
// ticks separate() already documents for pile-ups. That micro-arrangement was
// never a product guarantee (the server is the sole authority on separation, so
// there is nothing to desync against); reproducibility and host-independence,
// which are the guarantees, are untouched.

// cellKey identifies a square ground-plane cell by its integer grid coordinates.
type cellKey struct{ x, z int64 }

// sepGrid buckets entities into square cells of width cell (mm). Each bucket
// lists its members in ascending EntityID, because it is built by walking the
// world's ascending-ID order. cellOf records the cell each entity was placed in
// at build time, so a neighbourhood query keys off an actor's *snapshot* cell
// even after separation has moved it this pass (see neighbours).
type sepGrid struct {
	cell    int64
	buckets map[cellKey][]EntityID
	cellOf  map[EntityID]cellKey
}

// newSepGrid builds the spatial hash for the world's current positions with the
// given cell width. It walks w.order (ascending EntityID), so every bucket ends
// up ascending, which the k-way merge in neighbours relies on.
func newSepGrid(w *World, cell int64) *sepGrid {
	// Pre-size for one bucket per actor (the sparse common case, where every
	// actor sits alone in its cell) so the map does not grow-and-rehash while
	// filling. A persistent per-World scratch grid, reused across ticks to drop
	// the per-tick O(n) allocation entirely, is a natural follow-up if profiling
	// a real dense zone shows GC pressure — the algorithmic win here is the
	// O(n²)→~O(n) pair count, not allocation tuning.
	g := &sepGrid{
		cell:    cell,
		buckets: make(map[cellKey][]EntityID, len(w.order)),
		cellOf:  make(map[EntityID]cellKey, len(w.order)),
	}
	for _, id := range w.order {
		p := w.ents[id].Pos
		k := cellKey{x: floorDiv(p.X, cell), z: floorDiv(p.Z, cell)}
		g.buckets[k] = append(g.buckets[k], id)
		g.cellOf[id] = k
	}
	return g
}

// neighbours returns, into buf (reused across calls), the IDs of the entities in
// a's 3×3 cell neighbourhood whose ID is greater than a's — the separation
// candidates a is responsible for this pass — in ascending EntityID order. It
// merges the (already-ascending) neighbourhood buckets, so the cost is linear in
// the candidate count with a fixed nine-way fan-in: no per-entity sort, so even
// the pathological all-in-one-cell case stays O(n²), never O(n² log n).
//
// It keys off a's *snapshot* cell (cellOf), not its current Pos. That matters
// because a Gauss-Seidel pass moves actors as it goes: if a was pushed across a
// cell boundary as an earlier pair's partner before its own turn, its live Pos
// would query the wrong cell against buckets that still hold everyone at their
// build-time cells — and could miss a partner that overlapped a at build time
// and still overlaps it now. Querying the snapshot cell keeps the lookup
// consistent with the buckets, so every pair overlapping when the grid was built
// is offered (the no-prune invariant), regardless of intra-pass movement.
func (g *sepGrid) neighbours(a *Entity, buf []EntityID) []EntityID {
	buf = buf[:0]
	k := g.cellOf[a.ID]
	kx, kz := k.x, k.z

	// Gather the up-to-nine non-empty neighbourhood buckets, each advanced past
	// IDs ≤ a's (buckets are ascending, so a prefix skip suffices — this drops a
	// itself and every lower-ID member, whose turn already covered the pair).
	var lists [9][]EntityID
	n := 0
	for dx := int64(-1); dx <= 1; dx++ {
		for dz := int64(-1); dz <= 1; dz++ {
			b := g.buckets[cellKey{kx + dx, kz + dz}]
			p := 0
			for p < len(b) && b[p] <= a.ID {
				p++
			}
			if p < len(b) {
				lists[n] = b[p:]
				n++
			}
		}
	}

	// K-way merge of the ascending lists (n ≤ 9): repeatedly take the smallest
	// head. IDs are globally unique, so no de-duplication is needed.
	for {
		best := -1
		var bestID EntityID
		for i := 0; i < n; i++ {
			if len(lists[i]) == 0 {
				continue
			}
			if best == -1 || lists[i][0] < bestID {
				best, bestID = i, lists[i][0]
			}
		}
		if best == -1 {
			break
		}
		buf = append(buf, bestID)
		lists[best] = lists[best][1:]
	}
	return buf
}

// separationCellMM is the broad-phase cell width: twice the largest capsule
// radius present, i.e. the largest ground-plane centre distance at which any two
// actors can overlap. Sizing to the real maximum radius (not the 100 m
// maxRadiusMM ingestion cap) keeps cells tight so the pruning is effective,
// while still guaranteeing every overlapping pair shares a cell or an adjacent
// one. A world of only point capsules (max radius 0) has no separation to do,
// but the width is floored at 1 mm so cell keys stay well-defined (floorDiv by
// zero is undefined, and a zero-radius world never enters resolvePair's moving
// branch anyway).
func separationCellMM(w *World) int64 {
	var maxR int64
	for _, id := range w.order {
		if r := w.ents[id].Radius; r > maxR {
			maxR = r
		}
	}
	if cell := 2 * maxR; cell >= 1 {
		return cell
	}
	return 1
}

// floorDiv returns ⌊a / cell⌋ for cell > 0. Go's integer division truncates
// toward zero, which would fold the cell just below the origin (-cell+1 .. -1)
// into cell 0 and break the uniform tiling the neighbourhood argument depends
// on; flooring keeps every cell the same width across the origin.
func floorDiv(a, cell int64) int64 {
	q := a / cell
	if a%cell != 0 && a < 0 {
		q--
	}
	return q
}
