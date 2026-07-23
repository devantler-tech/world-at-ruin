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
// Four things are added here, in order of how much they matter at this
// world's low sun angle:
//   1. NORMAL perturbation — grazing light picking out grain is the single
//      biggest cue that a surface has substance. A flat normal cannot produce
//      it no matter how the albedo is tinted.
//   2. Slope-aware material — ash and dust settle on flats and wash off steep
//      faces, exposing coarser rock. Real ground changes with its angle, and
//      that change is what stops a heightfield reading as a painted mesh.
//   3. Multi-scale albedo/roughness break-up — drifts at metres, grain at
//      centimetres, so the ground neither tiles nor sits at one flat value.
//   4. DECIDED ground (#261) — see below. Every term in 1-3 is a smooth
//      interpolation of noise, and the art-direction reference set
//      (docs/art-direction/README.md) diagnoses exactly that as the reason
//      surfaces do not read as authored: noise interpolates, it never DECIDES.

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

// ---- Decided ground (#261) ----------------------------------------------
// The ground is not a dune field, it is BROKEN ROCK with ash blown over it.
// So the decision this shader can state outright is the plate: the ground
// partitions into irregular slabs, each slab IS one substance, and the slabs
// meet at cracks the ash has settled into. That gives the three things noise
// cannot — an edge, a named substance, and deliberate contrast — using the
// same primitives cave_rock.gdshader used for its bedding (#235/#236):
// floor() to decide, step() to name, fwidth() to keep the edge from aliasing.
//
// Three substances beside the existing rock_color, chosen to widen BOTH axes
// the reference set measures. rock_color..plate_pale spans 0.27..0.57 luma
// against the 0.28..0.46 the ash/rock pair alone could reach, and plate_ferric
// sits off the single warm hue line the whole Reach currently shares. They
// stay inside the massif's palette on purpose: cave_rock's exterior comment
// notes it sits between the ground's ash and rock colours so the massif reads
// as stone of the same landscape, and that only holds if the ground does too.
uniform vec3 plate_basalt: source_color = vec3(0.22, 0.21, 0.22);
uniform vec3 plate_ferric: source_color = vec3(0.42, 0.26, 0.18);
uniform vec3 plate_pale: source_color = vec3(0.54, 0.51, 0.45);
// Plates per metre. 0.85 puts a slab at about 1.2 m — a size a standing player
// reads against their own height, and small enough that a mid-field view has
// many contacts in frame. Calibrated against the cave's failure modes: too
// fine aliases into corduroy, too coarse puts so few edges on screen that the
// frame measures flatter than before the change. 0.55 (~1.8 m) was the first
// value here and read as floor tiles rather than as broken ground.
// Product law 2: the plate treatment is player-visible art that still reads as
// unfinished (flat against the ground, nothing crumbled), so it ships
// DEFAULT-OFF and a player opts in. Off, every plate-derived term below folds
// back to the pre-#261 ash/rock surface exactly. Set from WorldGen via
// WAR_GROUND_PLATES=1; this flips to true, and the uniform is retired, once the
// treatment clears the bar.
uniform bool plates_enabled = false;
uniform float plate_scale = 0.85;
// Crack half-width in plate units (so a crack stays the same fraction of a
// slab at any plate_scale): 0.032 * 1.2 m is a seam a couple of centimetres
// across.
uniform float crack_width: hint_range(0.001, 0.3) = 0.032;
// Kept deliberately low. A crack drawn as a dark OUTLINE tessellates the
// ground into a polygon net, which is the universal signature of dried mud —
// it read as a cracked lakebed to the horizon at 0.55 and still read as mud
// patches at 0.34. A seam should be found by the light raking across it
// (crack_relief, below), not drawn on as a line.
uniform float crack_darkness: hint_range(0.0, 1.0) = 0.09;
uniform float crack_relief: hint_range(0.0, 3.0) = 1.1;
// How hard the ash sheet ends. This used to be a 0.24-wide smoothstep ramp,
// which is precisely the "smooth interpolation" the diagnosis names — wind
// leaves a boundary, not a gradient.
uniform float ash_contact: hint_range(0.002, 0.3) = 0.035;
uniform float lip_lift: hint_range(0.0, 1.0) = 0.18;

