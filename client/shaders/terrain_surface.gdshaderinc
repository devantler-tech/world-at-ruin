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

// `id` is the owning cell and `id2` the runner-up — the plate on the other side
// of the nearest boundary. Both are needed because every per-cell decision (the
// substance, and whether the cell carries a slab at all) is a step function of
// the id, and a step function has no width to filter over. Knowing the other
// claimant is what makes the boundary filterable at all.
void terrain_plates(vec2 uv, out vec2 id, out vec2 id2, out float f1, out float f2) {
	vec2 base = floor(uv);
	f1 = 1000.0;
	f2 = 1000.0;
	id = base;
	id2 = base;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 cell = base + vec2(float(i), float(j));
			vec2 jitter = vec2(
				terrain_hash3(vec3(cell, 0.0)),
				terrain_hash3(vec3(cell, 7.0)));
			vec2 centre = cell + 0.15 + 0.7 * jitter;
			float d = length(uv - centre);
			if (d < f1) {
				f2 = f1;
				id2 = id;
				f1 = d;
				id = cell;
			} else if (d < f2) {
				f2 = d;
				id2 = cell;
			}
		}
	}
}

// How much of the RUNNER-UP plate this fragment should be given, 0.5 exactly on
// a boundary falling to 0.0 one screen footprint away.
//
// `f2 - f1` is zero on a boundary and grows as the fragment moves into the
// owning plate, so it is the boundary's own distance field; `gap_fw` is that
// field's screen-space derivative, i.e. the width of one pixel measured in it.
// Filtering in those units is what keeps this an ANTIALIASING term rather than a
// softening one: the transition is about a pixel wide wherever it is seen, so
// underfoot it spans a few millimetres of ground and the plate still reads as
// decided, while at the medium distances where a boundary lands inside a single
// pixel it is the difference between a step and a ramp.
//
// Without it `id` flips discontinuously across the boundary and every per-cell
// decision flips with it — basalt to pale stone in the space of no pixels at
// all. The configured MSAA cannot help: this is a procedural edge in a surface's
// interior, not a geometry edge, so nothing in the pipeline has ever been asked
// to resolve it, and the contact crawls as the camera moves.
//
// 0.5 rather than 1.0 at the boundary is the physically right answer: there the
// two plates are exactly equidistant, so the pixel genuinely covers half of
// each. Blending all the way to 1.0 would swap the plates over rather than
// average them, which just moves the step instead of removing it.
float terrain_plate_edge_weight(float f1, float f2, float gap_fw) {
	return 0.5 * (1.0 - smoothstep(0.0, max(gap_fw, 1e-6), f2 - f1));
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

// The substance, resolved across the boundary instead of at it. `edge_w` comes
// from [terrain_plate_edge_weight]; at 0.0 this is exactly the owning plate's
// own substance, so everywhere except the pixel-wide contact the answer is
// unchanged and the plate still states one substance outright.
vec4 terrain_plate_substance_filtered(
		vec2 id,
		vec2 id2,
		float edge_w,
		vec3 rock,
		float rock_rough,
		vec3 basalt,
		vec3 ferric,
		vec3 pale) {
	vec4 own = terrain_plate_substance(id, rock, rock_rough, basalt, ferric, pale);
	vec4 other = terrain_plate_substance(id2, rock, rock_rough, basalt, ferric, pale);
	return mix(own, other, edge_w);
}

// Whether this cell carries a slab, resolved across the boundary the same way.
//
// This is the SECOND per-cell step function the boundary carries, and filtering
// only the substance would have left the contact crawling just as badly: a slab
// meeting open ground is the larger contrast of the two, because it is the edge
// of the stone itself rather than a change of stone. One weight drives both, so
// the substance and the silhouette can never resolve the same boundary at
// different widths.
float terrain_plate_slab(vec2 id, vec2 id2, float edge_w, float threshold) {
	float own = step(threshold, terrain_hash3(vec3(id * 2.3, 19.0)));
	float other = step(threshold, terrain_hash3(vec3(id2 * 2.3, 19.0)));
	return mix(own, other, edge_w);
}
