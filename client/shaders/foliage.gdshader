// How VEGETATION is shaded — the ash scrub and dead grass. Solid debris has its
// own opaque shader (`debris.gdshader`); the two were one file until review
// pointed out that stone has no business on a cutout path.
//
// Three jobs, each answering one of the quality bar's "tells":
//   1. CUTOUT so a prop reads by its silhouette — leaves against the sky —
//      instead of as a solid primitive.
//   2. PER-INSTANCE TINT so a field of props is not one flat hue. The variation
//      is derived from INSTANCE_ID, NOT from an RNG or a per-instance colour
//      buffer: it costs nothing, needs no MultiMesh change, and is identical
//      every boot, so it cannot disturb determinism or a committed golden.
//   3. WIND so the world is not frozen. Sway is weighted by height along the
//      card (base anchored, tip free), which is what stops it looking like the
//      whole prop sliding.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
// The tint band. Every instance lands somewhere between these two colours, so
// widening the band is how a kind gets more tonal variety.
uniform vec3 tint_low : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 tint_high : source_color = vec3(1.0, 1.0, 1.0);
// Metres of horizontal sway at the tip.
uniform float wind_strength = 0.0;
uniform float wind_speed = 1.0;
// The wind's direction in WORLD space, shared by every prop.
//
// This has to be resolved per instance rather than baked into the offset.
// WorldGen gives each prop a random yaw, and a displacement written straight
// into VERTEX is in MODEL space — so the instance transform would rotate the
// sway with it and every clump would bend a different way. That is a field of
// props twitching independently, not one wind crossing the Reach.
uniform vec3 wind_dir = vec3(1.0, 0.0, 0.35);
// Metres per radian of gust phase — how long a gust is as it crosses the Reach.
uniform float wind_wavelength = 9.0;
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

	// Gust phase comes from the prop's WORLD POSITION along the wind, not from
	// its instance id, so a gust travels across the Reach and neighbours move
	// together. A per-instance phase makes every clump independent: at any
	// instant half the field bends upwind, which reads as twitching rather than
	// as weather. A small id-derived jitter keeps it from looking mechanical.
	vec3 wind_axis = normalize(wind_dir);
	vec3 world_pos = MODEL_MATRIX[3].xyz;
	// Note the MINUS on the time term: with a plus, points of constant phase
	// travel against wind_dir and the gusts visibly roll upwind.
	float phase = dot(world_pos, wind_axis) / max(wind_wavelength, 0.001)
		- TIME * wind_speed
		+ hash11(id) * 0.6;

	// Biased so the sway is always DOWNWIND: a gust varies how hard the
	// vegetation leans, never which way. Symmetric oscillation around neutral
	// would mean the field spends half its time bending into the wind.
	float gust = 0.62 + 0.38 * sin(phase);
	float sway = gust * wind_strength * influence;

	// Rotate the shared world-space wind into this instance's model space, so
	// every prop leans the SAME way regardless of the yaw it was planted with.
	// The instance basis is a Y rotation with uniform scale, so its transpose is
	// the inverse rotation up to that scale — which normalising removes.
	vec3 local_wind = normalize(transpose(mat3(MODEL_MATRIX)) * normalize(wind_dir));
	VERTEX += local_wind * sway;

	NORMAL = normalize(mix(NORMAL, vec3(0.0, 1.0, 0.0), normal_lift));
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);

	// Cut the silhouette with an explicit discard, and NEVER write ALPHA.
	//
	// The visual result is identical to an alpha-scissor threshold, but the
	// pipeline choice is unambiguous: a shader that never writes ALPHA is not a
	// transparency candidate under any reading of the rules, so these cards
	// cannot land in the transparent queue, cannot sort against each other, and
	// keep ordinary opaque shadow behaviour. Reviewers read the alpha-scissor
	// form as "transparent with a discard bolted on" (twice), and the intent is
	// worth more than the two characters saved. `depth_prepass_alpha` came off
	// the render mode with it — that mode exists to serve an ALPHA write.
	if (tex.a < 0.5) {
		discard;
	}
	ALBEDO = tex.rgb * inst_tint;
	ROUGHNESS = roughness_value;
	SPECULAR = 0.15;
	BACKLIGHT = backlight_tint;
}
