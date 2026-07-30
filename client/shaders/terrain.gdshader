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
// How hard an UNRESOLVED groove darkens the pixel that contains it — the seam
// relief the normal cannot carry, kept as occlusion instead of discarded (#539).
//
// This is a different quantity from `crack_darkness` above and the distinction
// is the whole reason it is safe to set higher. `crack_darkness` draws the
// crack as a LINE wherever the crack field says there is one, which is what
// tessellated the ground into a polygon net and read as a cracked lakebed at
// 0.55. This one is driven by the second moment, which is zero wherever a
// pixel resolves the groove and zero wherever it misses it entirely — it is
// non-zero only in the band where a seam is turning sub-pixel, so it is
// far-field statistical shading rather than a mid-field drawn mark, and it
// cannot outline a seam a player can still see.
//
// 3.5 is the KNEE, swept on-GPU (both instruments, one machine, one sitting,
// plates-off control 0.0000 on every arm). It is the smallest value that
// restores the near-field read the mean filter costs, measured as 6 m coverage
// x strength — the two move in opposite directions, so neither alone decides:
//
//   cavity   crawl    6 m       12 m      24 m      48 m      6 m read
//   off      0.0000   0.00028   0.00022   0.00004   0.00011   -42%
//   3.0      0.0000   0.00053   0.00113   0.00043   0.00420   -13%
//   3.5      0.0000   0.00066   0.00149   0.00070   0.00547    +7%
//   4.0      0.0000   0.00079   0.00180   0.00100   0.00661   +27%
//   8.0      0.0002   0.00151   0.00395   0.00449   0.01367  +180%
//   (main)   0.0005   0.00034   0.00050   0.00028   0.00056     0%
//
// The aim is a near field left AS IT WAS, not maximised, so the smallest value
// that clears `main` is the right one rather than the largest that still holds
// the floor. Below 3.5 the near field is still being paid away; at 8.0 the
// crawl floor gives.
//
// The crawl column is only this flat because the variance is blended across
// both cells at a contact (see `plate_mask_relief_nb`). Gated by the owning
// cell alone it read 0.0001 at 4.0 and 0.0007 at 8.0 — worse than `main` — and
// removing that step is what let the knee move up to where the near field is
// whole. Absolute levels are not portable between machines and both tools say
// so; the ORDERING is what carries.
uniform float seam_cavity: hint_range(0.0, 8.0) = 3.5;
// How hard the ash sheet ends. This used to be a 0.24-wide smoothstep ramp,
// which is precisely the "smooth interpolation" the diagnosis names — wind
// leaves a boundary, not a gradient.
uniform float ash_contact: hint_range(0.002, 0.3) = 0.035;
uniform float lip_lift: hint_range(0.0, 1.0) = 0.18;

// The measurement instrument for #273 — a scalar on the finished ground albedo,
// so `tools/atmosphere_ablation` can ask "how much of an albedo difference of
// size X survives to the screen?" by rendering the SAME frame twice and varying
// only this. The regions differ by a baked factor of 3.1x, so driving this
// between 1.0 and that factor reproduces a region step without moving the
// generator, the vertex colours or any determinism golden.
//
// It multiplies rather than replaces on purpose: the question is how a RATIO
// transmits through the atmosphere, and a ratio is what the regions actually
// are.
//
// At its default of exactly 1.0 the multiply is an arithmetic identity, but the
// shipped frame is NOT promised to be bit-identical and measurement says it is
// not: against a same-build control that reproduced 0.00% of outdoor pixels,
// adding this uniform moved 0.02-0.07% of them. The compiler is free to
// reassociate the widened product, which shifts the last mantissa bit on a
// scattered few. Every one of those differences is below 8-bit quantisation
// (mean |dRGB| <= 0.0001) and every reported frame metric — p1, p99, hue span —
// is unchanged to all published digits, so nothing a player can see moves.
uniform float albedo_probe: hint_range(0.25, 4.0) = 1.0;

varying vec3 world_pos;
varying vec3 world_normal;

#include "res://shaders/terrain_surface.gdshaderinc"
#include "res://shaders/noise.gdshaderinc"

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
// `c1`/`c2` are the centres those two distances are measured to. They come out
// of the same search at no extra cost and are what lets the crack relief below
// take an ANALYTIC gradient instead of differencing a sub-pixel step. `id2` is
// the cell they belong to, which is what lets the substance step across the
// boundary be averaged over the pixel drawing it. `f3`/`id3` are the third
// candidate, which is what keeps that averaging continuous where three plates
// meet (#499).
void plates(vec2 uv, out vec2 id, out float f1, out float f2,
		out vec2 c1, out vec2 c2, out vec2 id2, out float f3, out vec2 id3) {
	terrain_plates(uv, id, f1, f2, c1, c2, id2, f3, id3);
}

