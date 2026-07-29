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
// out-parameters rather than another nine-cell evaluation.
//
// `id2` is the CELL those second-nearest values belong to — the plate this
// fragment would have belonged to had it fallen a little further across. It
// costs nothing extra for the same reason `c2` does (the search already knows
// it), and it is what lets a caller average the substance step across the
// boundary rather than taking the owning cell's value outright.
//
// `f3`/`id3` are the THIRD-nearest, and they exist because `id2` alone is not a
// continuous choice of neighbour. At a triple junction the owning cell stays the
// same while the second- and third-nearest swap across their bisector, so a
// caller blending toward `id2` sees its blend target change identity abruptly
// while the weight is still near a half (#499). Carrying the third candidate is
// what lets that swap be made harmless; see `terrain_plate_junction_split`. It
// costs two more out-parameters and no additional distance evaluation — the
// nine-cell search already visits every candidate.
void terrain_plates(
		vec2 uv, out vec2 id, out float f1, out float f2,
		out vec2 c1, out vec2 c2, out vec2 id2,
		out float f3, out vec2 id3) {
	vec2 base = floor(uv);
	f1 = 1000.0;
	f2 = 1000.0;
	f3 = 1000.0;
	id = base;
	c1 = base;
	c2 = base;
	id2 = base;
	id3 = base;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 cell = base + vec2(float(i), float(j));
			vec2 jitter = vec2(
				terrain_hash3(vec3(cell, 0.0)),
				terrain_hash3(vec3(cell, 7.0)));
			vec2 centre = cell + 0.15 + 0.7 * jitter;
			float d = length(uv - centre);
			if (d < f1) {
				f3 = f2;
				id3 = id2;
				f2 = f1;
				c2 = c1;
				id2 = id;
				f1 = d;
				c1 = centre;
				id = cell;
			} else if (d < f2) {
				f3 = f2;
				id3 = id2;
				f2 = d;
				c2 = centre;
				id2 = cell;
			} else if (d < f3) {
				f3 = d;
				id3 = cell;
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

// How much of the NEIGHBOURING plate belongs in this fragment.
//
// `f2 - f1` is the distance to the boundary and `fw` is the HALF-footprint —
// how far the pixel reaches toward one side. Callers pass half of the full
// per-pixel variation, because that variation spans the pixel and so reaches
// only half of it either way. Ramping over the full width instead would still
// hand ~8% of the neighbour to a pixel lying wholly inside its own plate, which
// is a soft band rather than a coverage average, and would soften named
// substances at resolved contacts — the opposite of this term's purpose.
// On the boundary the two plates are equally present and the answer is a half;
// a half-footprint away it is entirely the owning plate's. That is the
// whole term: it is an analytic average over the pixel, not a soft edge, so it
// is exactly 0.0 wherever the boundary is resolved and only engages once the
// step is narrower than the pixel drawing it.
//
// Both the substance and the slab mask are step functions of the SAME cell id,
// so both step at exactly this boundary and both take this one weight — fixing
// only the substance would leave half the contrast still snapping.
float terrain_plate_edge_blend(float f1, float f2, float fw) {
	return 0.5 * (1.0 - smoothstep(0.0, max(fw, 1e-6), f2 - f1));
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
