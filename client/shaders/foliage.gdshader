// How every cosmetic ground prop is shaded. One shader serves all four kinds;
// a kind differs only by its uniforms, so vegetation and debris share a single
// code path (and a single test surface) rather than drifting apart.
//
// Three jobs, each answering one of the quality bar's "tells":
//   1. ALPHA CUTOUT so a prop reads by its silhouette — leaves against the sky
//      — instead of as a solid primitive.
//   2. PER-INSTANCE TINT so a field of props is not one flat hue. The variation
//      is derived from INSTANCE_ID, NOT from an RNG or a per-instance colour
//      buffer: it costs nothing, needs no MultiMesh change, and is identical
//      every boot, so it cannot disturb determinism or a committed golden.
//   3. WIND so the world is not frozen. Sway is weighted by height along the
//      card (base anchored, tip free), which is what stops it looking like the
//      whole prop sliding.
shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
// The tint band. Every instance lands somewhere between these two colours, so
// widening the band is how a kind gets more tonal variety.
uniform vec3 tint_low : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 tint_high : source_color = vec3(1.0, 1.0, 1.0);
// Metres of horizontal sway at the tip. 0 = static (the debris kinds).
uniform float wind_strength = 0.0;
uniform float wind_speed = 1.0;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.95;
// Blends the true surface normal toward straight up. Real foliage cards look
// harsh lit by their flat geometric normal; leaning the normal skyward is the
// standard trick that makes a card read as a soft leafy volume.
//
// Keep this LOW here. The Ashfall Reach's sun sits at about -19° elevation, so
// a skyward normal only ever catches grazing light: the first render of this
// pass used 0.55 and the scrub went nearly black under the real dusk sky.
uniform float normal_lift : hint_range(0.0, 1.0) = 0.0;
// Cheap stand-in for the subsurface scattering that makes real leaves glow when
// the sun is behind them. Under a low sun this is what stops thin vegetation
// reading as a flat black cutout, and it is the single biggest reason the scrub
// looks lit rather than stencilled.
uniform vec3 backlight_tint : source_color = vec3(0.0, 0.0, 0.0);

varying vec3 inst_tint;

// Cheap deterministic hash — same instance, same value, every boot and platform.
float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

void vertex() {
	float id = float(INSTANCE_ID);
	inst_tint = mix(tint_low, tint_high, hash11(id * 1.7 + 3.3));

	// UV.y is 1 at the prop's base and 0 at its tip, so this is 0 where the prop
	// meets the ground and 1 at the top: the base stays planted.
	float influence = 1.0 - UV.y;
	float phase = hash11(id) * 6.2831853;
	float sway = sin(TIME * wind_speed + phase) * wind_strength * influence;
	VERTEX.x += sway;
	VERTEX.z += sway * 0.6;

	NORMAL = normalize(mix(NORMAL, vec3(0.0, 1.0, 0.0), normal_lift));
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	ALBEDO = tex.rgb * inst_tint;
	ALPHA = tex.a;
	// Cutout, not blending: vegetation stays in the opaque pass, so it sorts
	// correctly against itself and costs no transparency overdraw.
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = roughness_value;
	SPECULAR = 0.15;
	BACKLIGHT = backlight_tint;
}