// One plate's substance, resolved from its cell id alone. rgb = colour,
// a = roughness. step() rather than smoothstep(): a slab IS basalt or IS
// ferric. Chained mixes mean each later threshold overrides the earlier one
// exactly, so the four selection widths are 0.38 / 0.28 / 0.20 / 0.14.
vec4 plate_substance(vec2 id) {
	return terrain_plate_substance(
		id, rock_color, rock_roughness, plate_basalt, plate_ferric, plate_pale);
}

// One cell's FINISHED surface: ash resolved against that cell's own stone, its
// own crack darkening, and its own roughness terms — composed before any
// averaging with a neighbour, for the reason the call site sets out (averaging
// earlier is a product of blends where the correct answer is a blend of
// products).
//
// The per-cell ORDERING here is load-bearing and is why this is one function
// rather than three inline copies. Scorch is affine with a non-zero constant, so
// it does not commute with the crack multiply and has to land before it; the
// region and grain offsets have to land before the crack pushes roughness toward
// 1. A triple junction needs three of these (#499), and three hand-copies of an
// ordering nothing checks is exactly how the ground and the contact band drifted
// apart before `crack_relief_parity_test` was written to pin them.
void plate_cell_surface(
		vec4 sub_cell, float slab_cell, float sheet, float rock_mix,
		float scorch_k, float crack_in, float region_rough, float grain,
		float detail,
		out vec3 surface_out, out float rough_out, out float crack_out) {
	float mask = sheet * slab_cell;
	float exposure = max(rock_mix, mask);
	// The crack is gated by the mask, so it is per-cell too — darkening the
	// averaged surface would darken the neighbour's ash by the slab's seam and
	// under-darken the slab.
	crack_out = crack_in * mask;
	surface_out = mix(
		mix(ash_color, mix(rock_color, sub_cell.rgb, mask), exposure),
		scorch_color, scorch_k) * (1.0 - crack_out * crack_darkness);
	rough_out = mix(
		clamp(mix(ash_roughness, mix(rock_roughness, sub_cell.a, mask), exposure)
			+ region_rough - 0.06 * (grain - 0.5) * detail, 0.0, 1.0),
		1.0, crack_out * 0.5);
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
	vec2 plate_id2 = vec2(0.0);
	vec2 plate_id3 = vec2(0.0);
	float f1 = 0.0;
	float f2 = 1.0;
	float f3 = 1.0;
	float plate_resolved = 0.0;
	float plate_edge_w = 0.0;
	// Coverage split across the three nearest plates, (owning, second, third).
	// The third is 0.0 everywhere except at a triple junction (#499).
	vec3 plate_w = vec3(1.0, 0.0, 0.0);
	vec4 sub = vec4(rock_color, rock_roughness);
	vec4 sub_nb = vec4(rock_color, rock_roughness);
	vec4 sub_nb3 = vec4(rock_color, rock_roughness);
	float is_slab2 = 0.0;
	float is_slab3 = 0.0;
	float crack = 0.0;
	float plate_fw = 0.0;
	float crack_fw = 0.0;
	// Hoisted out of the block below because the crack relief needs the same
	// footprint: it is the one quantity that measures how far the separator
	// moves in a pixel, and both the boundary average and the seam filter are
	// keyed on it.
	float edge_fw = 0.0;
	vec2 plate_c1 = vec2(0.0);
	vec2 plate_c2 = vec2(0.0);
	if (plates_enabled) {
	plates(plate_uv, plate_id, f1, f2, plate_c1, plate_c2, plate_id2, f3,
		plate_id3);

	// Screen footprint of one plate. Unlike the grain, plates are NOT tied to
	// the distance fade: a 1.8 m slab is still a resolvable feature well past
	// where centimetre grain has to go, so the right cutoff is the pixel
	// footprint, not a metre count. Once a pixel spans a whole plate there is
	// no per-plate answer left to give, so converge on the mean of the
	// distribution weighted by each substance's real selection width — a flat
	// average would converge on a colour no plate actually has.
	plate_fw = max(fwidth(plate_uv.x), fwidth(plate_uv.y));
	plate_resolved = 1.0 - smoothstep(0.30, 0.85, plate_fw);

	// Footprint of the boundary itself, needed before the substance is chosen so
	// the step between two plates can be averaged over the pixel that draws it.
	crack_fw = fwidth(f2 - f1);

	// A plate boundary is a step of ZERO width: `plate_substance` is a function
	// of the owning cell id, so a fragment does not shade across a contact, it
	// SWAPS by the whole contrast between two substances. Past the distance
	// where that boundary is narrower than a pixel, sliding the camera a
	// fraction of a pixel makes every pixel the boundary crosses flip — which
	// is the crawl this treatment was filed for (#306).
	//
	// So average the two plates over the boundary's own footprint. Below the
	// distance where the contact resolves, the weight is exactly 0.0 and the
	// near-field read — hard edges, named substances, full contrast — is
	// untouched, which is what #306's third acceptance criterion protects.
	// The footprint is taken from the ANALYTIC separator, not from
	// `fwidth(f2 - f1)`. `f2 - f1` is non-negative and folds to zero at the
	// boundary — the nearest and second-nearest sites swap identity across it —
	// so it is a cusp rather than a signed coordinate, and a screen difference
	// of it COLLAPSES on exactly the quads that straddle an edge: both samples
	// report a similar small magnitude from opposite sides, the difference goes
	// to zero, and the blend width with it. The pixels most in need of
	// averaging would be the ones that got none.
	//
	// grad(f2 - f1) = normalize(uv - c2) - normalize(uv - c1) is exact and
	// stays finite across the boundary, so scaling it by the plate footprint
	// gives how far `f2 - f1` really moves in one pixel. Same closed form the
	// relief below uses, for the same reason.
	// Projected through BOTH screen derivatives rather than scaled by a single
	// footprint scalar: |grad| * plate_fw discards the separator's ORIENTATION
	// against the pixel, so a boundary lying diagonally, or ground at a grazing
	// angle where the footprint is anisotropic, is under- or over-estimated.
	// d(f2-f1)/dx = dot(grad, dFdx(plate_uv)) is the exact pixel-space rate, and
	// |dx| + |dy| is then precisely what `fwidth` would have returned had the
	// quantity not been a cusp.
	vec2 e1 = plate_uv - plate_c1;
	vec2 e2 = plate_uv - plate_c2;
	vec2 gsep_e = e2 * inversesqrt(max(dot(e2, e2), 1e-12))
		- e1 * inversesqrt(max(dot(e1, e1), 1e-12));
	edge_fw = abs(dot(gsep_e, dFdx(plate_uv)))
		+ abs(dot(gsep_e, dFdy(plate_uv)));
	plate_edge_w = terrain_plate_edge_blend(f1, f2, edge_fw * 0.5);
	// ...and WHICH plates that share belongs to. Away from a triple junction this
	// is exactly `(1 - plate_edge_w, plate_edge_w, 0)` — the two-cell answer,
	// unchanged — and at one it becomes symmetric in the candidates so an
	// identity swap exchanges equal weights instead of stepping the blend target
	// (#499). Keyed on the isotropic `plate_fw`, not `edge_fw`; see the
	// function's own note on why a width built from `c1` puts the defect back.
	plate_w = terrain_plate_blend_weights(f1, f2, f3, plate_edge_w, plate_fw);

	// Both cells' substances are kept SEPARATE here and composed with their own
	// slab masks below. Blending the substances here and the masks there would
	// be a product of two blends where the correct answer is a blend of two
	// products: at a contact between a slab and a bare cell it would show a
	// quarter of the bare cell's substance, which that cell never draws.
	vec3 mean_col = rock_color * 0.38 + plate_basalt * 0.28
		+ plate_ferric * 0.20 + plate_pale * 0.14;
	float mean_rough = rock_roughness * 0.38 + 0.88 * 0.28
		+ 0.72 * 0.20 + 0.94 * 0.14;
	vec4 mean4 = vec4(mean_col, mean_rough);
	sub = mix(mean4, plate_substance(plate_id), plate_resolved);
	sub_nb = mix(mean4, plate_substance(plate_id2), plate_resolved);
	sub_nb3 = mix(mean4, plate_substance(plate_id3), plate_resolved);
	// The neighbour's slab pick belongs on the opt-in path with the rest of the
	// plate work: it is a hash, and the default-off ground must not pay for a
	// preview it never draws.
	is_slab2 = step(0.60, hash3(vec3(plate_id2 * 2.3, 19.0)));
	// The third candidate takes the same mask as the other two. The mask is the
	// DOMINANT half of the boundary residual (see the note at `slab` below), so
	// a third substance blended under the second's mask would leave most of the
	// junction step exactly where it was.
	is_slab3 = step(0.60, hash3(vec3(plate_id3 * 2.3, 19.0)));

	// The crack itself, widened to the local footprint so it stays a line
	// instead of aliasing, and dissolved once it is thinner than about a pixel
	// — detail leaves the frame by fading, never by shimmering.
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
	// The slab mask chooses stone-or-not from the SAME cell id as the substance,
	// so it steps at exactly the same zero-width boundary and crawls the same
	// way. It takes the same footprint average, or half the contrast at a
	// contact would still snap while the other half was being filtered.
	// The slab mask chooses stone-or-not from the SAME cell id as the substance,
	// so it steps at exactly the same zero-width boundary and crawls the same
	// way. Measured, it is the DOMINANT half: averaging the substance alone
	// leaves the boundary floor where it was (0.0014 -> 0.0015 with the relief
	// switched off), and averaging the mask too takes it to 0.0003.
	// Once a pixel spans a whole plate there is no per-plate answer to give,
	// so converge on the mean coverage exactly as the substance does above —
	// PER CELL, because each cell's substance is gated by its own mask.
	float slab_own = mix(0.40, is_slab, plate_resolved);
	float slab_nb = mix(0.40, is_slab2, plate_resolved);
	float slab_nb3 = mix(0.40, is_slab3, plate_resolved);
	// A weighted average over the three candidates. `plate_w` sums to one, and
	// away from a junction it is `(1 - plate_edge_w, plate_edge_w, 0)` — so this
	// is the previous two-cell blend term for term everywhere but a junction.
	float slab = slab_own * plate_w.x + slab_nb * plate_w.y
		+ slab_nb3 * plate_w.z;
	// ...but the SAME average must not reach the crack relief, and this is the
	// one place the two uses of the mask have to part company.
	//
	// `plate_mask` gates the relief, and the relief is LARGEST exactly here: the
	// crack derivative peaks at the seam, which is the same place this average
	// is non-zero. Softening the gate therefore widens the region over which
	// that peak is applied, spilling relief onto the neighbouring cell that
	// previously masked it to zero.
	//
	// Note this is NOT an aliasing argument and does not depend on one. The
	// gradient is taken in closed form above, so it is exact at every distance;
	// the cost is simply that a soft gate applies a large term where a hard gate
	// applied none. Measured with that closed form in place, the leak costs more
	// than the average it would pay for: routing the softened mask into the
	// relief reads 0.0045 against this split's 0.0030, while averaging the
	// boundary at all buys 0.0007 (0.0037 on `main` -> 0.0030 here). Doing both
	// to one mask is a net REGRESSION on `main`, which is what every earlier
	// attempt at this measured — and the reason the two USES are separated
	// rather than the average abandoned.
	//
	// Gating it on the BINARY mask keeps the relief confined to cells that
	// actually drew a slab, and costs nothing where it matters: past the
	// distance the contact stops being resolvable the gradient has already
	// faded to nothing, so the hard step multiplies a term that is not there.
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
	// The relief's own gate — same quantity, binary slab (see above).
	float plate_mask_relief = sheet * slab_own;
	// The NEIGHBOUR cell's version of that gate, for the seam variance only.
	// The relief's MEAN keeps the owning cell's binary gate, for the measured
	// reason above; the variance cannot, because the two terms are large in
	// opposite places. The mean's hard step is harmless precisely where the
	// note above says — past the distance a contact resolves, the mean has
	// already faded, so the step multiplies a term that is not there. The
	// variance is largest exactly THERE, so the same step lands on its peak
	// instead of on nothing, and flips the cavity between full and zero as the
	// pixel centre crosses a slab/bare boundary the footprint still straddles.
	// That is a zero-width step reintroduced into the very quantity this change
	// exists to filter.
	float plate_mask_relief_nb = sheet * slab_nb;
	// The THIRD candidate's version of the same gate. The variance is split
	// across all three by `plate_w`, exactly as the substance, the slab mask,
	// the roughness and the crack are — so it needs the third cell's height as
	// well. Away from a triple junction `plate_w.z` is 0, so this term
	// contributes nothing to the result (it is still computed — the cost is one
	// multiply, unconditionally); at one it is what keeps the cavity from
	// inheriting the second-nearest cell's identity swap.
	float plate_mask_relief_nb3 = sheet * slab_nb3;
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
	// rock + K*(sub_pre - slab*rock) rather than mix(rock, sub, K*slab): the
	// premultiplied form is the blend of per-cell products (see `sub_pre`).
	// With `plate_edge_w` at 0 the two are arithmetically identical, so a
	// resolved contact is unchanged.
	// Each cell's FINAL surface is composed before the two are averaged.
	//
	// Averaging any earlier is a product of blends again, one level up: the
	// ash-vs-stone choice is driven by `rock_exposure`, which is itself derived
	// from the mask, so mixing an averaged stone colour by an averaged exposure
	// reintroduces a material neither cell draws. At a 50/50 contact between a
	// slab and a bare cell with the ash sheet full, that yielded 50% ash +
	// 25% slab + 25% base rock where the correct answer is 50% ash + 50% slab.
	//
	// So resolve ash-vs-stone per cell, with that cell's own mask and its own
	// exposure, and blend the two finished surfaces. With `plate_edge_w` at 0
	// this is arithmetically identical to composing the owning cell alone, so a
	// resolved contact and the plates-off path are both unchanged.
	float eff_exposure = mix(rock_mix, rock_exposure, plate_gate);
	// Hoisted above the branch: both paths' roughness needs it.
	float region_rough = COLOR.a - 0.5;
	vec3 surface;
	float stone_rough;
	// The whole per-cell composition sits on the opt-in path. Off, the ground
	// resolves ash against rock exactly as it did before #261 and pays for none
	// of the plate work — the coherent branch this file is built around.
	if (plates_enabled) {
	// Scorch must land BEFORE the crack, which is why it is computed here and
	// passed in rather than applied to the averaged surface. Scorch is affine
	// with a non-zero constant, so it does NOT commute with the crack multiply:
	//   mix(S, scorch, k) * (1-d)  =  S(1-k)(1-d) + scorch*k*(1-d)
	//   mix(S * (1-d), scorch, k)  =  S(1-k)(1-d) + scorch*k
	// which differ by scorch*k*d — a scorched seam would come out undarkened.
	// Grain and lip below are pure multiplies and DO commute, so they stay on the
	// averaged surface.
	float scorch_k = smoothstep(0.62, 0.95, drift) * 0.35 * (1.0 - rock_mix);
	vec3 surf_own;
	vec3 surf_nb;
	vec3 surf_nb3;
	float rough_own;
	float rough_nb;
	float rough_nb3;
	float crack_own;
	float crack_nb;
	float crack_nb3;
	plate_cell_surface(sub, slab_own, sheet, rock_mix, scorch_k, crack,
		region_rough, grain, detail, surf_own, rough_own, crack_own);
	plate_cell_surface(sub_nb, slab_nb, sheet, rock_mix, scorch_k, crack,
		region_rough, grain, detail, surf_nb, rough_nb, crack_nb);
	// The third candidate, which carries weight only at a triple junction.
	plate_cell_surface(sub_nb3, slab_nb3, sheet, rock_mix, scorch_k, crack,
		region_rough, grain, detail, surf_nb3, rough_nb3, crack_nb3);
	// A weighted average of the three finished surfaces. `plate_w` sums to one
	// and is `(1 - plate_edge_w, plate_edge_w, 0)` away from a junction, so this
	// is the previous two-cell blend term for term there — and at a resolved
	// contact, where it is `(1, 0, 0)`, it still composes the owning cell alone.
	surface = surf_own * plate_w.x + surf_nb * plate_w.y + surf_nb3 * plate_w.z;
	// Roughness keeps its downstream terms in the original order too: the
	// region/grain offsets and the clamp are applied per cell BEFORE the crack
	// pushes toward 1, exactly as the ungated path did.
	stone_rough = rough_own * plate_w.x + rough_nb * plate_w.y
		+ rough_nb3 * plate_w.z;
	crack = crack_own * plate_w.x + crack_nb * plate_w.y
		+ crack_nb3 * plate_w.z;
	} else {
	surface = mix(mix(ash_color, rock_color, rock_mix), scorch_color,
		smoothstep(0.62, 0.95, drift) * 0.35 * (1.0 - rock_mix));
	stone_rough = clamp(mix(ash_roughness, rock_roughness, rock_mix)
		+ region_rough - 0.06 * (grain - 0.5) * detail, 0.0, 1.0);
	crack = 0.0;
	}
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

	ALBEDO = base * surface * 2.0 * albedo_probe;
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
	// `stone_rough` already carries the ash-vs-stone resolve, per cell, from the
	// surface composition above — blending it against ash a second time here
	// would apply that choice twice.
	// `stone_rough` already carries the per-cell resolve, the region/grain
	// offsets, the clamp and the crack — all in the original order.
	ROUGHNESS = stone_rough;
	// Packed ash in a crack is matte, whatever the slab either side of it is.
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
	// So take the gradient in CLOSED FORM from the two plate centres the
	// partition already found. f1 and f2 are plain distances to those centres,
	// so the crack field's gradient is
	//
	//     grad(f2 - f1) = normalize(uv - c2) - normalize(uv - c1)
	//
	// exactly — two normalizes, no extra cellular evaluation, and no screen
	// derivative of the crack field at all.
	//
	// That last part is what this change is FOR, and it is not a tidier
	// spelling of the same arithmetic. A screen-space difference of the crack
	// is only a gradient while the crack is wider than the quad doing the
	// differencing, and this one is not: `crack_width` is a constant in plate
	// units, so past a few metres of grazing ground the step is thinner than
	// the pixels sampling it and the difference returns sampling error rather
	// than a slope. The closed form has no such range limit — it is exact at
	// every distance, and the shimmer it removes was numerical, not artistic.
	//
	// The width stays the CONSTANT one, unchanged. Reading the relief at the
	// footprint-widened crack instead — the natural next thought, since the
	// closed form finally permits what a differenced one could not — was
	// measured on-GPU and is INERT: crawl 0.0037 either way, bit for bit, and
	// the seam read matched to within a repeat run at every swept distance.
	// The widening only becomes active past roughly the distance the fade
	// below has already closed, so there is nothing left for it to band-limit.
	// It is left out rather than carried as an unjustified difference.
	// Same uniform branch as the plate block: with the treatment off there is
	// no relief to compute.
	vec2 grad = vec2(0.0);
	// How much the seam's slope VARIES inside one pixel — the part of a groove
	// a normal cannot represent. Carried as cavity darkening after the bump.
	float seam_slope_var = 0.0;
	if (plates_enabled) {
	vec2 d1 = plate_uv - plate_c1;
	vec2 d2 = plate_uv - plate_c2;
	// inversesqrt of a floored square length: a fragment sitting exactly on a
	// centre would otherwise normalize a zero vector.
	vec2 gsep = d2 * inversesqrt(max(dot(d2, d2), 1e-12))
		- d1 * inversesqrt(max(dot(d1, d1), 1e-12));
	float cw_relief = max(crack_width, 1e-6);
	// The relief is read at the PIXEL CENTRE, and what it reads is finer than
	// the mark every guard below is keyed on: the crack profile turns over
	// inside a half-width, so its slope peaks at w/2 and is zero at both ends —
	// under-sampled a factor of two sooner than the crack itself. That
	// point-sample is the crawl.
	//
	// So integrate the groove across the pixel instead of sampling it. Two
	// moments come out and the treatment needs BOTH:
	//   - the MEAN tilt, which is what a normal can carry; and
	//   - the VARIANCE about it, which a normal cannot, because a pixel
	//     spanning a whole groove sees the two walls cancel exactly.
	// Filtering to the mean alone is correct and still erases the seam: past
	// the distance a groove resolves, the honest answer for the mean IS no net
	// tilt. The detail is not gone, it moved into the second moment — which is
	// carried as occlusion below.
	//
	// The profile integrated is a TOP HAT, because the seam-slope ceiling makes
	// it one. The raw slope peaks at 6*0.25/w * plate_scale, which at the
	// shipped width is ~40 against a ceiling of 0.4 — a hundredfold — so the
	// clamp binds across all but the outermost half-percent of the groove, and
	// what this shader actually applies is a constant-magnitude wall that flips
	// sign at the seam. `amp` is that plateau, reached through the same ceiling,
	// so the model follows the code rather than assuming it: open `crack_width`
	// far enough that the clamp stops binding and `amp` becomes the true peak.
	float amp = min(length(gsep) * (1.5 / cw_relief) * plate_scale
		* plate_mask_relief, 0.4);
	// The same plateau for the NEIGHBOURING cell. The profile below is shared —
	// it is a property of the footprint and the seam, not of either cell — so
	// the only per-cell quantity is this height, and blending the two over the
	// boundary footprint is what keeps the cavity continuous across a
	// slab-to-bare contact. See `plate_mask_relief_nb` above for why the mean
	// does not need this and the variance does.
	float amp_nb = min(length(gsep) * (1.5 / cw_relief) * plate_scale
		* plate_mask_relief_nb, 0.4);
	// And the third candidate's, for the coverage split below.
	float amp_nb3 = min(length(gsep) * (1.5 / cw_relief) * plate_scale
		* plate_mask_relief_nb3, 0.4);
	// The footprint is `edge_fw`, the ANALYTIC separator's screen rate — never
	// `fwidth(f2 - f1)`. That quantity is a cusp at the seam, so its screen
	// difference collapses on exactly the quads that straddle one: a filter
	// keyed on it widens everywhere EXCEPT where the seam is. That reads as a
	// free win on both instruments and is an artefact of a derivative
	// degenerating into its own epsilon floor, which varies by GPU and driver.
	// Same quantity and same reason as the boundary average above.
	float seam_h = max(edge_fw, 1e-6);
	float half_h = 0.5 * seam_h;
	float s_sep = f2 - f1;
	// Mean of a sign-flipping top hat over [s - h/2, s + h/2]. Its
	// antiderivative is min(|x|, w), which is EVEN, so the folded coordinate
	// `f2 - f1` serves directly: the straddling case (s < h/2) is carried by
	// the abs, and what comes out is the even function of the signed offset
	// that the fragment's own `gsep` then gives a direction to. At the seam the
	// two terms are equal and the mean is exactly zero, which is the
	// cancellation this whole term exists to account for.
	// The profile's SHAPE, with the per-cell height factored out: mean = amp *
	// prof, so this is the same closed form written once and reused by both
	// cells. It is dimensionless and depends only on the footprint's overlap
	// with the groove, which is why the two cells can share it.
	float prof = (min(s_sep + half_h, cw_relief)
		- min(abs(s_sep - half_h), cw_relief)) / seam_h;
	float mean_tilt = amp * prof;
	// Second moment. The top hat has magnitude `amp` wherever the footprint
	// overlaps the groove [-w, w], so E[u^2] is amp^2 times the covered
	// fraction of the pixel.
	float covered = clamp(max(min(s_sep + half_h, cw_relief)
		- max(s_sep - half_h, -cw_relief), 0.0) / seam_h, 0.0, 1.0);
	// Var = E[u^2] - E[u]^2, floored for float safety, with amp^2 factored out.
	// It is zero for a pixel that resolves one wall (covered 1, prof 1) and zero
	// for one that misses the groove entirely (both terms zero) — non-zero ONLY
	// where a pixel holds relief the mean is discarding. That is why carrying it
	// cannot soften a seam a player can still resolve, which is #306's third
	// acceptance criterion.
	float spread = max(covered - prof * prof, 0.0);
	// Split the cells' variances over the SAME three-candidate coverage weights
	// the substance, the slab mask, the roughness and the crack are split over
	// above, and for the same reason: a pixel straddling a contact contains
	// every one of those cells' seams, so gating the whole symmetric integral by
	// whichever cell owns the pixel centre steps the cavity between full and
	// zero as that centre crosses.
	//
	// `plate_w` rather than a pairwise `mix(..., plate_edge_w)`. Away from a
	// triple junction the two are arithmetically identical — the weights reduce
	// to `(1 - plate_edge_w, plate_edge_w, 0)` there — so this changes nothing a
	// player can resolve and nothing off a junction. At one, the pairwise form
	// takes the second-nearest cell outright, and that cell changes IDENTITY
	// abruptly while still holding near half the fragment's weight, so the
	// cavity inherits a zero-width step in exactly the quantity it exists to
	// filter. `spread` is common to all three, so splitting the squared heights
	// is arithmetically identical to splitting the three variances, two
	// multiplies cheaper.
	seam_slope_var = (amp * amp * plate_w.x + amp_nb * amp_nb * plate_w.y
		+ amp_nb3 * amp_nb3 * plate_w.z) * spread;
	// The tilt is INTO the groove, so it opposes the separator's gradient —
	// the same sign the differenced form and the closed-form `dcrack` both
	// carried, the latter by being negative by construction.
	//
	// This is inside the gate for a reason found by measurement: when the
	// relief was computed unconditionally, the grooves kept raking the light
	// with the treatment switched off, moving cave-chamber 29.61% away from
	// base. Shader reasoning said the gate was already exact; it was not.
	vec2 ghat = gsep * inversesqrt(max(dot(gsep, gsep), 1e-12));
	grad = -ghat * mean_tilt;
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
	// The first of those two guards did not actually do what it says. `plate_fw`
	// is the footprint of a whole PLATE, and a plate is some thirty times wider
	// than the seam drawn inside it, so dissolving on it is not "the same
	// schedule as the crack" — it does not engage until long after the crack has
	// stopped being drawable. In between, `crack_fixed` above is a step of
	// CONSTANT width (deliberately, per the note on the second-derivative), and
	// past about eight metres that width is narrower than one pixel. So this
	// term spent that whole range differencing a sub-pixel step, which is
	// precisely the jittering micro-relief the paragraph above describes.
	//
	// So dissolve on the CRACK's own footprint too. The ratio is how far the
	// seam has had to be stretched to stay a pixel wide, making 1.0 exactly the
	// distance at which it stops being resolvable; the fade is centred there.
	// Below 0.7 this multiplier is exactly 1.0, so every seam a player can
	// actually resolve keeps its full relief, unchanged.
	//
	// Measured on-GPU (tools/plate_crawl): the flickering fraction of the ground
	// falls 0.0052 -> 0.0027 against a plates-off control that reads 0.0000.
	//
	// The relief is most of what moves, but NOT all of it. A later session
	// measured `crack_relief = 0` at 0.0007 rather than the 0.0000 recorded
	// above, twice, by two independent routes (the uniform zeroed outright, and
	// this fade forced closed) agreeing to the digit on flicker, peak and
	// spread, against a plates-off control still reading 0.0000. What is left
	// at that floor is the substance and slab boundary — the step this issue was
	// originally filed on. Absolute levels here are not portable between
	// machines and the tool says so; the ordering is what carries.
	grad *= 1.0 - smoothstep(0.7, 1.3, crack_fw * 1.2 / max(crack_width, 1e-6));
	// The magnitude bound is the SLOPE A SEAM CAN HAVE, not a catastrophe
	// backstop. `bump` adds `grad * crack_relief` to the horizontal components
	// of a unit normal, so the ceiling is a tilt: at the shipped crack_relief
	// this bounds it by atan(0.4 * 1.1) ~= 24 degrees, the wall of a shallow
	// groove a few centimetres across that ash settles into. A ceiling set only
	// high enough to stop one degenerate quad flipping a normal allows
	// atan(1.5 * 1.1) ~= 59 degrees, which no seam in this ground has — so every
	// under-sampled quad claiming an impossible slope passed through it
	// untouched, and that is what the fade above was left carrying alone.
	//
	// A bound on the SLOPE and the fade above are different levers, and the
	// difference is the whole reason this one is here. The fade is keyed on
	// distance, so it removes shimmer and near-field seam read together at
	// about 1:1 — measured on-GPU with both instruments in one sitting, pulling
	// the fade window in to (0.40, 0.75) buys 65% of the relief's flicker and
	// takes 65-74% of the seam coverage at every swept distance with it, which
	// is the softening #306's third acceptance criterion forbids. This is keyed
	// on the slope a fragment claims, which is what actually distinguishes an
	// aliased sample from a resolved one, so it buys the SAME 65% while leaving
	// the near field untouched: coverage at 6 m is 0.00045 either way, and the
	// loss past it stays within 21% against the fade's 65-74%. What it spends
	// instead is rake strength, 22% at 6 m — every seam still there, raking
	// slightly less hard. Below 0.4 the near field goes too (0.2 already costs
	// 13% of the 6 m coverage), so this is the knee rather than a floor.
	float grad_len = length(grad);
	grad = grad_len > 0.4 ? grad * (0.4 / grad_len) : grad;
	// The variance takes the PLATE resolution cutoff and nothing else. Once a
	// pixel spans a whole plate there are no per-plate seams left to have a
	// second moment about, exactly as the substance and slab mask converge on
	// their means above — so this one is a statement about what exists, not a
	// fade bought to hide shimmer.
	//
	// It deliberately does NOT take the crack-footprint fade or the slope
	// ceiling. Those two bound what the NORMAL may claim, and the read they
	// give up is precisely what this term carries instead; applying them here
	// would hand back the seam they were spent on. Variance scales as the
	// square of the amplitude it is a variance of, so the cutoff enters
	// squared.
	seam_slope_var *= plate_resolved * plate_resolved;
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

	// The seam relief the normal above could not carry, kept as OCCLUSION.
	//
	// A groove narrower than the pixel drawing it has no net tilt — its two
	// walls cancel — but it is not flat, and shading it as flat is exactly how
	// a seam vanishes into the far field. What such a groove still does is
	// OCCLUDE: light reaching the bottom of it is blocked by its own walls, and
	// that survives the averaging the tilt does not, because occlusion does not
	// cancel between two opposing walls the way a signed slope does.
	//
	// Roughness is the textbook home for a filtered normal distribution
	// (Toksvig, LEAN, geometric specular AA all terminate there) and it was
	// measured on #306 and is INERT on this surface — a strength control at 8x
	// and an albedo positive control at 400x together say the channel, not the
	// coefficient, is what has no authority here: the ground is largely diffuse
	// at SPECULAR = 0.18 under a low sun, so a lobe widening of the physically
	// correct size lands below both the instrument's threshold and a player's.
	// Godot's AO built-in is the other candidate and was NOT measured; it is
	// passed over by reasoning, which is a weaker claim and is recorded as one:
	// AO acts on ambient light, and the same low sun that makes the roughness
	// move invisible is what dominates this surface. Cavity darkening on the
	// finished albedo is where a diffuse surface's self-occlusion shows without
	// depending on that argument, which is why it is done here.
	//
	// This lands on the FINISHED pixel rather than per cell, unlike the crack
	// darkening above, and that is correct rather than a convenience: the crack
	// is a per-cell material choice gated by that cell's own slab mask, while
	// this is a statement about how much unresolved groove the PIXEL contains —
	// a footprint quantity that has no per-cell answer.
	//
	// Scaled by `crack_relief * detail` because that is what the bump above
	// applies to the same slope, and squared because it is a variance of it.
	float seam_gain = crack_relief * detail;
	float seam_var = seam_slope_var * seam_gain * seam_gain;
	// A saturating cavity rather than `1 - k*var`: the variance is unbounded
	// from this shader's point of view (it scales with an artist-set relief and
	// a uniform gain), and a linear darkening would go NEGATIVE before anyone
	// noticed. This form is monotone, bounded to (0, 1], and — the property
	// that matters — is EXACTLY 1.0 when the variance is zero, so the near
	// field, the far field past the plate cutoff, and the whole default-off
	// path are arithmetically untouched rather than approximately so.
	//
	// The denominator is floored for the same reason `crack_width` is above:
	// this divides by a UNIFORM, and `hint_range` bounds the inspector rather
	// than the value a caller may set. A sufficiently negative `seam_cavity`
	// would otherwise drive it through zero — an infinite or negative albedo
	// rather than a clamped-looking one. The floor cannot bite at the shipped
	// domain, where the denominator is at least 1.0.
	ALBEDO *= 1.0 / max(1.0 + seam_cavity * seam_var, 1e-3);
}
