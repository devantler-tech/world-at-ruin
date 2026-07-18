shader_type spatial;
// Ashfall ground: wind-drifted ash over exposed rock, entirely procedural
// ("as code": no textures, the look is arithmetic — same idiom as
// cave_rock.gdshader, which solved this problem indoors).
//
// The terrain mesh bakes a broad ash/rock tint into COLOR at vertex density
// (one value per 1.7 m quad). That is far too coarse to read as a SURFACE: at
// walking distance the ground was a smooth flat plane, which is what made the
// Reach read as a beige backdrop with objects placed on it rather than ground
// a disaster happened to.
//
// Three things are added here, in order of how much they matter at this
// world's low sun angle:
//   1. NORMAL perturbation — grazing light picking out grain is the single
//      biggest cue that a surface has substance. A flat normal cannot produce
//      it no matter how the albedo is tinted.
//   2. Slope-aware material — ash and dust settle on flats and wash off steep
//      faces, exposing coarser rock. Real ground changes with its angle, and
//      that change is what stops a heightfield reading as a painted mesh.
//   3. Multi-scale albedo/roughness break-up — drifts at metres, grain at
//      centimetres, so the ground neither tiles nor sits at one flat value.

uniform vec3 ash_color: source_color = vec3(0.50, 0.46, 0.40);
uniform vec3 rock_color: source_color = vec3(0.30, 0.27, 0.25);
uniform vec3 scorch_color: source_color = vec3(0.17, 0.15, 0.14);
// Metres per drift cell — the broad patchwork of banked ash and swept ground.
uniform float drift_scale = 0.055;
// Fine grain frequency. High enough to read as grit underfoot, low enough not
// to alias into noise at distance (the fade below handles the far field).
uniform float grain_scale = 6.2;
uniform float bump_strength: hint_range(0.0, 3.0) = 0.34;
// Above this slope (1 = vertical) the face is treated as scoured rock.
uniform float rock_slope: hint_range(0.0, 1.0) = 0.34;
uniform float ash_roughness: hint_range(0.0, 1.0) = 0.97;
uniform float rock_roughness: hint_range(0.0, 1.0) = 0.78;
// Distance over which fine detail fades out, so the far field stays calm
// instead of shimmering.
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

// Ground detail sampled on the XZ plane: the surface is a heightfield, so
// planar sampling avoids the vertical smearing a 3D sample gives on slopes.
float ground_noise(vec2 xz, float scale) {
	return fbm(vec3(xz.x, 0.0, xz.y) * scale);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 n = normalize(world_normal);
	// 0 on the flat, 1 on a vertical face.
	float slope = clamp(1.0 - n.y, 0.0, 1.0);

	// Fade fine detail with distance so the far field stays calm.
	float dist = length(world_pos - CAMERA_POSITION_WORLD);
	float detail = 1.0 - smoothstep(detail_fade_start, detail_fade_end, dist);

	// Broad drifts, then grain on top of them.
	float drift = ground_noise(world_pos.xz, drift_scale);
	float grain = ground_noise(world_pos.xz, grain_scale);

	// Ash banks where the ground lies flat and where drifts pile it; rock is
	// scoured bare on the steeper faces. The drift term perturbs the threshold
	// so the boundary wanders instead of following a clean contour line.
	float rock_mix = smoothstep(rock_slope - 0.12, rock_slope + 0.12,
		slope + (drift - 0.5) * 0.22);

	// The vertex tint stays the base layer (as cave_rock does with COLOR), so
	// the world's existing ash/rock palette and its variation survive.
	vec3 base = COLOR.rgb;
	vec3 surface = mix(ash_color, rock_color, rock_mix);
	// Scorch pools in the low, sheltered drifts — the Ruin's burn, not shadow.
	surface = mix(surface, scorch_color, smoothstep(0.62, 0.95, drift) * 0.35 * (1.0 - rock_mix));
	// Grain modulates brightness slightly; kept subtle so it reads as texture
	// rather than dirt sprayed over the frame.
	surface *= 0.93 + 0.14 * mix(0.5, grain, detail);

	ALBEDO = base * surface * 2.0;
	ROUGHNESS = mix(ash_roughness, rock_roughness, rock_mix) - 0.06 * (grain - 0.5) * detail;
	SPECULAR = 0.18;

	// Perturb the normal from the gradient of the grain field. This is what
	// makes the low sun rake across the ground instead of washing it flat.
	// Finite differences in world XZ; the surface is near-horizontal, so
	// nudging the world normal directly is a good approximation and needs no
	// tangents on the mesh (the terrain is built by SurfaceTool without them).
	float e = 0.22;
	float h0 = ground_noise(world_pos.xz, grain_scale);
	float hx = ground_noise(world_pos.xz + vec2(e, 0.0), grain_scale);
	float hz = ground_noise(world_pos.xz + vec2(0.0, e), grain_scale);
	vec3 bump = vec3(h0 - hx, 0.0, h0 - hz) * bump_strength * detail;
	vec3 perturbed = normalize(n + bump);
	NORMAL = normalize((VIEW_MATRIX * vec4(perturbed, 0.0)).xyz);
}