varying vec3 world_pos;
varying vec3 world_normal;

#include "res://shaders/terrain_surface.gdshaderinc"

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
	return terrain_ground_noise(xz, scale);
}

// Jittered-grid partition of the ground plane. `id` is the owning plate (the
// decision — floor() of the grid, so every fragment on a slab resolves to the
// SAME plate), and f1/f2 are the two nearest centre distances. f2 - f1 is the
// crack field: it goes to zero exactly on a boundary between two plates, and
// widens naturally where three plates meet, which is where real broken ground
// opens up too.
void plates(vec2 uv, out vec2 id, out float f1, out float f2) {
	terrain_plates(uv, id, f1, f2);
}

// One plate's substance, resolved from its cell id alone. rgb = colour,
// a = roughness. step() rather than smoothstep(): a slab IS basalt or IS
// ferric. Chained mixes mean each later threshold overrides the earlier one
// exactly, so the four selection widths are 0.38 / 0.28 / 0.20 / 0.14.
vec4 plate_substance(vec2 id) {
	return terrain_plate_substance(
		id, rock_color, rock_roughness, plate_basalt, plate_ferric, plate_pale);
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

	// ---- The plates, and the cracks between them -------------------------
	// Everything from here to the end of this block is skipped entirely when
	// the treatment is off. Masking the results later still made every terrain
	// fragment pay for the nine-cell search, its hashes and its derivatives,
	// and terrain fills most of the frame — so a player who never opted in was
	// buying the experiment's GPU cost. `plates_enabled` is a uniform, so the
	// branch is coherent across the whole draw and the derivatives taken
	// inside it stay well-defined (which they would NOT be under varying
	// control flow).
	vec2 plate_uv = world_pos.xz * plate_scale;
	vec2 plate_id = vec2(0.0);
	float f1 = 0.0;
	float f2 = 1.0;
	float plate_resolved = 0.0;
	vec4 sub = vec4(rock_color, rock_roughness);
	float crack = 0.0;
	float plate_fw = 0.0;
	if (plates_enabled) {
	plates(plate_uv, plate_id, f1, f2);

	// Screen footprint of one plate. Unlike the grain, plates are NOT tied to
	// the distance fade: a 1.8 m slab is still a resolvable feature well past
	// where centimetre grain has to go, so the right cutoff is the pixel
	// footprint, not a metre count. Once a pixel spans a whole plate there is
	// no per-plate answer left to give, so converge on the mean of the
	// distribution weighted by each substance's real selection width — a flat
	// average would converge on a colour no plate actually has.
	plate_fw = max(fwidth(plate_uv.x), fwidth(plate_uv.y));
	plate_resolved = 1.0 - smoothstep(0.30, 0.85, plate_fw);

	sub = plate_substance(plate_id);
	vec3 mean_col = rock_color * 0.38 + plate_basalt * 0.28
		+ plate_ferric * 0.20 + plate_pale * 0.14;
	float mean_rough = rock_roughness * 0.38 + 0.88 * 0.28
		+ 0.72 * 0.20 + 0.94 * 0.14;
	sub = mix(vec4(mean_col, mean_rough), sub, plate_resolved);

	// The crack itself, widened to the local footprint so it stays a line
	// instead of aliasing, and dissolved once it is thinner than about a pixel
	// — detail leaves the frame by fading, never by shimmering.
	float crack_fw = fwidth(f2 - f1);
	float cw = max(crack_width, crack_fw * 1.2);
	crack = 1.0 - smoothstep(0.0, cw, f2 - f1);
	crack *= 1.0 - smoothstep(0.30, 0.85, plate_fw);
	}

	// Ash banks where the ground lies flat and where drifts pile it; rock is
	// scoured bare on the steeper faces. The drift term perturbs the threshold
	// so the boundary wanders instead of following a clean contour line — but
	// the boundary is now a CONTACT, not a ramp: wind leaves an edge.
	float ash_edge = slope + (drift - 0.5) * 0.22 - rock_slope;
	// Clamped so a faceted normal (slope is per-face) cannot spike the width.
	// The ceiling must never fall below the floor: ash_contact ranges to 0.3,
	// and clamp() with minVal > maxVal is UNDEFINED in GLSL, not merely odd.
	float aw = clamp(max(ash_contact, fwidth(ash_edge) * 1.2),
		ash_contact, max(ash_contact, 0.25));
	// The sharp CONTACT is part of the treatment, not a free improvement: it
	// replaces the previous fixed-width ramp and so changes albedo and
	// roughness for any fragment near the slope threshold. Left ungated it
	// shipped a slice of the unfinished work to everyone, and no fixed-vantage
	// frame comparison can prove no such fragment is on screen elsewhere. So
	// the default path keeps the pre-#261 ramp exactly.
	float rock_mix = plates_enabled
		? smoothstep(-aw, aw, ash_edge)
		: smoothstep(rock_slope - 0.12, rock_slope + 0.12,
			slope + (drift - 0.5) * 0.22);

	// How much bare rock shows through here. The ash sheet is what the wind
	// left, so rock surfaces where the drift field says the ground was swept,
	// and always on a face too steep to hold ash.
	//
	// This gate is the difference between broken ground and a dried lakebed.
	// Without it the plates were drawn everywhere at equal strength, which put
	// a continuous, uniform polygon net across the whole Reach — and because
	// the substances were gated behind rock_mix (near zero on flat ground)
	// the only thing that actually rendered was the crack. Cracked mud, not
	// ash over rock. Slabs and their cracks now appear together, in patches,
	// and the ash between them stays smooth — which is honest: wind-blown ash
	// IS smooth, and the contrast against a decided slab is the whole point.
	// The gate is itself a CONTACT, not a ramp. A smoothstep here blended every
	// slab part-way back toward ash, which washed the named substances out to
	// the point that the only thing left reading was the crack — the same
	// failure one level up. An ash sheet has an edge; inside it there is ash,
	// outside it there is rock.
	// 0.52 put so little bare rock in frame that whole vantages (the shrine
	// approach among them) showed none at all and read exactly as they did
	// before the change; 0.47 puts a slab field in most views while keeping
	// ash the dominant surface, which is what the fiction asks for.
	float exposed_edge = drift - 0.47;
	// Same undefined-clamp guard as the ash contact above.
	float ew = clamp(max(ash_contact, fwidth(exposed_edge) * 1.2),
		ash_contact, max(ash_contact, 0.25));
	float sheet = clamp(smoothstep(-ew, ew, exposed_edge) + rock_mix, 0.0, 1.0);

	// ---- Stones, not paving ----------------------------------------------
	// A cellular partition that FILLS the ground is a tessellation, and a
	// tessellation of flat tiles reads as crazy paving or dried mud no matter
	// how it is tuned — four calibration passes improved the colour, the seam
	// weight and the patch size without ever escaping that signature, because
	// the signature is the primitive and not the constants. Broken rock is not
	// space-filling: it is DISCRETE stones with ash and grit lying between
	// them. So a cell is not automatically a slab. Each one independently
	// either carries stone or does not, which turns the net into scattered
	// slabs whose edges only appear where a stone meets open ground.
	float slab_pick = hash3(vec3(plate_id * 2.3, 19.0));
	float is_slab = step(0.60, slab_pick);
	// Once a pixel spans a whole plate there is no per-plate answer to give,
	// so converge on the mean coverage exactly as the substance does above.
	float slab = mix(0.40, is_slab, plate_resolved);
	// TWO separate quantities, and conflating them was a real bug in both
	// directions:
	//
	//   plate_mask  — is this cell a SLAB? Drives the per-cell substance, the
	//                 crack darkening and the crack relief. A rejected cell
	//                 must show none of those, or the slabs stop being
	//                 discrete stones and become the space-filling
	//                 tessellation this whole section exists to avoid.
	//   rock_exposure — is there bare stone here at all, slab or not? Drives
	//                 only the ash-vs-stone choice. A face too steep to hold
	//                 ash shows rock whether or not it drew a slab.
	//
	// Multiplying the binary slab mask into `sheet` zeroed ~60% of steep cells
	// back to ash. Taking max() of the two instead fixed that but fed the
	// substrate into the plate terms, so every rejected cell on a steep face
	// drew its own substance and seams — the tessellation again, now only on
	// slopes. They are separate values because they answer separate questions.
	float plate_mask = sheet * slab;
	float rock_exposure = max(rock_mix, plate_mask);

	// The vertex tint stays the base layer (as cave_rock does with COLOR), so
	// the world's existing ash/rock palette and its variation survive.
	vec3 base = COLOR.rgb;
	// The opt-in gate. With plates off these three collapse to rock_color,
	// rock_roughness and rock_mix — which is the pre-#261 surface term for
	// term, so a default boot renders exactly what it rendered before.
	float plate_gate = plates_enabled ? 1.0 : 0.0;
	float eff_plate = plate_mask * plate_gate;
	// Stone is rock_color unless this cell is a slab, in which case it is the
	// slab's own substance. Then ash over the top of whichever it is.
	vec3 stone_rgb = mix(rock_color, sub.rgb, eff_plate);
	float stone_rough = mix(rock_roughness, sub.a, eff_plate);
	float eff_exposure = mix(rock_mix, rock_exposure, plate_gate);
	crack *= eff_plate;
	vec3 surface = mix(ash_color, stone_rgb, eff_exposure);
	// Scorch pools in the low, sheltered drifts — the Ruin's burn, not shadow.
	surface = mix(surface, scorch_color, smoothstep(0.62, 0.95, drift) * 0.35 * (1.0 - rock_mix));
	// Grain modulates brightness slightly; kept subtle so it reads as texture
	// rather than dirt sprayed over the frame.
	surface *= 0.93 + 0.14 * mix(0.5, grain, detail);
	// Ash drifts pile into a crisp lip at their own leading edge rather than
	// thinning away — the cue that reads as "blown here" instead of "painted".
	float lip = (1.0 - smoothstep(0.0, aw * 4.0, abs(ash_edge)))
		* (1.0 - smoothstep(0.30, 0.85, fwidth(ash_edge)));
	surface *= 1.0 + lip * lip_lift * plate_gate;
	// Ash and shadow collect in the cracks: the cavity-darkening the reference
	// set names, applied to an edge the shader decided rather than to noise.
	// Gated by the SLAB mask, not by rock exposure — a crack belongs to the
	// stone that drew it, and a bare steep face that never drew a slab has no
	// seams to darken. (Already zeroed above when plates are off.)
	surface *= 1.0 - crack * crack_darkness;

	ALBEDO = base * surface * 2.0;
	// The region's own roughness rides in the vertex ALPHA, biased to 0.5 (see
	// WorldGen._ground_color). Without it every region would be one substance
	// wearing a different tint: scoured stone would answer the low sun exactly
	// like loose ash. Clamped because the bias plus the grain term must not
	// leave a legal roughness.
	//
	// #261 substitutes the SLAB's own roughness for the flat rock_roughness on
	// the exposed side of that mix, so the region bias now rides on top of a
	// per-slab substance rather than one stone. The two are answering different
	// questions and compose cleanly: the REGION says how worn this part of the
	// Reach is, the SLAB says what this particular piece of it is made of.
	float region_rough = COLOR.a - 0.5;
	ROUGHNESS = clamp(mix(ash_roughness, stone_rough, eff_exposure) + region_rough
		- 0.06 * (grain - 0.5) * detail, 0.0, 1.0);
	// Packed ash in a crack is matte, whatever the slab either side of it is.
	ROUGHNESS = mix(ROUGHNESS, 1.0, crack * 0.5);
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
	// The cracks are grooves and need relief too, but re-sampling the plate
	// field at offsets would cost three MORE cellular evaluations on top of
	// the one already done — four per fragment over a surface that fills the
	// frame. The first cut of this shader did exactly that and the macOS GPU
	// watchdog killed the process before the world finished building.
	//
	// So take the gradient from the screen derivatives of the value already in
	// hand, and convert it back into world XZ with the derivatives of the
	// plate coordinate itself (a 2x2 solve). `crack_fixed` deliberately uses
	// the constant width, never the fwidth-widened one: differencing a term
	// that already carries a screen derivative would be a second derivative,
	// which is undefined.
	// Same uniform branch as the plate block: with the treatment off there is
	// no relief to compute, and this is where its second batch of derivative
	// work lives.
	vec2 grad = vec2(0.0);
	if (plates_enabled) {
	float crack_fixed = 1.0 - smoothstep(0.0, crack_width, f2 - f1);
	vec2 duvdx = dFdx(plate_uv);
	vec2 duvdy = dFdy(plate_uv);
	float dcdx = dFdx(crack_fixed);
	float dcdy = dFdy(crack_fixed);
	float det = duvdx.x * duvdy.y - duvdx.y * duvdy.x;
	float safe_det = abs(det) < 1e-8 ? 1e-8 : det;
	// Gradient in plate-uv space, then into world XZ (plate_uv = xz * scale).
	// This is inside the gate for a reason found by measurement: when the
	// relief was computed unconditionally, the grooves kept raking the light
	// with the treatment switched off, moving cave-chamber 29.61% away from
	// base. Shader reasoning said the gate was already exact; it was not.
	grad = vec2(dcdx * duvdy.y - dcdy * duvdx.y,
		dcdy * duvdx.x - dcdx * duvdy.x) / safe_det * plate_scale * plate_mask;
	// A screen-space gradient is UNBOUNDED as the feature it measures compresses
	// into a pixel: at a grazing angle a seam 4 cm wide spans a fraction of one,
	// and the raw slope runs to tens per metre — enough to swing the normal
	// through a right angle and shimmer. Two guards, both of which the albedo
	// crack already had and this term was missing:
	//   - dissolve on the SAME schedule as the crack it belongs to, so relief
	//     never outlives the mark that justifies it;
	//   - clamp the magnitude, so a single degenerate quad cannot flip a normal.
	// Without these the ground kept a jittering micro-relief exactly where the
	// crack had visually vanished — detail leaving by shimmering rather than by
	// fading, which is the failure this shader family is written to avoid.
	grad *= 1.0 - smoothstep(0.30, 0.85, plate_fw);
	float grad_len = length(grad);
	grad = grad_len > 1.5 ? grad * (1.5 / grad_len) : grad;
	}
	// A crack is a groove, so height is -crack and the normal tilts INTO it.
	// The grain bump below is NOT plate work and runs on both paths; only the
	// crack_relief term above it is gated, and it is zero when the treatment
	// is off.
	vec3 bump = vec3(
		(h0 - hx) * bump_strength + grad.x * crack_relief,
		0.0,
		(h0 - hz) * bump_strength + grad.y * crack_relief) * detail;
	vec3 perturbed = normalize(n + bump);
	NORMAL = normalize((VIEW_MATRIX * vec4(perturbed, 0.0)).xyz);
}
