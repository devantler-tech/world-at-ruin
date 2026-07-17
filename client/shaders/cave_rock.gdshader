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
	float floor_mix = smoothstep(0.45, 0.8, normalize(world_normal).y);
	vec3 base = COLOR.rgb;
	ALBEDO = mix(base * strata * 1.9, base, floor_mix * 0.75);
	ROUGHNESS = roughness_value;
}
