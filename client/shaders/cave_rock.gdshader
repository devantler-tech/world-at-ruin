shader_type spatial;
// Cave rock: warm sandstone striations in the WoW register — broad banded
// strata warped by low-frequency noise, sediment floors, all procedural
// ("as code": no textures, the look is arithmetic).
//
// The mesh bakes coarse shading into COLOR (band tint, floor blend, torch-
// side warmth); this shader adds the fine strata the vertex density cannot
// carry. Bands run along world Y so they read as geological layers whatever
// the wall's shape.

// band_a/b/c and roughness_value are gone with the interpolated interior they
// fed: the interior now names its substances below and derives roughness per
// bed. (`roughness_value` still exists in foliage.gdshader and debris.gdshader,
// which have their own copies — this removes only cave rock's, which nothing
// sets: cave_system_gen.gd loads the shader and uses its defaults.)
uniform float band_frequency = 1.1;
uniform float warp_strength = 1.6;

// ---- Decided bedding (#235) ---------------------------------------------
// The interior used to be two smoothsteps of noise, one constant roughness and
// no normal perturbation at all, which is why it measured 12.8% luminance range
// and 6.3 degrees of hue against a 93.5% / 324 wide-gamut control
// (docs/art-direction/README.md). Noise interpolates; it never DECIDES. So the
// interior now picks a substance per bed, contacts them hard, and cuts the
// result with fractures — edges a shader can state outright.
//
// Four named substances. The spread is deliberate on BOTH axes the reference
// set measures: sandstone->pale is a value range the old palette never had
// (0.19 to 0.72 luma against the old 0.30 to 0.58), and shale sits off the warm
// hue line the whole cave used to share.
uniform vec3 rock_sandstone: source_color = vec3(0.62, 0.45, 0.28);
uniform vec3 rock_shale: source_color = vec3(0.20, 0.19, 0.20);
uniform vec3 rock_pale: source_color = vec3(0.78, 0.72, 0.60);
uniform vec3 rock_iron: source_color = vec3(0.48, 0.22, 0.12);
// Beds per unit of the warped strata coordinate, which already carries
// band_frequency — so a bed is about 1 / (band_frequency * bed_frequency)
// metres of rock, roughly 0.9m here. That is a thickness a standing player can
// read against their own height. Calibrated on rendered frames, not by taste:
// 2.7 (~0.3m beds) aliased into printed corduroy, 0.38 (~2.4m) put so few
// contacts in frame that the cave measured FLATTER than before the change.
uniform float bed_frequency = 2.2;
// Contact width as a FRACTION of a bed, so a seam stays a line at every bed
// thickness instead of becoming a gradient on the thick ones.
uniform float seam_width: hint_range(0.001, 0.25) = 0.055;
uniform float seam_darkness: hint_range(0.0, 1.0) = 0.30;
// Joints: near-vertical fractures cutting ACROSS the bedding. Squashed in Y so
// one joint runs the height of a face rather than tiling.
uniform float joint_scale = 0.09;
uniform float joint_width: hint_range(0.001, 0.2) = 0.03;
// Relief depth for the interior. Bedding planes and joints are the only cue
// grazing torchlight has that this rock has a surface at all.
uniform float interior_relief: hint_range(0.0, 2.0) = 0.50;

// A hard edge narrower than a pixel does not read as an edge — it aliases into
// moire, which is what the first cut of this shader shipped. Every threshold
// below is therefore widened to the local screen footprint (fwidth) and faded
// out entirely once the feature it bounds is smaller than about a pixel, so
// detail leaves the frame by dissolving rather than by shimmering.
// coord is the CONTINUOUS coordinate, not its fract: fwidth() of a fract()
// spikes to ~1 at every wrap, which is exactly where the seam is, so measuring
// the footprint there would erase each line precisely along its own centre.
// One bed's substance, resolved from its id alone so a neighbouring bed can be
// evaluated too and the pair filtered across their contact. rgb = colour,
// a = roughness.
vec4 substance(float id) {
	float pick = hash3(vec3(id * 3.1, 5.0, 11.0));
	// step() rather than smoothstep(): a bed IS sandstone or IS shale. Chained
	// mixes mean each later threshold overrides the earlier one exactly.
	vec3 c = mix(rock_sandstone, rock_shale, step(0.34, pick));
	c = mix(c, rock_pale, step(0.61, pick));
	c = mix(c, rock_iron, step(0.85, pick));
	float r = mix(0.97, 0.88, step(0.34, pick));
	r = mix(r, 0.93, step(0.61, pick));
	r = mix(r, 0.99, step(0.85, pick));
	return vec4(c, r);
}

