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
