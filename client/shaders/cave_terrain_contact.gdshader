shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// Render-only transition between the starter cave's weathered exterior and
// the exact local ground substance sampled by WorldGen. UV.xy + UV2.x carry
// the ground's baked RGB, UV2.y its loose-ash roughness, COLOR.rg its rendered
// triangle normal, COLOR.b its height, and COLOR.a the contact weight.
//
// This declares the same surface parameters as terrain.gdshader and consumes
// the shared procedural fields below. The cave foot therefore receives the
// ground's drift, grain, slope/scorch response, normal relief, and opted-in
// plate substances—not a flat tint approximation.

uniform vec3 ash_color: source_color = vec3(0.50, 0.46, 0.40);
uniform vec3 rock_color: source_color = vec3(0.30, 0.27, 0.25);
uniform vec3 scorch_color: source_color = vec3(0.17, 0.15, 0.14);
uniform float drift_scale = 0.055;
uniform float grain_scale = 6.2;
uniform float bump_strength: hint_range(0.0, 3.0) = 0.34;
uniform float rock_slope: hint_range(0.0, 1.0) = 0.34;
uniform float ash_roughness: hint_range(0.0, 1.0) = 0.97;
uniform float rock_roughness: hint_range(0.0, 1.0) = 0.78;
uniform float detail_fade_start = 45.0;
uniform float detail_fade_end = 130.0;

uniform vec3 plate_basalt: source_color = vec3(0.22, 0.21, 0.22);
uniform vec3 plate_ferric: source_color = vec3(0.42, 0.26, 0.18);
uniform vec3 plate_pale: source_color = vec3(0.54, 0.51, 0.45);
uniform bool plates_enabled = false;
uniform float plate_scale = 0.85;
uniform float crack_width: hint_range(0.001, 0.3) = 0.032;
uniform float crack_darkness: hint_range(0.0, 1.0) = 0.09;
uniform float crack_relief: hint_range(0.0, 3.0) = 1.1;
uniform float ash_contact: hint_range(0.002, 0.3) = 0.035;
uniform float lip_lift: hint_range(0.0, 1.0) = 0.18;

#include "res://shaders/terrain_surface.gdshaderinc"

varying vec3 terrain_world_pos;
varying vec3 terrain_world_normal;

void vertex() {
	// Keep the overlay just above its source surface. The displacement reaches
	// 4 mm only at full contact and vanishes with the blend, avoiding z-fighting
	// without moving the generated rock or its collision.
	VERTEX += NORMAL * (0.004 * COLOR.a);

	vec4 cave_world = MODEL_MATRIX * vec4(VERTEX, 1.0);
	vec2 ground_xz = COLOR.rg * 2.0 - 1.0;
	float ground_ny = sqrt(max(0.0, 1.0 - dot(ground_xz, ground_xz)));
	terrain_world_normal = normalize(vec3(ground_xz.x, ground_ny, ground_xz.y));
	terrain_world_pos = vec3(cave_world.x, (COLOR.b - 0.5) * 64.0, cave_world.z);
}

