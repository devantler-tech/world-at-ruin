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

// `id` owns this fragment and `id2` is the cell across the nearest boundary —
// the only other plate a fragment can be partly covered by, and so the one to
// blend toward when that boundary falls inside a pixel.
void terrain_plates(
		vec2 uv, out vec2 id, out float f1, out float f2, out vec2 id2) {
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

// How much of the neighbouring plate this fragment's pixel actually covers.
//
// Every per-cell decision below is chosen from a cell id, so it changes in one
// step at a boundary. Once that boundary is narrower than a pixel the step
// lands inside the pixel and crawls as the camera moves: MSAA resolves geometry
// edges, not a procedural interior one, and the whole-plate footprint term
// answers a different question — a plate that is still many pixels across can
// have a subpixel boundary running through it.
//
// `f2 - f1` is the distance to that boundary: zero on it, growing to either
// side, so `fwidth()` of it is how much of the field one pixel spans. Weighting
// the neighbour over exactly that footprint makes every decision continuous
// across the boundary, because the two cells swap roles precisely where the
// weight is one half — both sides evaluate to the same half-and-half result.
// Away from a boundary the weight falls to zero and a plate keeps its own
// answer outright, so the treatment still decides rather than interpolates.
float terrain_plate_boundary_blend(float f1, float f2) {
	float edge = f2 - f1;
	// smoothstep() is undefined when its two edges are equal, which a run of
	// fragments with no local variation in the field can reach exactly.
	return 0.5 * (1.0 - smoothstep(0.0, max(fwidth(edge), 1e-5), edge));
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

// The substance a pixel actually covers, rather than whichever cell won its
// centre. Two neighbouring slabs can be the highest-contrast pair in the set
// (basalt against pale stone), so this boundary is the one that shows.
vec4 terrain_plate_substance_filtered(
		vec2 id,
		vec2 id2,
		float blend,
		vec3 rock,
		float rock_rough,
		vec3 basalt,
		vec3 ferric,
		vec3 pale) {
	return mix(
		terrain_plate_substance(id, rock, rock_rough, basalt, ferric, pale),
		terrain_plate_substance(id2, rock, rock_rough, basalt, ferric, pale),
		blend);
}

// Whether this cell carries stone at all. Broken rock is discrete stones with
// ash between them, so a cell either draws a slab or does not — and that choice
// steps at the same boundaries the substance does, over the full contrast
// between bare rock and a named substance. It is filtered over the same
// footprint for the same reason.
float terrain_plate_slab(vec2 id, vec2 id2, float blend) {
	return mix(
		step(0.60, terrain_hash3(vec3(id * 2.3, 19.0))),
		step(0.60, terrain_hash3(vec3(id2 * 2.3, 19.0))),
		blend);
}