// Surface-tangent gradient of a height field, from its screen derivatives.
// The caller must pass a height built ONLY from fixed-width terms: anything
// carrying fwidth() would make this a second derivative, which is undefined.
vec3 surface_gradient(float h, vec3 nrm, vec3 r1, vec3 r2, float safe_det) {
	vec3 g = (dFdx(h) * r1 + dFdy(h) * r2) / safe_det;
	return g - nrm * dot(g, nrm);
}

float edge_line(float coord, float half_width) {
	float fw = fwidth(coord);
	float f = fract(coord);
	float w = max(half_width, fw * 1.2);
	float line = 1.0 - smoothstep(0.0, w, min(f, 1.0 - f));
	return line * (1.0 - smoothstep(0.30, 0.85, fw));
}

// ---- Weathered exterior (#156) ------------------------------------------
// COLOR.a carries a baked sky-exposure mask (1 = the massif's outer hull,
// 0 = a carved cave wall, blending through the mouth). Every exterior term
// below is weighted by it, so interior fragments are untouched by this block.
// The palette sits between the ground's ash and rock colors on purpose: the
// massif must read as stone of the SAME landscape the terrain shader draws,
// not as cave sandstone that happens to be outdoors.
uniform vec3 weathered_a: source_color = vec3(0.46, 0.42, 0.36);
uniform vec3 weathered_b: source_color = vec3(0.29, 0.26, 0.23);
uniform vec3 weathered_c: source_color = vec3(0.55, 0.52, 0.46);
uniform vec3 ash_color: source_color = vec3(0.50, 0.46, 0.40);
// Fine surface grain — the grazing-light cue that the rock has substance
// (the terrain shader's lesson #1, applied to a wall).
uniform float ext_grain_scale = 2.9;
uniform float ext_bump_strength: hint_range(0.0, 3.0) = 0.55;
// Vertical scour streaking on steep faces: variation ACROSS the face,
// near-constant down the fall line, the way wind and runoff strip a cliff.
uniform float scour_strength: hint_range(0.0, 1.0) = 0.45;
uniform float ext_roughness: hint_range(0.0, 1.0) = 0.88;
// Fine detail fades with distance so the far silhouette stays calm
// (mirrors the terrain shader's fade so the two surfaces agree).
uniform float detail_fade_start = 45.0;
uniform float detail_fade_end = 130.0;

varying vec3 world_pos;
varying vec3 world_normal;