void fragment() {
	vec3 n = normalize(terrain_world_normal);
	float slope = clamp(1.0 - n.y, 0.0, 1.0);
	float dist = length(terrain_world_pos - CAMERA_POSITION_WORLD);
	float detail = 1.0 - smoothstep(detail_fade_start, detail_fade_end, dist);
	float drift = terrain_ground_noise(terrain_world_pos.xz, drift_scale);
	float grain = terrain_ground_noise(terrain_world_pos.xz, grain_scale);

	// Same coherent uniform-gated plate path as terrain.gdshader. Default-off
	// pays no nine-cell search; opt-in resolves the identical cells, substances,
	// contacts and crack relief at the same world XZ.
	vec2 plate_uv = terrain_world_pos.xz * plate_scale;
	vec2 plate_id = vec2(0.0);
	float f1 = 0.0;
	float f2 = 1.0;
	float plate_resolved = 0.0;
	vec4 sub = vec4(rock_color, rock_roughness);
	float crack = 0.0;
	float plate_fw = 0.0;
	if (plates_enabled) {
		terrain_plates(plate_uv, plate_id, f1, f2);
		plate_fw = max(fwidth(plate_uv.x), fwidth(plate_uv.y));
		plate_resolved = 1.0 - smoothstep(0.30, 0.85, plate_fw);
		sub = terrain_plate_substance(
			plate_id,
			rock_color,
			rock_roughness,
			plate_basalt,
			plate_ferric,
			plate_pale);
		vec3 mean_col = rock_color * 0.38 + plate_basalt * 0.28
			+ plate_ferric * 0.20 + plate_pale * 0.14;
		float mean_rough = rock_roughness * 0.38 + 0.88 * 0.28
			+ 0.72 * 0.20 + 0.94 * 0.14;
		sub = mix(vec4(mean_col, mean_rough), sub, plate_resolved);
		float crack_fw = fwidth(f2 - f1);
		float cw = max(crack_width, crack_fw * 1.2);
		crack = 1.0 - smoothstep(0.0, cw, f2 - f1);
		crack *= 1.0 - smoothstep(0.30, 0.85, plate_fw);
	}

	float ash_edge = slope + (drift - 0.5) * 0.22 - rock_slope;
	float aw = clamp(
		max(ash_contact, fwidth(ash_edge) * 1.2),
		ash_contact,
		max(ash_contact, 0.25));
	float rock_mix = plates_enabled
		? smoothstep(-aw, aw, ash_edge)
		: smoothstep(
			rock_slope - 0.12,
			rock_slope + 0.12,
			slope + (drift - 0.5) * 0.22);

	float exposed_edge = drift - 0.47;
	float ew = clamp(
		max(ash_contact, fwidth(exposed_edge) * 1.2),
		ash_contact,
		max(ash_contact, 0.25));
	float sheet = clamp(smoothstep(-ew, ew, exposed_edge) + rock_mix, 0.0, 1.0);
	float slab_pick = terrain_hash3(vec3(plate_id * 2.3, 19.0));
	float is_slab = step(0.60, slab_pick);
	float slab = mix(0.40, is_slab, plate_resolved);
	float plate_mask = sheet * slab;
	float rock_exposure = max(rock_mix, plate_mask);

	vec3 base = vec3(UV, UV2.x);
	float plate_gate = plates_enabled ? 1.0 : 0.0;
	float eff_plate = plate_mask * plate_gate;
	vec3 stone_rgb = mix(rock_color, sub.rgb, eff_plate);
	float stone_rough = mix(rock_roughness, sub.a, eff_plate);
	float eff_exposure = mix(rock_mix, rock_exposure, plate_gate);
	crack *= eff_plate;

	vec3 surface = mix(ash_color, stone_rgb, eff_exposure);
	surface = mix(
		surface,
		scorch_color,
		smoothstep(0.62, 0.95, drift) * 0.35 * (1.0 - rock_mix));
	surface *= 0.93 + 0.14 * mix(0.5, grain, detail);
	float lip = (1.0 - smoothstep(0.0, aw * 4.0, abs(ash_edge)))
		* (1.0 - smoothstep(0.30, 0.85, fwidth(ash_edge)));
	surface *= 1.0 + lip * lip_lift * plate_gate;
	surface *= 1.0 - crack * crack_darkness;

	ALBEDO = base * surface * 2.0;
	float region_rough = UV2.y - ash_roughness;
	ROUGHNESS = clamp(
		mix(ash_roughness, stone_rough, eff_exposure) + region_rough
			- 0.06 * (grain - 0.5) * detail,
		0.0,
		1.0);
	ROUGHNESS = mix(ROUGHNESS, 1.0, crack * 0.5);
	SPECULAR = 0.18;

	float e = 0.22;
	float h0 = terrain_ground_noise(terrain_world_pos.xz, grain_scale);
	float hx = terrain_ground_noise(terrain_world_pos.xz + vec2(e, 0.0), grain_scale);
	float hz = terrain_ground_noise(terrain_world_pos.xz + vec2(0.0, e), grain_scale);
	vec2 grad = vec2(0.0);
	if (plates_enabled) {
		float crack_fixed = 1.0 - smoothstep(0.0, crack_width, f2 - f1);
		vec2 duvdx = dFdx(plate_uv);
		vec2 duvdy = dFdy(plate_uv);
		float dcdx = dFdx(crack_fixed);
		float dcdy = dFdy(crack_fixed);
		float det = duvdx.x * duvdy.y - duvdx.y * duvdy.x;
		float safe_det = abs(det) < 1e-8 ? 1e-8 : det;
		grad = vec2(
			dcdx * duvdy.y - dcdy * duvdx.y,
			dcdy * duvdx.x - dcdx * duvdy.x
		) / safe_det * plate_scale * plate_mask;
		grad *= 1.0 - smoothstep(0.30, 0.85, plate_fw);
		float grad_len = length(grad);
		grad = grad_len > 1.5 ? grad * (1.5 / grad_len) : grad;
	}
	vec3 bump = vec3(
		(h0 - hx) * bump_strength + grad.x * crack_relief,
		0.0,
		(h0 - hz) * bump_strength + grad.y * crack_relief) * detail;
	vec3 perturbed = normalize(n + bump);
	NORMAL = normalize((VIEW_MATRIX * vec4(perturbed, 0.0)).xyz);
	ALPHA = COLOR.a;
}
