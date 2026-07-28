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

// `id2` is the cell on the OTHER side of the nearest boundary — the plate this
// fragment would have belonged to had it fallen a little further across. It is
// tracked alongside `f2` (they are the same cell by definition: f2 is that
// cell's centre distance) so a caller can antialias the step between the two
// rather than taking the owning cell's value outright.
void terrain_plates(vec2 uv, out vec2 id, out float f1, out float f2, out vec2 id2) {
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

// How much of the NEIGHBOURING plate belongs in this fragment.
//
// `f2 - f1` is the distance to the boundary, and `fw` is how far that quantity
// moves across one pixel, so the ratio is where the fragment sits within its own
// footprint. On the boundary the two plates are equally present and the answer
// is a half; a footprint away it is entirely the owning plate's. That is the
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
