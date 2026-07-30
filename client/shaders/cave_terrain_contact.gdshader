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
// Same unresolved-groove occlusion as terrain.gdshader (#539), and necessarily
// the same default: this band blends into that ground, so a contact darkening
// its sub-pixel seams harder or softer than the ground would draw a visible
// join exactly where the two meet.
uniform float seam_cavity: hint_range(0.0, 8.0) = 3.5;
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

// One cell's FINISHED surface — the contact band's copy of the ground's
// `plate_cell_surface`, kept in the same shape and the same order for the same
// reason (scorch before the crack, the roughness offsets and clamp before the
// crack pushes toward 1). A triple junction needs three of these (#499), and
// three inline copies of a load-bearing ordering is exactly the drift this
// file's parity test exists to catch.
void plate_cell_surface(
		vec4 sub_cell, float slab_cell, float sheet, float rock_mix,
		float scorch_k, float crack_in, float region_rough, float grain,
		float detail,
		out vec3 surface_out, out float rough_out, out float crack_out) {
	float mask = sheet * slab_cell;
	float exposure = max(rock_mix, mask);
	crack_out = crack_in * mask;
	surface_out = mix(
		mix(ash_color, mix(rock_color, sub_cell.rgb, mask), exposure),
		scorch_color, scorch_k) * (1.0 - crack_out * crack_darkness);
	rough_out = mix(
		clamp(mix(ash_roughness, mix(rock_roughness, sub_cell.a, mask), exposure)
			+ region_rough - 0.06 * (grain - 0.5) * detail, 0.0, 1.0),
		1.0, crack_out * 0.5);
}

