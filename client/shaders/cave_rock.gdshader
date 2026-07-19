shader_type spatial;
// Cave rock: warm sandstone striations in the WoW register — broad banded
// strata warped by low-frequency noise, sediment floors, all procedural
// ("as code": no textures, the look is arithmetic).
//
// The mesh bakes coarse shading into COLOR (band tint, floor blend, torch-
// side warmth); this shader adds the fine strata the vertex density cannot
// carry. Bands run along world Y so they read as geological layers whatever
// the wall's shape.

uniform vec3 band_a: source_color = vec3(0.62, 0.45, 0.28);
uniform vec3 band_b: source_color = vec3(0.42, 0.28, 0.17);
uniform vec3 band_c: source_color = vec3(0.72, 0.58, 0.40);
uniform float band_frequency = 1.1;
uniform float warp_strength = 1.6;
uniform float roughness_value: hint_range(0.0, 1.0) = 0.96;

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
	float band = value_noise(vec3(0.0, layer * 2.1, 0.0));
	float vein = fbm(world_pos * vec3(0.05, 0.9, 0.05) + vec3(warp));
	vec3 strata = mix(band_a, band_b, smoothstep(0.25, 0.75, band));
	strata = mix(strata, band_c, smoothstep(0.55, 0.95, vein) * 0.55);

	// Floors silt over: blend toward the baked sediment color from below.
	vec3 n = normalize(world_normal);
	float floor_mix = smoothstep(0.45, 0.8, n.y);
	vec3 base = COLOR.rgb;
	vec3 interior = mix(base * strata * 1.9, base, floor_mix * 0.75);

	// Weathered exterior, weighted by the baked exposure mask. At mask 0 every
	// mix below returns its interior argument exactly and NORMAL is never
	// written, so cave walls render bit-for-bit as before this block existed.
	float sky = COLOR.a;

	float dist = length(world_pos - CAMERA_POSITION_WORLD);
	float detail = 1.0 - smoothstep(detail_fade_start, detail_fade_end, dist);

	// The same geological bedding, bleached and cooled: outdoor rock keeps its
	// layers but an age of sun and ash has taken the warm cave glow out.
	vec3 wstrata = mix(weathered_a, weathered_b, smoothstep(0.25, 0.75, band));
	wstrata = mix(wstrata, weathered_c, smoothstep(0.55, 0.95, vein) * 0.4);
	// The baked tint keeps its variation but not its warmth outdoors.
	vec3 wbase = mix(vec3(dot(base, vec3(0.3333))), base, 0.45);

	// Scour: streaks run DOWN a face, so the noise is stretched along Y and
	// the darkening applies where the rock stands steep.
	float steep = clamp(1.0 - n.y, 0.0, 1.0);
	float streak = fbm(world_pos * vec3(1.6, 0.22, 1.6));
	float scour = smoothstep(0.42, 0.78, streak) * smoothstep(0.35, 0.75, steep);

	// Ash settles where the rock lies back — the same ash the ground wears, so
	// the massif meets the Reach in one material family. A broad drift term
	// wanders the boundary the way the terrain shader wanders its rock line.
	float drift = fbm(world_pos * 0.16);
	float ash_mix = smoothstep(0.3, 0.75, n.y) * smoothstep(0.3, 0.7, drift + 0.15);

	// Grain: multi-scale brightness/roughness break-up plus a perturbed
	// normal — grazing light picking out grit is what stops a smooth SDF dome
	// reading as plastic under this world's low sun.
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
	ROUGHNESS = mix(roughness_value, ext_roughness - 0.08 * (g0 - 0.5) * detail, sky);
	SPECULAR = mix(0.5, 0.2, sky);
	if (sky > 0.001) {
		vec3 perturbed = normalize(n + grad * ext_bump_strength * sky * detail);
		NORMAL = normalize((VIEW_MATRIX * vec4(perturbed, 0.0)).xyz);
	}
}
