// Shared procedural fields for every surface that renders as Ashfall Reach
// ground. The terrain and the cave-foot transition both call these functions;
// changing the ground's drift, grain, plate partition, or named substances can
// therefore not leave the contact seam wearing an older approximation.

float terrain_hash3(vec3 p) {
	return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

float terrain_value_noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	vec3 u = f * f * (3.0 - 2.0 * f);
	float n000 = terrain_hash3(i);
	float n100 = terrain_hash3(i + vec3(1.0, 0.0, 0.0));
	float n010 = terrain_hash3(i + vec3(0.0, 1.0, 0.0));
	float n110 = terrain_hash3(i + vec3(1.0, 1.0, 0.0));
	float n001 = terrain_hash3(i + vec3(0.0, 0.0, 1.0));
	float n101 = terrain_hash3(i + vec3(1.0, 0.0, 1.0));
	float n011 = terrain_hash3(i + vec3(0.0, 1.0, 1.0));
	float n111 = terrain_hash3(i + vec3(1.0, 1.0, 1.0));
	return mix(
		mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
		mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}

float terrain_fbm(vec3 p) {
	float amp = 0.5;
	float sum = 0.0;
	for (int i = 0; i < 3; i++) {
		sum += amp * terrain_value_noise(p);
		p *= 2.03;
		amp *= 0.5;
	}
	return sum;
}

float terrain_ground_noise(vec2 xz, float scale) {
	return terrain_fbm(vec3(xz.x, 0.0, xz.y) * scale);
}

// The jittered-grid partition. `id` is the owning cell, `f1`/`f2` the two
// nearest centre distances, and `c1`/`c2` the centres those are measured to.
//
// The centres are reported because the crack field's gradient is then available
// in closed form: f1 = |uv - c1| and f2 = |uv - c2| are plain distances, so
//
//     grad(f2 - f1) = normalize(uv - c2) - normalize(uv - c1)
//
// exactly, with no screen derivative anywhere in it. A caller differencing the
// crack field with dFdx/dFdy instead is sampling a step whose width can be far
// under one pixel, and that is the aliasing rather than a measurement of it.
// The search already computes both centres, so returning them costs two
// out-parameters rather than another partition evaluation.
//
// `id2` is the CELL those second-nearest values belong to — the plate this
// fragment would have belonged to had it fallen a little further across. It
// costs nothing extra for the same reason `c2` does (the search already knows
// it), and it is what lets a caller average the substance step across the
// boundary rather than taking the owning cell's value outright.
//
// `f3`/`c3`/`id3` are the THIRD-nearest, and they exist because `id2` alone is
// not a continuous choice of neighbour. At a triple junction the owning cell
// stays the same while the second- and third-nearest swap across their bisector,
// so a caller blending toward `id2` sees its blend target change identity
// abruptly while the weight is still near a half (#499). Carrying the third
// candidate is what lets that swap be made harmless; see
// `terrain_plate_blend_weights`. It costs three more out-parameters and no
// additional distance evaluation — the partition search already visits every
// supported candidate.
//
// `f4` is the FOURTH-nearest distance. No fourth identity is carried: its only
// job is to say when the fixed three-candidate answer has reached its own tail.
// At `f3 == f4`, the third label can swap with an uncarried fourth while still
// holding coverage. Callers use that distance to fold the symmetric whole
// search window in exactly there (#573).
void terrain_plates(
		vec2 uv, out vec2 id, out float f1, out float f2,
		out vec2 c1, out vec2 c2, out vec2 id2,
		out float f3, out vec2 c3, out vec2 id3, out float f4) {
	vec2 base = floor(uv);
	f1 = 1000.0;
	f2 = 1000.0;
	f3 = 1000.0;
	f4 = 1000.0;
	id = base;
	c1 = base;
	c2 = base;
	c3 = base;
	id2 = base;
	id3 = base;
	for (int j = -2; j <= 2; j++) {
		for (int i = -2; i <= 2; i++) {
			vec2 cell = base + vec2(float(i), float(j));
			vec2 jitter = vec2(
				terrain_hash3(vec3(cell, 0.0)),
				terrain_hash3(vec3(cell, 7.0)));
			vec2 centre = cell + 0.15 + 0.7 * jitter;
			float d = length(uv - centre);
			if (d < f1) {
				f4 = f3;
				f3 = f2;
				c3 = c2;
				id3 = id2;
				f2 = f1;
				c2 = c1;
				id2 = id;
				f1 = d;
				c1 = centre;
				id = cell;
			} else if (d < f2) {
				f4 = f3;
				f3 = f2;
				c3 = c2;
				id3 = id2;
				f2 = d;
				c2 = centre;
				id2 = cell;
			} else if (d < f3) {
				f4 = f3;
				f3 = d;
				c3 = centre;
				id3 = cell;
			} else if (d < f4) {
				f4 = d;
			}
		}
	}
}

// How a fragment's coverage divides between the three nearest plates, as
// (owning, second, third). Sums to 1.0.
//
// `terrain_plate_edge_blend` decides HOW MUCH of a fragment belongs to a
// neighbouring plate. It does not decide WHICH one, and taking `id2` outright is
// only exact away from a triple junction. At one — where the owning cell stays
// the same while the second- and third-nearest swap across their bisector —
// `id2` changes identity discontinuously while that weight is still near a half,
// so the blend target jumps by the whole contrast between two substances. That
// is a fresh zero-width step inside the very region the averaging exists to
// remove (#499), and the averaging cannot filter it because it is a step in
// WHICH value is being blended, not in how much.
//
// The answer is a weighting that is SYMMETRIC in the candidates, because a
// discontinuity that lives in an identity swap is removed by symmetry or not at
// all: if two candidates carry equal weight wherever they are equidistant, then
// exchanging their labels does not move the blended value, exactly and at every
// footprint. Two swaps have to be covered, and covering only one is the trap
// this function was rewritten around —
//
//   f2 == f3, the second/third swap. This is the one #499 names.
//   f1 == f2, the owner swap. This one runs the whole length of every ordinary
//     plate boundary, and `terrain_plate_edge_blend` already handles it alone
//     (it returns exactly 0.5 there, so the two cells trade equal shares). But
//     next to a junction the third candidate carries weight too, and a rule that
//     hands the owner a fixed `1 - w` while the second gets `w * something`
//     stops being symmetric under it — the owner's share jumps as the label
//     moves. Measured on the probe in `plate_junction_test`, splitting only the
//     neighbour's half left exactly half the original step behind (0.306 down to
//     0.172, and flat under refinement — a jump, not a gradient).
//
// So blend two answers by how close the fragment is to a junction:
//
//   P — the pairwise answer, `(1 - w, w, 0)`. Exact wherever the third plate is
//       further away than the footprint, which is almost everywhere.
//   S — the symmetric coverage answer, each candidate weighted by how far it is
//       past the nearest and then normalised. Symmetric in all three by
//       construction, so it is continuous under BOTH swaps.
//   j — how much of a junction this is, from `f3 - f2`.
//
// `j` is 0.0 wherever the third plate is past the footprint, so the result there
// is P *bit-identical* to the two-cell rule and no fragment outside a junction
// changes at all. `j` is 1.0 where the second and third are equidistant, which
// is where P is discontinuous and S is not.
//
// The footprint is the caller's ISOTROPIC plate footprint, not the analytic
// separator `edge_fw` the owning boundary uses. `edge_fw` is built from `c1` and
// `c2`, and it survives the owner swap only because the separator merely negates
// there and the projection takes absolute values. Against the THIRD candidate no
// such cancellation exists, so a width built from `c1` would jump whenever the
// owner's label moved and would put a smaller copy of the defect back inside the
// fix. An orientation-free width depends on no cell identity at all. The cost is
// that the junction blend engages over a slightly conservative distance, which
// is acceptable for a correction that only ever applies where three plates meet.
vec3 terrain_plate_blend_weights(
		float f1, float f2, float f3, float pair_w, float fw) {
	float w = max(fw, 1e-6);
	vec3 pairwise = vec3(1.0 - pair_w, pair_w, 0.0);
	float g2 = 1.0 - smoothstep(0.0, w, f2 - f1);
	float g3 = 1.0 - smoothstep(0.0, w, f3 - f1);
	// The nearest candidate's own term is 1.0 by construction (f1 - f1 == 0).
	vec3 symmetric = vec3(1.0, g2, g3) / (1.0 + g2 + g3);
	float j = 1.0 - smoothstep(0.0, w, f3 - f2);
	return mix(pairwise, symmetric, j);
}

// The same two-to-many junction ramp used by
// `terrain_plate_blend_weights`. The whole-window result is composed DIRECTLY
// from the established pairwise answer with this ramp, rather than mixed over
// the already three-way result: when the fourth cell's coverage reaches zero,
// the generalized window then becomes exactly the same three-candidate
// symmetric answer before any search-window cutoff is applied.
float terrain_plate_window_junction(float f2, float f3, float fw) {
	float w = max(fw, 1e-6);
	return 1.0 - smoothstep(0.0, w, f3 - f2);
}

// One search-window cell's symmetric coverage. This depends only on the cell's
// distance excess over the nearest centre, never on its sorted position or
// identity, so exchanging any equidistant labels cannot move the answer. The
// caller normalises the weights after composing each cell independently.
float terrain_plate_window_weight(float d, float f1, float fw) {
	return 1.0 - smoothstep(0.0, max(fw, 1e-6), d - f1);
}

// Coverage is allowed to retire a junction correction only through a smooth
// ramp. Normalising candidate weights and then dropping them at an epsilon
// leaves a hard contour because the normalised answer does not approach the
// pairwise one as all remote weights vanish together.
float terrain_plate_coverage_authority(float coverage) {
	return smoothstep(0.0, 0.05, coverage);
}

// A label swap matters only while the exchanged outer candidate reaches this
// fragment. This authority is shared by the separator correction and its small
// read compensation so the latter cannot light unrelated bands where two
// uncovered remote candidates merely happen to be equidistant.
float terrain_plate_covered_junction(
		float f1, float f2, float f3, float fw) {
	float coverage = terrain_plate_window_weight(f3, f1, fw);
	return terrain_plate_window_junction(f2, f3, fw)
		* terrain_plate_coverage_authority(coverage);
}

// The permutation-free separator width over every covered cell in the same 5x5
// domain as `terrain_plates`. Pairwise weighted RMS is computable from first and
// second moments, so this remains O(n) rather than comparing all n² pairs. With
// only two covered cells it reduces to their established projected separator
// exactly; with more, no ordered "last candidate" exists to swap.
float terrain_plate_window_separator_footprint(
		vec2 uv, float f1, float plate_fw, vec2 uv_dx, vec2 uv_dy) {
	vec2 base = floor(uv);
	float total = 0.0;
	float weight_sq_total = 0.0;
	float dx_total = 0.0;
	float dx_sq_total = 0.0;
	float dy_total = 0.0;
	float dy_sq_total = 0.0;
	for (int j = -2; j <= 2; j++) {
		for (int i = -2; i <= 2; i++) {
			vec2 cell = base + vec2(float(i), float(j));
			vec2 jitter = vec2(
				terrain_hash3(vec3(cell, 0.0)),
				terrain_hash3(vec3(cell, 7.0)));
			vec2 centre = cell + 0.15 + 0.7 * jitter;
			vec2 e = uv - centre;
			float d = length(e);
			float weight = terrain_plate_window_weight(
				d, f1, plate_fw);
			vec2 n = e * inversesqrt(max(dot(e, e), 1e-12));
			float px = dot(n, uv_dx);
			float py = dot(n, uv_dy);
			total += weight;
			weight_sq_total += weight * weight;
			dx_total += weight * px;
			dx_sq_total += weight * px * px;
			dy_total += weight * py;
			dy_sq_total += weight * py * py;
		}
	}
	float pair_total = 0.5 * (
		total * total - weight_sq_total);
	float rms_dx = sqrt(max(
		(total * dx_sq_total - dx_total * dx_total)
			/ max(pair_total, 1e-12),
		0.0));
	float rms_dy = sqrt(max(
		(total * dy_sq_total - dy_total * dy_total)
			/ max(pair_total, 1e-12),
		0.0));
	return rms_dx + rms_dy;
}

// The analytic screen footprint of the nearest/second-nearest separator,
// made permutation-safe wherever more candidates enter the pixel (#589).
//
// The established two-cell answer is returned arithmetically unchanged until
// the junction ramp is non-zero. Inside that ramp, all three pair separators
// are averaged by the products of their candidates' coverage. At an identity
// swap the exchanged candidates have equal coverage, so permuting their labels
// cannot change the width. This covers both the second/third swap named by the
// issue and the owner swap an arc around the same junction also crosses. When a
// fourth candidate reaches the fragment, the same higher-order ramp already
// used by the material folds in the identity-free 5x5 window footprint. That
// removes the c3/c4 tail without carrying another ordered centre.
//
// `uv_dx` and `uv_dy` preserve the anisotropic projection used by the original
// footprint. Falling back to isotropic `plate_fw` would also hide the label
// jump, but it would misestimate diagonal and grazing-angle boundaries.
float terrain_plate_separator_footprint(
		vec2 uv, vec2 c1, vec2 c2, vec2 c3,
		float f1, float f2, float f3, float f4, float plate_fw,
		float plate_resolved, vec2 uv_dx, vec2 uv_dy) {
	vec2 e1 = uv - c1;
	vec2 e2 = uv - c2;
	vec2 n1 = e1 * inversesqrt(max(dot(e1, e1), 1e-12));
	vec2 n2 = e2 * inversesqrt(max(dot(e2, e2), 1e-12));
	vec2 g12 = n2 - n1;
	float edge12 = abs(dot(g12, uv_dx)) + abs(dot(g12, uv_dy));
	float triple_coverage_authority = terrain_plate_covered_junction(
		f1, f2, f3, plate_fw);
	if (triple_coverage_authority <= 0.0) {
		return edge12;
	}

	vec2 e3 = uv - c3;
	vec2 n3 = e3 * inversesqrt(max(dot(e3, e3), 1e-12));
	vec2 g13 = n3 - n1;
	vec2 g23 = n3 - n2;
	float edge13 = abs(dot(g13, uv_dx)) + abs(dot(g13, uv_dy));
	float edge23 = abs(dot(g23, uv_dx)) + abs(dot(g23, uv_dy));
	float g2 = terrain_plate_window_weight(f2, f1, plate_fw);
	float g3 = terrain_plate_window_weight(f3, f1, plate_fw);
	float pair_sum = g2 + g3 + g2 * g3;
	// Coverage-weighted harmonic composition keeps the narrow anisotropic
	// separator legible instead of letting a broad crossing orientation soften
	// it. The three pair terms and their weights are permutation-symmetric.
	float triple = pair_sum / (
		g2 / max(edge12, 1e-6) + g3 / max(edge13, 1e-6)
			+ g2 * g3 / max(edge23, 1e-6));
	float triple_junction = terrain_plate_window_junction(
		f2, f3, plate_fw);
	// Coverage retires the correction away from the identity boundary. At the
	// exact c2/c3 swap, however, any non-zero coverage must give the symmetric
	// triple full authority or the remaining edge12 coefficient still changes
	// identity. Normalising the covered authority against the complementary
	// identity gap satisfies both limits without activating off-junction cells.
	float triple_identity_denominator = (
		1.0 - triple_junction + triple_coverage_authority);
	float triple_identity_authority = (
		triple_coverage_authority / triple_identity_denominator);
	float higher_junction = terrain_plate_window_junction(
		f3, f4, plate_fw);
	float footprint = mix(edge12, triple, triple_identity_authority);

	// The material has already converged to its mean once this reaches zero.
	// Preserve the cheap analytic answer for downstream dead expressions, but
	// do not pay for another full 5x5 search whose result cannot be observed.
	if (plate_resolved <= 0.0) {
		return footprint;
	}
	// At the exact c3/c4 swap the carried c3 identity can change while all
	// distances remain equal. The identity-only ramp therefore removes the
	// ordered triple independently of coverage. Coverage still retires the
	// expensive window smoothly into the stable c1/c2 pair as c4 leaves reach.
	if (higher_junction <= 0.0) {
		return footprint;
	}
	float fourth_coverage = terrain_plate_window_weight(
		f4, f1, plate_fw);
	float fourth_authority = terrain_plate_coverage_authority(
		fourth_coverage);
	float higher_coverage_authority = (
		higher_junction * fourth_authority);
	if (higher_coverage_authority <= 0.0) {
		return footprint;
	}
	float higher_identity_denominator = (
		1.0 - higher_junction + higher_coverage_authority);
	float higher_identity_authority = (
		higher_coverage_authority / higher_identity_denominator);
	float window = terrain_plate_window_separator_footprint(
		uv, f1, plate_fw, uv_dx, uv_dy);
	// Factor the ordered list explicitly: edge12 is valid until c2/c3 swap,
	// the symmetric triple is valid until c3/c4 swap, and only the full window
	// is valid when both identity ramps overlap.
	float symmetric_tail = mix(
		triple, window, higher_identity_authority);
	return mix(
		edge12, symmetric_tail, triple_identity_authority);
}

// Closing the old footprint jump also removes the energy that hard step
// contributed to the measured relief read. Restore that small amount only under
// the same smooth, identity-free junction authority; outside it this is exactly
// 1.0. The 1.05 endpoint is measurement-derived: on Apple M2 Pro / Metal at
// 1280x720, the 6 m relief coverage-strength product then holds above current
// main while crawl remains identical against a zero plates-off floor (#589).
float terrain_plate_junction_read_gain(float covered_junction) {
	return mix(1.0, 1.05, covered_junction);
}

// A PERFORMANCE gate only, never a blend authority. Once the fourth cell is
// outside the nearest cell's footprint every later window weight is exactly
// zero, so the generalized result has already converged to the established
// three-way answer. The hard step is therefore applied only after the two
// answers are equal, including at an exact third/fourth identity swap.
float terrain_plate_window_reachable(float f1, float f4, float fw) {
	return step(f4 - f1, max(fw, 1e-6));
}

// How much of the NEIGHBOURING plate belongs in this fragment.
//
// `f2 - f1` is the distance to the boundary and `fw` is the reconstruction
// reach. On the boundary the two plates are equally present and at `fw` the
// answer is entirely the owning plate's. Callers use twice the analytic
// separator footprint: a one-pixel box reconstruction still moves the shipped
// pale/basalt contrast by 0.10285 luma under plate_crawl's quarter-pixel step,
// while the four-pixel support keeps that move below its 0.05 crawl line. Cell
// interiors remain bit-identical; only the contact's reconstruction support
// changes, so the named substances keep their full contrast.
//
// Both the substance and the slab mask are step functions of the SAME cell id,
// so both step at exactly this boundary and both take this one weight — fixing
// only the substance would leave half the contrast still snapping.
float terrain_plate_edge_blend(float f1, float f2, float fw) {
	return 0.5 * (1.0 - smoothstep(0.0, max(fw, 1e-6), f2 - f1));
}

// The second moment of a sign-flipping seam slope after a temporal-stability
// reconstruction. `seam_h` is the analytic one-pixel separator footprint used
// by the mean normal. The cavity is unsigned luma energy rather than a signed
// direction, so it can use four footprints without moving the mean or softening
// the resolved normal. The wider support spreads the same unresolved groove
// across the pixels that can see it instead of letting one pixel take the whole
// occlusion step as the camera advances a fraction of a pixel (#306).
float terrain_plate_cavity_spread(
		float s_sep, float seam_h, float groove_width) {
	float cavity_h = max(seam_h * 4.0, 1e-6);
	float half_h = 0.5 * cavity_h;
	float prof = (min(s_sep + half_h, groove_width)
		- min(abs(s_sep - half_h), groove_width)) / cavity_h;
	float covered = clamp(max(min(s_sep + half_h, groove_width)
		- max(s_sep - half_h, -groove_width), 0.0) / cavity_h, 0.0, 1.0);
	return max(covered - prof * prof, 0.0);
}

// The crack RELIEF: how a seam between two plates tilts the normal into itself,
// and how much of that tilt a single pixel cannot represent. The ground and the
// cave-terrain contact band are adjacent on screen and are meant to read as one
// continuous floor, so both call this — a divergence between two copies showed
// up as seams raking differently in a strip around every cave mouth, with
// nothing failing anywhere (#464).
//
// `groove_width` is the caller's `crack_width` and `plate_uv_scale` its
// `plate_scale`; they are parameters rather than uniforms read directly so this
// include keeps the file's no-uniform convention.
//
// The relief is read at the PIXEL CENTRE, and what it reads is finer than
// the mark every guard below is keyed on: the crack profile turns over
// inside a half-width, so its slope peaks at w/2 and is zero at both ends —
// under-sampled a factor of two sooner than the crack itself. That
// point-sample is the crawl.
//
// So integrate the groove across the pixel instead of sampling it. Two
// moments come out and the treatment needs BOTH:
//   - the MEAN tilt, which is what a normal can carry; and
//   - the VARIANCE about it, which a normal cannot, because a pixel
//     spanning a whole groove sees the two walls cancel exactly.
// Filtering to the mean alone is correct and still erases the seam: past
// the distance a groove resolves, the honest answer for the mean IS no net
// tilt. The detail is not gone, it moved into the second moment — which the
// callers carry as occlusion.
void terrain_plate_seam_relief(
		vec2 plate_uv,
		vec2 plate_c1,
		vec2 plate_c2,
		float groove_width,
		float plate_uv_scale,
		float plate_mask_relief,
		float plate_mask_relief_nb,
		float plate_mask_relief_nb3,
		float edge_fw,
		float f1,
		float f2,
		float f3,
		float plate_fw,
		float crack_fw,
		vec3 plate_w,
		float plate_window_gate,
		float plate_window_w,
		float plate_window_slab_share,
		float sheet,
		float plate_resolved,
		float plate_edge_w,
		out vec2 grad,
		out float seam_slope_var) {
	// The closed-form crack gradient. Differencing the crack field samples a step
	// narrower than a pixel past a few metres, which IS the aliasing rather than a
	// reading of it. grad(f2 - f1) = normalize(uv - c2) - normalize(uv - c1).
	vec2 d1 = plate_uv - plate_c1;
	vec2 d2 = plate_uv - plate_c2;
	// inversesqrt of a floored square length: a fragment sitting exactly on a
	// centre would otherwise normalize a zero vector.
	vec2 gsep = d2 * inversesqrt(max(dot(d2, d2), 1e-12))
		- d1 * inversesqrt(max(dot(d1, d1), 1e-12));
	float cw_relief = max(groove_width, 1e-6);
	// The profile integrated is a TOP HAT, because the seam-slope ceiling makes
	// it one. The raw slope peaks at 6*0.25/w * plate_scale, which at the
	// shipped width is ~40 against a ceiling of 0.4 — a hundredfold — so the
	// clamp binds across all but the outermost half-percent of the groove, and
	// what this actually applies is a constant-magnitude wall that flips
	// sign at the seam. `amp` is that plateau, reached through the same ceiling,
	// so the model follows the code rather than assuming it: open `crack_width`
	// far enough that the clamp stops binding and `amp` becomes the true peak.
	float amp_scale = length(gsep) * (1.5 / cw_relief) * plate_uv_scale;
	float amp = min(amp_scale * plate_mask_relief, 0.4);
	// The same plateau for the NEIGHBOURING cell. The profile below is shared —
	// it is a property of the footprint and the seam, not of either cell — so
	// the only per-cell quantity is this height, and blending the two over the
	// boundary footprint is what keeps the cavity continuous across a
	// slab-to-bare contact. The mean does not need this and the variance does.
	float amp_nb = min(amp_scale * plate_mask_relief_nb, 0.4);
	// And the third candidate's, for the coverage split below.
	float amp_nb3 = min(amp_scale * plate_mask_relief_nb3, 0.4);
	// The footprint is `edge_fw`, the ANALYTIC separator's screen rate — never
	// `fwidth(f2 - f1)`. That quantity is a cusp at the seam, so its screen
	// difference collapses on exactly the quads that straddle one: a filter
	// keyed on it widens everywhere EXCEPT where the seam is. That reads as a
	// free win on both instruments and is an artefact of a derivative
	// degenerating into its own epsilon floor, which varies by GPU and driver.
	float seam_h = max(edge_fw, 1e-6);
	float half_h = 0.5 * seam_h;
	float s_sep = f2 - f1;
	// Mean of a sign-flipping top hat over [s - h/2, s + h/2]. Its
	// antiderivative is min(|x|, w), which is EVEN, so the folded coordinate
	// `f2 - f1` serves directly: the straddling case (s < h/2) is carried by
	// the abs, and what comes out is the even function of the signed offset
	// that the fragment's own `gsep` then gives a direction to. At the seam the
	// two terms are equal and the mean is exactly zero, which is the
	// cancellation this whole term exists to account for.
	// The profile's SHAPE, with the per-cell height factored out: mean = amp *
	// prof, so this is the same closed form written once and reused by both
	// cells. It is dimensionless and depends only on the footprint's overlap
	// with the groove, which is why the two cells can share it.
	float prof = (min(s_sep + half_h, cw_relief)
		- min(abs(s_sep - half_h), cw_relief)) / seam_h;
	float mean_tilt = amp * prof;
	// Second moment. The top hat has magnitude `amp` wherever the footprint
	// overlaps the groove [-w, w], so E[u^2] is amp^2 times the covered
	// fraction of the pixel.
	// Var = E[u^2] - E[u]^2, reconstructed over a wider support than the signed
	// mean. The shared helper keeps this ground and the cave-contact band on the
	// same temporal filter; it is zero outside the groove and never changes the
	// mean normal above.
	float spread = terrain_plate_cavity_spread(s_sep, seam_h, cw_relief);
	// Start from the SAME three-candidate coverage split the substance, slab
	// mask, roughness and crack use. A pixel straddling a contact contains
	// every one of those cells' seams, so gating the integral by whichever cell
	// owns the pixel centre steps the cavity between full and zero as that
	// centre crosses. The higher-order branch below then generalizes this
	// per-cell factor through the same symmetric window as those quantities.
	//
	// The baseline uses `plate_w` rather than a pairwise
	// `mix(..., plate_edge_w)`. Away from a
	// triple junction the two are arithmetically identical — the weights reduce
	// to `(1 - plate_edge_w, plate_edge_w, 0)` there — so this changes nothing a
	// player can resolve and nothing off a junction. At one, the pairwise form
	// takes the second-nearest cell outright, and that cell changes IDENTITY
	// abruptly while still holding near half the fragment's weight, so the
	// cavity inherits a zero-width step in exactly the quantity it exists to
	// filter. `spread` is common to all three, so splitting the squared heights
	// is arithmetically identical to splitting the three variances, two
	// multiplies cheaper.
	float seam_amp_sq = amp * amp * plate_w.x + amp_nb * amp_nb * plate_w.y
		+ amp_nb3 * amp_nb3 * plate_w.z;
	if (plate_window_gate > 0.0 && plate_window_w > 0.0) {
		// Every resolved cell has one of two slab states, so the retained
		// `plate_window_slab_share` composes their already-clamped squared
		// amplitudes exactly without paying for a second 5x5 hash loop here.
		float low_amp = min(
			amp_scale * sheet * mix(0.40, 0.0, plate_resolved), 0.4);
		float high_amp = min(
			amp_scale * sheet * mix(0.40, 1.0, plate_resolved), 0.4);
		float window_amp_sq = mix(
			low_amp * low_amp,
			high_amp * high_amp,
			plate_window_slab_share);
		// This pairwise expression is only the base of the generalized
		// composition. At the fourth-cell reach cutoff the normalized window
		// has become the established symmetric three-way term, so mixing from
		// the pairwise base with the common junction ramp converges to the
		// assignment above before the performance gate skips the work.
		float pair_amp_sq = amp * amp * (1.0 - plate_edge_w)
			+ amp_nb * amp_nb * plate_edge_w;
		seam_amp_sq = mix(
			pair_amp_sq,
			window_amp_sq,
			plate_window_w);
	}
	seam_slope_var = seam_amp_sq * spread;
	// Removing the old label-swap jump also removes the energy that hard step
	// contributed. Preserve the measured 6 m read only under the same smooth,
	// identity-free junction authority; off-junction this is exactly 1.0.
	float junction_read_authority = terrain_plate_covered_junction(
		f1, f2, f3, plate_fw);
	float junction_read_gain = terrain_plate_junction_read_gain(
		junction_read_authority);
	mean_tilt *= junction_read_gain;
	seam_slope_var *= junction_read_gain * junction_read_gain;
	// The tilt is INTO the groove, so it opposes the separator's gradient —
	// the same sign the differenced form and the closed-form `dcrack` both
	// carried, the latter by being negative by construction.
	//
	// This is inside the caller's `plates_enabled` gate for a reason found by
	// measurement: when the relief was computed unconditionally, the grooves kept
	// raking the light with the treatment switched off, moving cave-chamber
	// 29.61% away from base. Shader reasoning said the gate was already exact; it
	// was not.
	vec2 ghat = gsep * inversesqrt(max(dot(gsep, gsep), 1e-12));
	grad = -ghat * mean_tilt;
	// A screen-space gradient is UNBOUNDED as the feature it measures compresses
	// into a pixel: at a grazing angle a seam 4 cm wide spans a fraction of one,
	// and the raw slope runs to tens per metre — enough to swing the normal
	// through a right angle and shimmer. Two guards, both of which the albedo
	// crack already had and this term was missing:
	//   - dissolve on the SAME schedule as the crack it belongs to, so relief
	//     never outlives the mark that justifies it;
	//   - clamp the magnitude, so a single degenerate quad cannot flip a normal.
	// Without these the ground kept a jittering micro-relief exactly where the
	// crack had visually vanished — detail leaving by shimmering rather than by
	// fading, which is the failure this shader family is written to avoid.
	grad *= 1.0 - smoothstep(0.30, 0.85, plate_fw);
	// The first of those two guards did not actually do what it says. `plate_fw`
	// is the footprint of a whole PLATE, and a plate is some thirty times wider
	// than the seam drawn inside it, so dissolving on it is not "the same
	// schedule as the crack" — it does not engage until long after the crack has
	// stopped being drawable. In between, the profile above is a step of
	// CONSTANT width (deliberately, per the note on the second-derivative), and
	// past about eight metres that width is narrower than one pixel. So this
	// term spent that whole range differencing a sub-pixel step, which is
	// precisely the jittering micro-relief the paragraph above describes.
	//
	// So dissolve on the CRACK's own footprint too. The ratio is how far the
	// seam has had to be stretched to stay a pixel wide, making 1.0 exactly the
	// distance at which it stops being resolvable; the fade is centred there.
	// Below 0.7 this multiplier is exactly 1.0, so every seam a player can
	// actually resolve keeps its full relief, unchanged.
	//
	// Measured on-GPU (tools/plate_crawl): the flickering fraction of the ground
	// falls 0.0052 -> 0.0027 against a plates-off control that reads 0.0000.
	//
	// The relief is most of what moves, but NOT all of it. A later session
	// measured `crack_relief = 0` at 0.0007 rather than the 0.0000 recorded
	// above, twice, by two independent routes (the uniform zeroed outright, and
	// this fade forced closed) agreeing to the digit on flicker, peak and
	// spread, against a plates-off control still reading 0.0000. What is left
	// at that floor is the substance and slab boundary — the step this issue was
	// originally filed on. Absolute levels here are not portable between
	// machines and the tool says so; the ordering is what carries.
	grad *= 1.0 - smoothstep(0.7, 1.3, crack_fw * 1.2 / max(groove_width, 1e-6));
	// The magnitude bound is the SLOPE A SEAM CAN HAVE, not a catastrophe
	// backstop. The caller adds `grad * crack_relief` to the horizontal
	// components of a unit normal, so the ceiling is a tilt: at the shipped
	// crack_relief this bounds it by atan(0.4 * 1.1) ~= 24 degrees, the wall of a
	// shallow groove a few centimetres across that ash settles into. A ceiling
	// set only high enough to stop one degenerate quad flipping a normal allows
	// atan(1.5 * 1.1) ~= 59 degrees, which no seam in this ground has — so every
	// under-sampled quad claiming an impossible slope passed through it
	// untouched, and that is what the fade above was left carrying alone.
	//
	// A bound on the SLOPE and the fade above are different levers, and the
	// difference is the whole reason this one is here. The fade is keyed on
	// distance, so it removes shimmer and near-field seam read together at
	// about 1:1 — measured on-GPU with both instruments in one sitting, pulling
	// the fade window in to (0.40, 0.75) buys 65% of the relief's flicker and
	// takes 65-74% of the seam coverage at every swept distance with it, which
	// is the softening #306's third acceptance criterion forbids. This is keyed
	// on the slope a fragment claims, which is what actually distinguishes an
	// aliased sample from a resolved one, so it buys the SAME 65% while leaving
	// the near field untouched: coverage at 6 m is 0.00045 either way, and the
	// loss past it stays within 21% against the fade's 65-74%. What it spends
	// instead is rake strength, 22% at 6 m — every seam still there, raking
	// slightly less hard. Below 0.4 the near field goes too (0.2 already costs
	// 13% of the 6 m coverage), so this is the knee rather than a floor.
	float grad_len = length(grad);
	grad = grad_len > 0.4 ? grad * (0.4 / grad_len) : grad;
	// The variance takes the PLATE resolution cutoff and nothing else. Once a
	// pixel spans a whole plate there are no per-plate seams left to have a
	// second moment about, exactly as the substance and slab mask converge on
	// their means — so this one is a statement about what exists, not a
	// fade bought to hide shimmer.
	//
	// It deliberately does NOT take the crack-footprint fade or the slope
	// ceiling. Those two bound what the NORMAL may claim, and the read they
	// give up is precisely what this term carries instead; applying them here
	// would hand back the seam they were spent on. Variance scales as the
	// square of the amplitude it is a variance of, so the cutoff enters
	// squared.
	seam_slope_var *= plate_resolved * plate_resolved;
}

vec4 terrain_plate_substance(
		vec2 id,
		vec3 rock,
		float rock_rough,
		vec3 basalt,
		vec3 ferric,
		vec3 pale) {
	float pick = terrain_hash3(vec3(id * 1.7, 3.0));
	vec3 c = rock;
	c = mix(c, basalt, step(0.38, pick));
	c = mix(c, ferric, step(0.66, pick));
	c = mix(c, pale, step(0.86, pick));
	float r = rock_rough;
	r = mix(r, 0.88, step(0.38, pick));
	r = mix(r, 0.72, step(0.66, pick));
	r = mix(r, 0.94, step(0.86, pick));
	return vec4(c, r);
}