void fragment() {
	vec3 n = normalize(terrain_world_normal);
	float slope = clamp(1.0 - n.y, 0.0, 1.0);
	float dist = length(terrain_world_pos - CAMERA_POSITION_WORLD);
	float detail = 1.0 - smoothstep(detail_fade_start, detail_fade_end, dist);
	float drift = terrain_ground_noise(terrain_world_pos.xz, drift_scale);
	float grain = terrain_ground_noise(terrain_world_pos.xz, grain_scale);

	// Same coherent uniform-gated plate path as terrain.gdshader. Default-off
	// pays no partition search; opt-in resolves the identical cells, substances,
	// contacts and crack relief at the same world XZ.
	vec2 plate_uv = terrain_world_pos.xz * plate_scale;
	vec2 plate_id = vec2(0.0);
	vec2 plate_id2 = vec2(0.0);
	vec2 plate_id3 = vec2(0.0);
	float f1 = 0.0;
	float f2 = 1.0;
	float f3 = 1.0;
	float f4 = 1.0;
	float plate_resolved = 0.0;
	float plate_edge_w = 0.0;
	// Coverage split across the three nearest plates, (owning, second, third).
	// The third is 0.0 everywhere except at a triple junction (#499).
	vec3 plate_w = vec3(1.0, 0.0, 0.0);
	// Junction authority plus a separate fourth-cell performance gate (#573).
	float plate_window_w = 0.0;
	float plate_window_gate = 0.0;
	vec4 sub = vec4(rock_color, rock_roughness);
	vec4 sub_nb = vec4(rock_color, rock_roughness);
	vec4 sub_nb3 = vec4(rock_color, rock_roughness);
	float is_slab2 = 0.0;
	float is_slab3 = 0.0;
	float crack = 0.0;
	float plate_fw = 0.0;
	float crack_fw = 0.0;
	// Hoisted for the crack relief below, as terrain.gdshader does: the seam
	// filter and the boundary average are keyed on the same footprint.
	float edge_fw = 0.0;
	vec2 plate_c1 = vec2(0.0);
	vec2 plate_c2 = vec2(0.0);
	vec2 plate_c3 = vec2(0.0);
	if (plates_enabled) {
		terrain_plates(plate_uv, plate_id, f1, f2, plate_c1, plate_c2, plate_id2,
			f3, plate_c3, plate_id3, f4);
		plate_fw = max(fwidth(plate_uv.x), fwidth(plate_uv.y));
		plate_resolved = 1.0 - smoothstep(0.30, 0.85, plate_fw);
		crack_fw = fwidth(f2 - f1);
		// Same analytic footprint as terrain.gdshader, for the same reason:
		// `fwidth(f2 - f1)` collapses on a quad straddling the boundary,
		// because that quantity is a cusp there rather than a signed
		// coordinate. grad(f2 - f1) = normalize(uv - c2) - normalize(uv - c1).
		vec2 plate_uv_dx = dFdx(plate_uv);
		vec2 plate_uv_dy = dFdy(plate_uv);
		edge_fw = terrain_plate_separator_footprint(
			plate_uv, plate_c1, plate_c2, plate_c3,
			f1, f2, f3, f4, plate_fw, plate_resolved,
			plate_uv_dx, plate_uv_dy);
		plate_edge_w = terrain_plate_edge_blend(f1, f2, edge_fw * 0.5);
		// ...and the same three-way coverage split, keyed on the isotropic
		// `plate_fw` for the reason the function gives. The ground and this band
		// have to agree about WHICH plates they are blending as well as how much,
		// or they part company at a triple junction that straddles the contact.
		plate_w = terrain_plate_blend_weights(f1, f2, f3, plate_edge_w, plate_fw);
		plate_window_w = terrain_plate_window_junction(f2, f3, plate_fw);
		plate_window_gate = plate_resolved * terrain_plate_window_reachable(
			f1, f4, plate_fw);
		// The same footprint average as the ground (#306). This path exists to
		// resolve the IDENTICAL substance at the same world XZ, so leaving the
		// step unfiltered here would reintroduce the crawl at the cave contact
		// and disagree with the ground it has to meet.
		sub = terrain_plate_substance(
			plate_id, rock_color, rock_roughness,
			plate_basalt, plate_ferric, plate_pale);
		sub_nb = terrain_plate_substance(
			plate_id2, rock_color, rock_roughness,
			plate_basalt, plate_ferric, plate_pale);
		sub_nb3 = terrain_plate_substance(
			plate_id3, rock_color, rock_roughness,
			plate_basalt, plate_ferric, plate_pale);
		vec3 mean_col = rock_color * 0.38 + plate_basalt * 0.28
			+ plate_ferric * 0.20 + plate_pale * 0.14;
		float mean_rough = rock_roughness * 0.38 + 0.88 * 0.28
			+ 0.72 * 0.20 + 0.94 * 0.14;
		sub = mix(vec4(mean_col, mean_rough), sub, plate_resolved);
		sub_nb = mix(vec4(mean_col, mean_rough), sub_nb, plate_resolved);
		sub_nb3 = mix(vec4(mean_col, mean_rough), sub_nb3, plate_resolved);
		is_slab2 = step(0.60, terrain_hash3(vec3(plate_id2 * 2.3, 19.0)));
		is_slab3 = step(0.60, terrain_hash3(vec3(plate_id3 * 2.3, 19.0)));
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
	// Same split as the ground (#306): the albedo takes the footprint average of
	// the slab mask, the relief keeps the binary one. This band has to resolve
	// the IDENTICAL substance as the ground it meets, so a soft mask there and a
	// hard one here would part company along the contact — the drift this file's
	// parity test exists to catch.
	// Per-cell masks, then a blend of PRODUCTS (see terrain.gdshader): blending
	// substance and mask separately and multiplying afterwards would show a
	// quarter of a bare neighbour's substance at a slab-to-bare contact.
	float slab_own = mix(0.40, is_slab, plate_resolved);
	float slab_nb = mix(0.40, is_slab2, plate_resolved);
	float slab_nb3 = mix(0.40, is_slab3, plate_resolved);
	// A weighted average over the three candidates. `plate_w` sums to one, and
	// away from a junction it is `(1 - plate_edge_w, plate_edge_w, 0)` — the
	// previous two-cell blend exactly.
	float pair_slab = mix(slab_own, slab_nb, plate_edge_w);
	float slab = slab_own * plate_w.x + slab_nb * plate_w.y
		+ slab_nb3 * plate_w.z;
	// Preserve the normalized share of source cells that drew a slab for the
	// nonlinear seam-cavity composition below. The amplitude is clamped and
	// squared per cell, so it cannot be reconstructed from averaged `slab`.
	float plate_window_slab_share = 0.0;
	// Mirror the ground shader's symmetric sum over every cell that can carry
	// footprint weight. During the active 0.30–0.85 resolution fade that support
	// fits inside this 5x5 domain; outside it `plate_window_gate` is already zero.
	// It has authority only where the fourth candidate enters this fragment's
	// footprint. The generalized answer is composed from the same pairwise base,
	// so it converges to the established three-way result before the performance
	// gate skips the window.
	if (plates_enabled && plate_window_gate > 0.0 && plate_window_w > 0.0) {
		vec2 window_base = floor(plate_uv);
		float window_total = 0.0;
		float window_slab = 0.0;
		float window_slab_share = 0.0;
		for (int j = -2; j <= 2; j++) {
			for (int i = -2; i <= 2; i++) {
				vec2 cell = window_base + vec2(float(i), float(j));
				vec2 jitter = vec2(
					terrain_hash3(vec3(cell, 0.0)),
					terrain_hash3(vec3(cell, 7.0)));
				vec2 centre = cell + 0.15 + 0.7 * jitter;
				float d = length(plate_uv - centre);
				float weight = terrain_plate_window_weight(d, f1, plate_fw);
				float cell_is_slab = step(
					0.60, terrain_hash3(vec3(cell * 2.3, 19.0)));
				float cell_slab = mix(
					0.40,
					cell_is_slab,
					plate_resolved);
				window_slab += cell_slab * weight;
				window_slab_share += cell_is_slab * weight;
				window_total += weight;
			}
		}
		plate_window_slab_share =
			window_slab_share / max(window_total, 1e-6);
		slab = mix(
			pair_slab,
			window_slab / max(window_total, 1e-6),
			plate_window_w);
	}
	float plate_mask = sheet * slab;
	float plate_mask_relief = sheet * slab_own;
	// The neighbour cells' gates, for the seam variance only — same split as
	// terrain.gdshader: the mean keeps the owning cell's binary gate, the
	// variance is split across all three candidates, because the variance peaks
	// exactly where the mean's hard step is harmless and so lands on the peak
	// instead of on nothing.
	float plate_mask_relief_nb = sheet * slab_nb;
	float plate_mask_relief_nb3 = sheet * slab_nb3;
	float rock_exposure = max(rock_mix, plate_mask);

	vec3 base = vec3(UV, UV2.x);
	float plate_gate = plates_enabled ? 1.0 : 0.0;
	float eff_plate = plate_mask * plate_gate;
	// Each cell's FINAL surface composed before averaging, as terrain.gdshader
	// does and for the same reason: the ash-vs-stone choice is driven by the
	// mask, so averaging before that resolve shows a material neither cell has.
	float eff_exposure = mix(rock_mix, rock_exposure, plate_gate);

	// Hoisted above the branch: both paths' roughness needs it.
	float region_rough = UV2.y - ash_roughness;
	vec3 surface;
	float stone_rough;
	// Same opt-in branch and same per-cell ordering as terrain.gdshader: scorch
	// is affine with a non-zero constant, so the crack must follow it rather
	// than precede it, and the roughness offsets and clamp keep their original
	// order too. Grain and lip below are pure multiplies and do commute.
	float scorch_k = smoothstep(0.62, 0.95, drift) * 0.35 * (1.0 - rock_mix);
	if (plates_enabled) {
	vec3 surf_own;
	vec3 surf_nb;
	vec3 surf_nb3;
	float rough_own;
	float rough_nb;
	float rough_nb3;
	float crack_own;
	float crack_nb;
	float crack_nb3;
	float plate_crack_field = crack;
	plate_cell_surface(sub, slab_own, sheet, rock_mix, scorch_k, plate_crack_field,
		region_rough, grain, detail, surf_own, rough_own, crack_own);
	plate_cell_surface(sub_nb, slab_nb, sheet, rock_mix, scorch_k,
		plate_crack_field,
		region_rough, grain, detail, surf_nb, rough_nb, crack_nb);
	// The third candidate, which carries weight only at a triple junction.
	plate_cell_surface(sub_nb3, slab_nb3, sheet, rock_mix, scorch_k,
		plate_crack_field,
		region_rough, grain, detail, surf_nb3, rough_nb3, crack_nb3);
	// A weighted average of the three finished surfaces, as the ground does.
	vec3 pair_surface = mix(surf_own, surf_nb, plate_edge_w);
	float pair_rough = mix(rough_own, rough_nb, plate_edge_w);
	float pair_crack = mix(crack_own, crack_nb, plate_edge_w);
	surface = surf_own * plate_w.x + surf_nb * plate_w.y + surf_nb3 * plate_w.z;
	stone_rough = rough_own * plate_w.x + rough_nb * plate_w.y
		+ rough_nb3 * plate_w.z;
	crack = crack_own * plate_w.x + crack_nb * plate_w.y
		+ crack_nb3 * plate_w.z;
	if (plate_window_gate > 0.0 && plate_window_w > 0.0) {
		vec2 window_base = floor(plate_uv);
		vec3 window_surface = vec3(0.0);
		float window_rough = 0.0;
		float window_crack = 0.0;
		float window_total = 0.0;
		vec3 window_mean_col = rock_color * 0.38 + plate_basalt * 0.28
			+ plate_ferric * 0.20 + plate_pale * 0.14;
		float window_mean_rough = rock_roughness * 0.38 + 0.88 * 0.28
			+ 0.72 * 0.20 + 0.94 * 0.14;
		vec4 window_mean = vec4(window_mean_col, window_mean_rough);
		for (int j = -2; j <= 2; j++) {
			for (int i = -2; i <= 2; i++) {
				vec2 cell = window_base + vec2(float(i), float(j));
				vec2 jitter = vec2(
					terrain_hash3(vec3(cell, 0.0)),
					terrain_hash3(vec3(cell, 7.0)));
				vec2 centre = cell + 0.15 + 0.7 * jitter;
				float d = length(plate_uv - centre);
				float weight = terrain_plate_window_weight(d, f1, plate_fw);
				vec4 cell_sub = mix(
					window_mean,
					terrain_plate_substance(
						cell, rock_color, rock_roughness,
						plate_basalt, plate_ferric, plate_pale),
					plate_resolved);
				float cell_slab = mix(
					0.40,
					step(0.60, terrain_hash3(vec3(cell * 2.3, 19.0))),
					plate_resolved);
				vec3 cell_surface;
				float cell_rough;
				float cell_crack;
				plate_cell_surface(
					cell_sub, cell_slab, sheet, rock_mix, scorch_k,
					plate_crack_field, region_rough, grain, detail,
					cell_surface, cell_rough, cell_crack);
				window_surface += cell_surface * weight;
				window_rough += cell_rough * weight;
				window_crack += cell_crack * weight;
				window_total += weight;
			}
		}
		float inverse_window_total = 1.0 / max(window_total, 1e-6);
		surface = mix(
			pair_surface,
			window_surface * inverse_window_total,
			plate_window_w);
		stone_rough = mix(
			pair_rough,
			window_rough * inverse_window_total,
			plate_window_w);
		crack = mix(
			pair_crack,
			window_crack * inverse_window_total,
			plate_window_w);
	}
	} else {
	surface = mix(mix(ash_color, rock_color, rock_mix), scorch_color, scorch_k);
	stone_rough = clamp(mix(ash_roughness, rock_roughness, rock_mix)
		+ region_rough - 0.06 * (grain - 0.5) * detail, 0.0, 1.0);
	crack = 0.0;
	}
	surface *= 0.93 + 0.14 * mix(0.5, grain, detail);
	float lip = (1.0 - smoothstep(0.0, aw * 4.0, abs(ash_edge)))
		* (1.0 - smoothstep(0.30, 0.85, fwidth(ash_edge)));
	surface *= 1.0 + lip * lip_lift * plate_gate;

	ALBEDO = base * surface * 2.0;
	// `stone_rough` already carries the per-cell resolve, the region/grain
	// offsets, the clamp and the crack — all in the original order.
	ROUGHNESS = stone_rough;
	SPECULAR = 0.18;

	float e = 0.22;
	float h0 = terrain_ground_noise(terrain_world_pos.xz, grain_scale);
	float hx = terrain_ground_noise(terrain_world_pos.xz + vec2(e, 0.0), grain_scale);
	float hz = terrain_ground_noise(terrain_world_pos.xz + vec2(0.0, e), grain_scale);
	vec2 grad = vec2(0.0);
	// Same seam-slope variance as terrain.gdshader, carried as cavity darkening
	// below. This band blends into that ground, so a contact whose seams
	// stopped reading at the distance the ground's still read would draw a
	// visible join exactly where the two meet.
	float seam_slope_var = 0.0;
	if (plates_enabled) {
		// Same closed-form crack gradient as terrain.gdshader, for the same
		// reason: differencing the crack field samples a step narrower than a
		// pixel past a few metres, which IS the aliasing rather than a reading
		// of it. grad(f2 - f1) = normalize(uv - c2) - normalize(uv - c1).
		vec2 d1 = plate_uv - plate_c1;
		vec2 d2 = plate_uv - plate_c2;
		vec2 gsep = d2 * inversesqrt(max(dot(d2, d2), 1e-12))
			- d1 * inversesqrt(max(dot(d1, d1), 1e-12));
		float cw_relief = max(crack_width, 1e-6);
		// Same footprint-integrated groove as terrain.gdshader, for the same
		// reason and necessarily the same form: the relief was read at the
		// pixel centre while the thing being read (the crack profile's slope,
		// which peaks at w/2 and is zero at both ends) is finer than the mark
		// the guards below are keyed on. The mean tilt is what a normal can
		// carry; the variance about it is what a normal cannot, because a
		// pixel spanning a whole groove sees its two walls cancel. The full
		// derivation, the top-hat justification and the limits are in
		// terrain.gdshader — this is the same integral over the same profile.
		float amp_scale = length(gsep) * (1.5 / cw_relief) * plate_scale;
		float amp = min(amp_scale * plate_mask_relief, 0.4);
		float amp_nb = min(amp_scale * plate_mask_relief_nb, 0.4);
		float amp_nb3 = min(amp_scale * plate_mask_relief_nb3, 0.4);
		float seam_h = max(edge_fw, 1e-6);
		float half_h = 0.5 * seam_h;
		float s_sep = f2 - f1;
		float prof = (min(s_sep + half_h, cw_relief)
			- min(abs(s_sep - half_h), cw_relief)) / seam_h;
		float mean_tilt = amp * prof;
		float covered = clamp(max(min(s_sep + half_h, cw_relief)
			- max(s_sep - half_h, -cw_relief), 0.0) / seam_h, 0.0, 1.0);
		float spread = max(covered - prof * prof, 0.0);
		// Same three-candidate baseline as terrain.gdshader, over the same
		// weights every per-cell quantity above uses. A pixel straddling a
		// slab-to-bare contact contains all of those cells' seams, and gating the
		// integral by whichever cell owns the pixel centre steps the cavity as
		// that centre crosses. `plate_w` rather than a pairwise mix keeps the
		// triple junction continuous; the branch below then generalizes the
		// per-cell factor through the same symmetric window as the surface.
		float seam_amp_sq = amp * amp * plate_w.x
			+ amp_nb * amp_nb * plate_w.y + amp_nb3 * amp_nb3 * plate_w.z;
		if (plate_window_gate > 0.0 && plate_window_w > 0.0) {
			// The resolved cell has one of two slab states. Their normalized
			// window share lets this nonlinear, already-clamped square use the
			// existing 5x5 work rather than repeating the hash loop.
			float low_amp = min(
				amp_scale * sheet * mix(0.40, 0.0, plate_resolved), 0.4);
			float high_amp = min(
				amp_scale * sheet * mix(0.40, 1.0, plate_resolved), 0.4);
			float window_amp_sq = mix(
				low_amp * low_amp,
				high_amp * high_amp,
				plate_window_slab_share);
			float pair_amp_sq = amp * amp * (1.0 - plate_edge_w)
				+ amp_nb * amp_nb * plate_edge_w;
			seam_amp_sq = mix(
				pair_amp_sq,
				window_amp_sq,
				plate_window_w);
		}
		seam_slope_var = seam_amp_sq * spread;
		// Same read-preserving junction gain as the ground. It has zero
		// authority where the third candidate has no local coverage.
		float junction_read_authority = terrain_plate_covered_junction(
			f1, f2, f3, plate_fw);
		float junction_read_gain = terrain_plate_junction_read_gain(
			junction_read_authority);
		mean_tilt *= junction_read_gain;
		seam_slope_var *= junction_read_gain * junction_read_gain;
		vec2 ghat = gsep * inversesqrt(max(dot(gsep, gsep), 1e-12));
		grad = -ghat * mean_tilt;
		grad *= 1.0 - smoothstep(0.30, 0.85, plate_fw);
		// Same crack-footprint dissolve as terrain.gdshader, for the same
		// reason: `plate_fw` is a whole plate's footprint and cannot stand in
		// for the much narrower seam whose relief this is.
		grad *= 1.0 - smoothstep(0.7, 1.3, crack_fw * 1.2 / max(crack_width, 1e-6));
		// Same seam-slope ceiling as terrain.gdshader, for the same reason and
		// necessarily the same number: this band blends into that ground, so a
		// contact whose seams may tilt further than the ground's would shimmer
		// exactly where the two meet.
		float grad_len = length(grad);
		grad = grad_len > 0.4 ? grad * (0.4 / grad_len) : grad;
		// Same plate-resolution cutoff on the variance as terrain.gdshader,
		// and the same two guards deliberately left off it: the crack fade and
		// the slope ceiling bound what the NORMAL may claim, and the read they
		// give up is what this term carries instead. Squared, because it is a
		// variance of the amplitude the cutoff scales.
		seam_slope_var *= plate_resolved * plate_resolved;
	}
	vec3 bump = vec3(
		(h0 - hx) * bump_strength + grad.x * crack_relief,
		0.0,
		(h0 - hz) * bump_strength + grad.y * crack_relief) * detail;
	vec3 perturbed = normalize(n + bump);
	NORMAL = normalize((VIEW_MATRIX * vec4(perturbed, 0.0)).xyz);
	// Same cavity darkening as terrain.gdshader: the sub-pixel groove has no
	// net tilt but is not flat, and what it still does is occlude. Roughness is
	// the textbook home for a filtered normal distribution and was measured
	// INERT on this surface (#306), so the residual read is carried where a
	// diffuse surface's self-occlusion actually shows. Set from `stone_rough`
	// and `surface` above; the darkening waits for the relief block, which is
	// where the second moment is computed.
	float seam_gain = crack_relief * detail;
	float seam_var = seam_slope_var * seam_gain * seam_gain;
	ALBEDO *= 1.0 / max(1.0 + seam_cavity * seam_var, 1e-3);
	ALPHA = COLOR.a;
}