float hash3(vec3 p) {
	return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

float value_noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	vec3 u = f * f * (3.0 - 2.0 * f);
	float n000 = hash3(i);
	float n100 = hash3(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash3(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash3(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash3(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash3(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash3(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash3(i + vec3(1.0, 1.0, 1.0));
	return mix(
		mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
		mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}

float fbm(vec3 p) {
	float amp = 0.5;
	float sum = 0.0;
	for (int i = 0; i < 3; i++) {
		sum += amp * value_noise(p);
		p *= 2.03;
		amp *= 0.5;
	}
	return sum;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
}

void fragment() {
	// Strata: bands along Y, warped so layers sag and flow like the rock.
	float warp = fbm(world_pos * 0.13) * warp_strength;
	float layer = world_pos.y * band_frequency + warp;
	vec3 n = normalize(world_normal);
	vec3 base = COLOR.rgb;
	float sky = COLOR.a;

	// ---- Bedding: one substance per bed, contacted hard --------------------
	// floor() of the warped strata coordinate is the decision. Every fragment
	// in a bed resolves to the SAME substance, so a contact is a step and not a
	// ramp — the property the old smoothstep pair could not express.
	float bed_coord = layer * bed_frequency;
	float bed_id = floor(bed_coord);
	float bed_f = fract(bed_coord);
	// The SUBSTANCE needs filtering in its own right, and fading its amplitude
	// is not filtering: scaling one bed's colour toward a mean still leaves
	// every fragment choosing exactly one bed, so crossing a contact remains an
	// abrupt jump — the stair-step and temporal popping this block exists to
	// remove — right up until the fade completes.
	//
	// So filter in two stages, the way a mip chain does. FIRST, box-filter
	// across the contact: a pixel whose footprint straddles a boundary gets the
	// neighbouring bed blended in by the fraction of the pixel that actually
	// falls there. SECOND, once a pixel spans a whole bed there is no per-bed
	// answer left to give, so converge on the mean of the distribution weighted
	// by each substance's real selection width (0.34 / 0.27 / 0.24 / 0.15) —
	// a flat average would converge on a colour no bed has.
	float bed_fw = fwidth(bed_coord);
	float bed_resolved = 1.0 - smoothstep(0.30, 0.85, bed_fw);

	float dist_to_edge = min(bed_f, 1.0 - bed_f);
	float neighbour_frac = clamp((bed_fw * 0.5 - dist_to_edge)
		/ max(bed_fw, 1e-5), 0.0, 0.5);
	float neighbour_id = bed_f < 0.5 ? bed_id - 1.0 : bed_id + 1.0;
	vec4 sub = mix(substance(bed_id), substance(neighbour_id), neighbour_frac);

	vec3 mean_col = rock_sandstone * 0.34 + rock_shale * 0.27
		+ rock_pale * 0.24 + rock_iron * 0.15;
	float mean_rough = 0.97 * 0.34 + 0.88 * 0.27 + 0.93 * 0.24 + 0.99 * 0.15;
	sub = mix(vec4(mean_col, mean_rough), sub, bed_resolved);
	vec3 sub_col = sub.rgb;
	float sub_rough = sub.a;

	// Some beds are laminated into finer plates, some are massive. One hash per
	// bed decides which — a bed is never half of each. Two plates, not four:
	// the finer split was the loudest source of the moire the first cut shipped.
	float bed_rand = hash3(vec3(bed_id, 17.0, 3.0));
	float laminated = step(0.68, bed_rand);

	// Bedding planes recess into a dark line at each contact.
	float seam = edge_line(bed_coord, seam_width);
	float lam_seam = edge_line(bed_coord * 2.0, seam_width * 1.4) * laminated;

	// ---- Joints: fractures across the beds ---------------------------------
	// Thresholding |field - 0.5| turns the field's zero crossing into a LINE
	// with an edge, instead of the broad wash a smoothstep of the field gives.
	// Footprint-widened for the same reason as the bedding.
	float jf = fbm(world_pos * vec3(joint_scale, joint_scale * 0.18, joint_scale)
		+ vec3(31.0));
	float jf_fw = fwidth(jf);
	float jw = max(joint_width, jf_fw * 1.2);
	float joint = 1.0 - smoothstep(0.0, jw, abs(jf - 0.5));
	// How well a joint is still resolved, in the field's own units: once one
	// pixel spans several times the joint's width there is no line left to draw.
	float joint_resolved = 1.0 - smoothstep(joint_width, joint_width * 4.0, jf_fw);

	// Floors silt over: blend toward the baked sediment color from below. The
	// bedding is near-parallel to a floor, so it would wash out into flat
	// sheets there; the same joint field doubles as a sediment mottle instead,
	// at no extra noise tap. Kept low-contrast — pushed harder it reads as
	// contour lines drawn on the floor rather than as silt.
	float floor_mix = smoothstep(0.45, 0.8, n.y);
	float sediment = smoothstep(0.35, 0.65, jf);

	float recess = max(seam, max(lam_seam * 0.55, joint * 0.45));
	vec3 rock = mix(sub_col, sub_col * seam_darkness, recess);
	rock = mix(rock, mix(sub_col * 0.93, sub_col * 1.05, sediment), floor_mix * 0.5);
	vec3 interior = mix(base * rock * 1.9, base, floor_mix * 0.45);
	float interior_rough = clamp(sub_rough + 0.03 * recess, 0.0, 1.0);

	// ---- Relief ------------------------------------------------------------
	// The seams and joints are a height field, so its screen-space gradient is
	// the surface normal they imply. dFdx/dFdy costs a few ALU against the two
	// extra noise taps an offset-sampled gradient would need, which matters on
	// a surface that fills the frame in the opening cave. It is per-quad, so
	// the relief is clamped rather than trusted at silhouettes.
	//
	// 🔴 The height field is rebuilt here from FIXED-WIDTH masks and must stay
	// that way. The shaded `recess` above is footprint-widened, so it already
	// contains fwidth() — and differentiating a value that is itself a
	// derivative is undefined or implementation-dependent, which on another GPU
	// shows up as unstable lighting or quad-shaped blocks across the whole
	// starter cave. (This client already renders on at least two very different
	// devices: this Apple GPU and CI's Paravirtual one.) These masks are only
	// ever differentiated, never shaded, so aliasing in them does not reach the
	// frame directly.
	//
	// `recess` is high where rock has been CUT AWAY, so it enters the height
	// field NEGATED: a bedding plane or a joint must sit below the face. With
	// +recess the derived normal bulges each crack outward and grazing
	// torchlight embosses it — the exact inverse of the intent. Silt is the one
	// term that genuinely adds material, so it keeps its positive sign.
	float h_seam = 1.0 - smoothstep(0.0, seam_width, min(bed_f, 1.0 - bed_f));
	float lam_f = fract(bed_coord * 2.0);
	float h_lam = (1.0 - smoothstep(0.0, seam_width * 1.4,
		min(lam_f, 1.0 - lam_f))) * laminated;
	float h_joint = 1.0 - smoothstep(0.0, joint_width, abs(jf - 0.5));
	// Detail must leave the LIGHTING on the same schedule it leaves the albedo,
	// or dissolved detail returns as shimmer. But the fade factors themselves
	// carry fwidth(), so multiplying them INTO the height before differentiating
	// would recreate the very second-order derivative this block forbids.
	//
	// So: differentiate each fixed-width field on its own, then fade each
	// resulting GRADIENT by its own footprint factor. Bedding and joints fade on
	// different schedules — a joint stops being resolvable at a different
	// distance than a bed does — which is exactly why they cannot share one
	// height field. Silt carries no fwidth and needs no fade.
	vec3 dpx = dFdx(world_pos);
	vec3 dpy = dFdy(world_pos);
	vec3 r1 = cross(dpy, n);
	vec3 r2 = cross(n, dpx);
	float det = dot(dpx, r1);
	float safe_det = max(abs(det), 1e-9) * (det < 0.0 ? -1.0 : 1.0);

	float h_bed = max(h_seam, h_lam * 0.55);
	float h_jnt = h_joint * 0.45;
	float h_silt = 0.10 * sediment * floor_mix;
	vec3 g_bed = surface_gradient(h_bed, n, r1, r2, safe_det) * bed_resolved;
	vec3 g_jnt = surface_gradient(h_jnt, n, r1, r2, safe_det) * joint_resolved;
	vec3 g_silt = surface_gradient(h_silt, n, r1, r2, safe_det);
	// Recesses subtract height, silt adds it.
	vec3 relief_grad = g_silt - (g_bed + g_jnt);
	if (length(relief_grad) > 4.0) {
		relief_grad = normalize(relief_grad) * 4.0;
	}
	vec3 interior_normal = normalize(n - relief_grad * interior_relief);

	// Weathered exterior, weighted by the baked exposure mask. The whole block
	// sits behind one coherent branch: the mask splits the mesh into large
	// contiguous interior/exterior regions, so warps don't diverge and an
	// interior fragment — which can fill the screen in the opening cave —
	// pays nothing for the outdoor treatment. At mask 0 the branch is skipped
	// and the defaults below ship the exact pre-#156 interior result.
	ALBEDO = interior;
	ROUGHNESS = interior_rough;
	NORMAL = normalize((VIEW_MATRIX * vec4(interior_normal, 0.0)).xyz);
	if (sky > 0.001) {
		float dist = length(world_pos - CAMERA_POSITION_WORLD);
		float detail = 1.0 - smoothstep(detail_fade_start, detail_fade_end, dist);

		// The exterior's own strata terms live inside the branch: they are the
		// only consumers left now that the interior beds itself, so an interior
		// fragment no longer pays for a value_noise and an fbm it discards.
		float band = value_noise(vec3(0.0, layer * 2.1, 0.0));
		float vein = fbm(world_pos * vec3(0.05, 0.9, 0.05) + vec3(warp));

		// The same geological bedding, bleached and cooled: outdoor rock keeps
		// its layers but an age of sun and ash has taken the warm glow out.
		vec3 wstrata = mix(weathered_a, weathered_b, smoothstep(0.25, 0.75, band));
		wstrata = mix(wstrata, weathered_c, smoothstep(0.55, 0.95, vein) * 0.4);
		// The baked tint keeps its variation but not its warmth outdoors.
		vec3 wbase = mix(vec3(dot(base, vec3(0.3333))), base, 0.45);

		// Scour: streaks run DOWN a face, so the noise is stretched along Y
		// and the darkening applies where the rock stands steep.
		float steep = clamp(1.0 - n.y, 0.0, 1.0);
		float streak = fbm(world_pos * vec3(1.6, 0.22, 1.6));
		float scour = smoothstep(0.42, 0.78, streak) * smoothstep(0.35, 0.75, steep);

		// Ash settles where the rock lies back — the same ash the ground
		// wears, so the massif meets the Reach in one material family. A broad
		// drift term wanders the boundary like the terrain's rock line.
		float drift = fbm(world_pos * 0.16);
		float ash_mix = smoothstep(0.3, 0.75, n.y) * smoothstep(0.3, 0.7, drift + 0.15);

		// Grain: multi-scale brightness/roughness break-up plus a perturbed
		// normal — grazing light picking out grit is what stops a smooth SDF
		// dome reading as plastic under this world's low sun.
		float e = 0.2;
		float g0 = fbm(world_pos * ext_grain_scale);
		float gx = fbm((world_pos + vec3(e, 0.0, 0.0)) * ext_grain_scale);
		float gy = fbm((world_pos + vec3(0.0, e, 0.0)) * ext_grain_scale);
		float gz = fbm((world_pos + vec3(0.0, 0.0, e)) * ext_grain_scale);
		vec3 grad = vec3(g0 - gx, g0 - gy, g0 - gz);
		grad -= n * dot(grad, n); // Keep the tangential part: bumps ride the face.

		vec3 exterior = wbase * wstrata * 2.1;
		exterior = mix(exterior, exterior * 0.68, scour * scour_strength);
		exterior = mix(exterior, ash_color * wbase * 2.0, ash_mix * 0.5);
		exterior *= 0.9 + 0.2 * mix(0.5, g0, detail);

		ALBEDO = mix(interior, exterior, sky);
		ROUGHNESS = mix(interior_rough, ext_roughness - 0.08 * (g0 - 0.5) * detail, sky);
		SPECULAR = mix(0.5, 0.2, sky);
		// Fade the interior relief back to the flat face as exposure rises, so
		// it dissolves through the mouth instead of stepping off at the first
		// fragment the mask calls exterior. It must actually reach zero at
		// sky == 1: out there the albedo is entirely the weathered exterior
		// material, so leaving the bedding relief at full strength would light
		// the outer massif with seams and fractures that are not on it.
		vec3 relief_normal = normalize(mix(interior_normal, n, sky));
		vec3 perturbed = normalize(relief_normal + grad * ext_bump_strength * sky * detail);
		NORMAL = normalize((VIEW_MATRIX * vec4(perturbed, 0.0)).xyz);
	}
}
