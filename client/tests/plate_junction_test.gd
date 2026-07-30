extends Node
## Proves the plate boundary average stays CONTINUOUS where any number of plates
## meet (#573), and that it is unchanged everywhere else.
##
## `terrain_plate_edge_blend` decides how much of a fragment belongs to a
## neighbouring plate. It does not decide WHICH neighbour, and #482 took `id2`
## outright. At a Voronoi triple junction the owning cell stays the same while
## the second- and third-nearest swap across their bisector, so `id2` changes
## IDENTITY abruptly while that weight is still near a half. The blended value
## then jumps by the whole contrast between two substances — a fresh zero-width
## step inside the very region the averaging exists to remove, and one the
## averaging cannot filter because it is a step in *which* value is blended
## rather than in *how much*.
##
## ## What this test can and cannot prove — read this before trusting it
##
## The partition is reimplemented HERE, in GDScript. It is not the shader. Those
## values are fragment-local expressions inside a `plates_enabled` branch, never
## uniforms, so nothing can read them back, and observing them needs a windowed
## GPU run of an opt-in treatment that `--headless` CI cannot do (the same
## constraint `crack_relief_parity_test` records). GDScript is also double
## precision where the GPU is single, so this mirror does NOT reproduce the
## shader's partition bit for bit and no assertion here depends on it doing so.
##
## What it proves is the WEIGHTING ALGEBRA: given a partition with a triple
## junction, the three-way rule is continuous across the second/third identity
## swap and the pairwise rule is not. That property is exact and holds for any
## hash, which is why the mirror's precision does not enter into it.
##
## What keeps the mirror honest about the shader is the SOURCE GUARD below: if
## the shaders stop calling the three-way split, stop feeding it the isotropic
## footprint, or stop folding the whole search window in at a higher-order
## junction, this test fails even though its own arithmetic is untouched.
## Continuity proven here plus those calls proven present in both shaders is the
## join.
##
## ## The seam cavity arms (#584, #589)
##
## `_check_cavity_continuity` probes the SEAM CAVITY as well as the substance,
## because the cavity is not a linear blend — each cell's height is clamped and
## squared before the weights apply. It reports the cavity DECOMPOSED: the
## three-way split makes the per-cell amplitudes continuous, and the separator
## footprint must likewise stay continuous when `c2` and `c3` exchange labels.
## A footprint built only from the direction to `c2` jumps even though `f2`
## itself stays smooth, so both `spread` and the full cavity are asserted under
## 4x refinement rather than merely bounded.
##
## Run: godot --headless --path client res://tests/plate_junction_test.tscn

const GROUND_SHADER_PATH := "res://shaders/terrain.gdshader"
const CONTACT_SHADER_PATH := "res://shaders/cave_terrain_contact.gdshader"
const PARTITION_PATH := "res://shaders/terrain_surface.gdshaderinc"

## The substance palette, taken from the shipping uniform defaults so the step
## this probe measures is the real contrast between two named substances rather
## than an invented one.
const ROCK := Vector3(0.30, 0.27, 0.25)
const BASALT := Vector3(0.22, 0.21, 0.22)
const FERRIC := Vector3(0.42, 0.26, 0.18)
const PALE := Vector3(0.54, 0.51, 0.45)

## One pixel's reach in plate-uv units. A plate is ~1.0 uv across, so this is a
## pixel spanning a twentieth of a plate — the middle distance where the boundary
## is subpixel and the averaging is live. Nearer than this the contact resolves
## and every weight below is 0.0; further and `plate_resolved` has already
## collapsed the plates to their mean.
const FOOTPRINT := 0.05

## Samples around the junction for the coarse pass. The fine pass uses 4x this.
const ARC_SAMPLES := 720
## How far from the triple point the probe circles it. Small enough that
## `f2 - f1` stays inside the averaging band (so the neighbour weight is
## non-zero, which is what acceptance criterion 1 requires), large enough that
## the three cells are distinguishable.
const ARC_RADIUS := 0.015

## Refining the sampling 4x must shrink a continuous function's largest adjacent
## step by roughly 4x. Allowing 0.5 rather than demanding 0.25 leaves room for
## the arc's curvature and for the sample grid landing differently; a jump
## discontinuity does not shrink at all, so the two cases stay far apart.
const CONTINUITY_RATIO := 0.5
## Below this a step is indistinguishable from smooth variation at this sampling
## density. The substance contrasts are ~0.2-0.3 apart, so a surviving identity
## step reads an order of magnitude above it.
const CONTINUOUS_STEP_MAX := 0.01
## The control must clear this, or the probe is not actually crossing a junction
## and the whole test is vacuous.
const CONTROL_STEP_MIN := 0.02
## At a degenerate four-plate vertex the remaining step must stay under the
## pairwise rule's. Measured at 49% at a true four-fold vertex — the fourth plate
## is exactly equidistant there, so the third's label swap carries as much weight
## as it ever can, and three carried candidates cannot cover it at all.
##
## This bound is a REGRESSION GUARD, not a target: it is set to catch the blend
## falling back toward the unfixed 100%, not to encode 49% as acceptable. Such
## vertices are also measure-zero in a jittered grid — a generic Voronoi diagram
## has only three-fold vertices, and a fourth plate exactly equidistant needs
## cocircularity — so this is an isolated point, against the junction LINES the
## isolated arm covers exactly.
const DEGENERATE_STEP_RATIO_MAX := 0.60

## The seam cavity's shipped constants, read from the uniform defaults both
## shaders declare. `AMP_GAIN / CRACK_WIDTH * PLATE_SCALE` is ~40 against a
## ceiling of 0.4, so the clamp binds wherever a cell draws a slab at all — the
## per-cell height is effectively the ceiling gated by the binary slab mask, and
## the cavity is that squared, split by coverage, times `spread`.
const PLATE_SCALE := 0.85
const CRACK_WIDTH := 0.032
const AMP_GAIN := 1.5
const AMP_CEILING := 0.4

## Closing the old footprint jump removes energy the discontinuity itself
## contributed. Both shaders restore the measured near-field read only inside
## the smooth junction authority; away from it this factor is exactly 1.0.
const JUNCTION_READ_GAIN := 1.05

## The cavity's own step thresholds. It is bounded by `AMP_CEILING^2` = 0.16
## rather than by a substance contrast, so it needs its own scale rather than
## reusing the substance arm's. Both are set the same way: the control must clear
## a floor the probe can actually resolve, and a continuous result must land an
## order of magnitude below the jump it replaces.
const CAVITY_CONTROL_STEP_MIN := 0.01
const CAVITY_CONTINUOUS_STEP_MAX := 0.005
var _failures: PackedStringArray = []


func _ready() -> void:
	_check_source_guards()
	var isolated := _find_triple_junction(true)
	if isolated.is_empty():
		_fail("no ISOLATED triple junction found in the scanned region — the "
			+ "probe has nothing to cross and the continuity assertion would "
			+ "pass vacuously")
	else:
		_check_junction_continuity(isolated["uv"])
		_check_cavity_continuity(isolated["uv"])
	var degenerate := _find_triple_junction(false)
	if degenerate.is_empty():
		# Not a failure. A region may genuinely contain no four-plate vertex; the
		# guarantee being measured there is a bound, not a law.
		print("DEGENERATE none found in the scanned region — skipping the "
			+ "four-plate bound")
	else:
		_check_degenerate_vertex_bound(degenerate["uv"])
	_check_footprint_coverage_authority()
	_check_exact_higher_order_swap_footprint()
	_check_window_activation_continuity()
	_check_exact_swap_reach_handoff()
	_check_window_grid_boundary_continuity()
	_check_activation_order_domain()
	_check_two_cell_reduction()
	_report()


# ---------------------------------------------------------------------------
# The mirror. Mirrors terrain_surface.gdshaderinc exactly in SHAPE; see the
# precision note in the header.
# ---------------------------------------------------------------------------

## GLSL `step`. Godot's global `step()` is a DIFFERENT function — it snaps a
## value to a multiple — so using it here would silently compute nonsense.
func _glsl_step(edge: float, x: float) -> float:
	return 0.0 if x < edge else 1.0


func _hash3(p: Vector3) -> float:
	var d := p.dot(Vector3(127.1, 311.7, 74.7))
	var s := sin(d) * 43758.5453
	return s - floor(s)


## The three nearest identities plus the fourth-nearest distance, as
## `terrain_plates` reports them.
func _plates(uv: Vector2, radius: int = 2) -> Dictionary:
	var base := Vector2(floor(uv.x), floor(uv.y))
	var f1 := 1000.0
	var f2 := 1000.0
	var f3 := 1000.0
	# The FOURTH distance. Its identity is deliberately not carried: the distance
	# tells production and this mirror when the fixed three-candidate list reaches
	# its tail and the symmetric whole-window answer must take over. Carried in
	# this same loop rather than a second pass over the window: the searches below
	# evaluate this tens of thousands of times, and a duplicate partition loop
	# doubled the whole test's runtime against CI's 180 s budget.
	var f4 := 1000.0
	var id := base
	var c1 := base
	var c2 := base
	var c3 := base
	var id2 := base
	var id3 := base
	for j in range(-radius, radius + 1):
		for i in range(-radius, radius + 1):
			var cell := base + Vector2(float(i), float(j))
			var jitter := Vector2(
				_hash3(Vector3(cell.x, cell.y, 0.0)),
				_hash3(Vector3(cell.x, cell.y, 7.0)))
			var centre := cell + Vector2(0.15, 0.15) + 0.7 * jitter
			var d := uv.distance_to(centre)
			if d < f1:
				f4 = f3
				f3 = f2
				c3 = c2
				id3 = id2
				f2 = f1
				c2 = c1
				id2 = id
				f1 = d
				c1 = centre
				id = cell
			elif d < f2:
				f4 = f3
				f3 = f2
				c3 = c2
				id3 = id2
				f2 = d
				c2 = centre
				id2 = cell
			elif d < f3:
				f4 = f3
				f3 = d
				c3 = centre
				id3 = cell
			elif d < f4:
				f4 = d
	return {
		"id": id, "id2": id2, "id3": id3,
		"f1": f1, "f2": f2, "f3": f3, "f4": f4,
		"c1": c1, "c2": c2, "c3": c3,
	}


## `terrain_plate_substance`, as a colour. Chained mixes with GLSL `step`, so
## each later threshold overrides the earlier one exactly.
func _substance(id: Vector2) -> Vector3:
	var pick := _hash3(Vector3(id.x * 1.7, id.y * 1.7, 3.0))
	var c := ROCK
	c = c.lerp(BASALT, _glsl_step(0.38, pick))
	c = c.lerp(FERRIC, _glsl_step(0.66, pick))
	c = c.lerp(PALE, _glsl_step(0.86, pick))
	return c


## The slab mask — measured as the dominant half of the boundary residual, so it
## belongs in the probed value alongside the substance.
func _is_slab(id: Vector2) -> float:
	return _glsl_step(0.60, _hash3(Vector3(id.x * 2.3, id.y * 2.3, 19.0)))


## The legacy two-cell separator footprint. This remains the exact answer away
## from a junction and is the reduction control for the symmetric form below.
func _pair_separator_footprint(
		uv: Vector2, c1: Vector2, c2: Vector2) -> float:
	var e1 := uv - c1
	var e2 := uv - c2
	var gsep := e2.normalized() - e1.normalized()
	return FOOTPRINT * (absf(gsep.x) + absf(gsep.y))


func _candidate_coverage(
		d: float, f1: float, footprint: float = FOOTPRINT) -> float:
	return 1.0 - smoothstep(
		0.0, maxf(footprint, 1e-6), d - f1)


func _coverage_authority(coverage: float) -> float:
	return smoothstep(0.0, 0.05, coverage)


func _covered_junction(
		p: Dictionary, footprint: float = FOOTPRINT) -> float:
	var coverage := _candidate_coverage(
		float(p["f3"]), float(p["f1"]), footprint)
	return _window_junction(p, footprint) * _coverage_authority(coverage)


func _higher_junction(
		p: Dictionary, footprint: float = FOOTPRINT) -> float:
	return 1.0 - smoothstep(
		0.0, maxf(footprint, 1e-6),
		float(p["f4"]) - float(p["f3"]))


## The identity-free whole-window separator mirror. Weighted pairwise RMS is
## derived from moments, so all covered candidates contribute in O(n) and no
## ordered final centre exists to swap at a higher-order vertex.
func _full_window_separator_footprint(
		uv: Vector2,
		p: Dictionary,
		footprint: float = FOOTPRINT,
		radius: int = 2) -> float:
	var base := Vector2(floor(uv.x), floor(uv.y))
	var total := 0.0
	var weight_sq_total := 0.0
	var dx_total := 0.0
	var dx_sq_total := 0.0
	var dy_total := 0.0
	var dy_sq_total := 0.0
	for j in range(-radius, radius + 1):
		for i in range(-radius, radius + 1):
			var cell := base + Vector2(float(i), float(j))
			var jitter := Vector2(
				_hash3(Vector3(cell.x, cell.y, 0.0)),
				_hash3(Vector3(cell.x, cell.y, 7.0)))
			var centre := cell + Vector2(0.15, 0.15) + 0.7 * jitter
			var e := uv - centre
			var weight := _candidate_coverage(
				e.length(), float(p["f1"]), footprint)
			var n := e.normalized()
			var px := n.x * footprint
			var py := n.y * footprint
			total += weight
			weight_sq_total += weight * weight
			dx_total += weight * px
			dx_sq_total += weight * px * px
			dy_total += weight * py
			dy_sq_total += weight * py * py
	var pair_total := 0.5 * (total * total - weight_sq_total)
	if pair_total <= 1e-12:
		return _pair_separator_footprint(uv, p["c1"], p["c2"])
	var rms_dx := sqrt(maxf(
		(total * dx_sq_total - dx_total * dx_total) / pair_total, 0.0))
	var rms_dy := sqrt(maxf(
		(total * dy_sq_total - dy_total * dy_total) / pair_total, 0.0))
	return rms_dx + rms_dy


## Mirrors `terrain_plate_separator_footprint`. Pairwise authority is preserved
## exactly until the third plate enters the footprint. At a junction, all three
## pair separators contribute through symmetric coverage weights; when a fourth
## enters, the whole-window RMS removes the fixed-list tail.
func _separator_footprint(p: Dictionary, uv: Vector2) -> float:
	var pair_fw := _pair_separator_footprint(uv, p["c1"], p["c2"])
	var triple_authority := _covered_junction(p)
	if triple_authority <= 0.0:
		return pair_fw
	var edge13 := _pair_separator_footprint(uv, p["c1"], p["c3"])
	var edge23 := _pair_separator_footprint(uv, p["c2"], p["c3"])
	var g2 := _candidate_coverage(float(p["f2"]), float(p["f1"]))
	var g3 := _candidate_coverage(float(p["f3"]), float(p["f1"]))
	var pair_sum := g2 + g3 + g2 * g3
	var triple := pair_sum / (
		g2 / maxf(pair_fw, 1e-6) + g3 / maxf(edge13, 1e-6)
			+ g2 * g3 / maxf(edge23, 1e-6))
	var higher_junction := _higher_junction(p)
	var footprint := lerpf(pair_fw, triple, triple_authority)
	if float(p.get("plate_resolved", 1.0)) <= 0.0:
		return footprint
	if higher_junction <= 0.0:
		return footprint
	var fourth_coverage := _candidate_coverage(
		float(p["f4"]), float(p["f1"]))
	var fourth_authority := _coverage_authority(fourth_coverage)
	var identity_safe_tail := pair_fw
	if fourth_authority > 0.0:
		identity_safe_tail = lerpf(
			pair_fw,
			_full_window_separator_footprint(uv, p),
			fourth_authority)
	return lerpf(footprint, identity_safe_tail, higher_junction)


## Mirrors the current shader read compensation. The coverage-authority probe
## below requires this to stay at 1.0 unless the third plate actually reaches
## the fragment.
func _junction_read_gain(
		p: Dictionary, footprint: float = FOOTPRINT) -> float:
	return lerpf(
		1.0, JUNCTION_READ_GAIN, _covered_junction(p, footprint))


## `terrain_plate_edge_blend(f1, f2, edge_fw * 0.5)`, with `edge_fw`
## symmetrized at a junction and projected through both screen derivatives.
## Axis-aligned derivatives of magnitude FOOTPRINT stand in for the pixel.
func _edge_weight(p: Dictionary, uv: Vector2) -> float:
	var edge_fw := _separator_footprint(p, uv)
	var half: float = maxf(edge_fw * 0.5, 1e-6)
	return 0.5 * (1.0 - smoothstep(0.0, half, p["f2"] - p["f1"]))


## `terrain_plate_blend_weights(f1, f2, f3, pair_w, plate_fw)` — the coverage
## split across the three candidates, as (owning, second, third).
func _blend_weights(p: Dictionary, pair_w: float) -> Vector3:
	var w: float = maxf(FOOTPRINT, 1e-6)
	var pairwise := Vector3(1.0 - pair_w, pair_w, 0.0)
	var g2: float = 1.0 - smoothstep(0.0, w, p["f2"] - p["f1"])
	var g3: float = 1.0 - smoothstep(0.0, w, p["f3"] - p["f1"])
	var symmetric := Vector3(1.0, g2, g3) / (1.0 + g2 + g3)
	var j: float = 1.0 - smoothstep(0.0, w, p["f3"] - p["f2"])
	return pairwise.lerp(symmetric, j)


## The blended cell signature: substance rgb plus the slab mask, which is what
## both shaders carry per cell into their composition. Returned as a 4-vector
## flattened into an array so the two rules can be compared component-wise.
##
## `use_third` false is the #482 rule — the whole neighbour share to `id2`.
## True is the #499 rule — coverage split symmetrically across all three.
func _blend(uv: Vector2, use_third: bool) -> PackedFloat64Array:
	var p := _plates(uv)
	var pair_w: float = _edge_weight(p, uv)
	var w := (_blend_weights(p, pair_w) if use_third
		else Vector3(1.0 - pair_w, pair_w, 0.0))
	var col := _substance(p["id"]) * w.x + _substance(p["id2"]) * w.y \
		+ _substance(p["id3"]) * w.z
	var mask: float = _is_slab(p["id"]) * w.x + _is_slab(p["id2"]) * w.y \
		+ _is_slab(p["id3"]) * w.z
	return PackedFloat64Array([col.x, col.y, col.z, mask])


## The symmetric whole-window answer. Every candidate in the same 5x5
## search as `_plates` receives a weight derived only from its distance excess
## over the nearest cell. No ordered "last carried candidate" exists, so swapping
## any equidistant labels cannot move the result.
func _full_window_blend(
		uv: Vector2,
		p: Dictionary,
		footprint: float = FOOTPRINT,
		radius: int = 2) -> PackedFloat64Array:
	var base := Vector2(floor(uv.x), floor(uv.y))
	var w: float = maxf(footprint, 1e-6)
	var total := 0.0
	var out := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	for j in range(-radius, radius + 1):
		for i in range(-radius, radius + 1):
			var cell := base + Vector2(float(i), float(j))
			var jitter := Vector2(
				_hash3(Vector3(cell.x, cell.y, 0.0)),
				_hash3(Vector3(cell.x, cell.y, 7.0)))
			var centre := cell + Vector2(0.15, 0.15) + 0.7 * jitter
			var d := uv.distance_to(centre)
			var weight: float = 1.0 - smoothstep(
				0.0, w, d - float(p["f1"]))
			var col := _substance(cell)
			out[0] += col.x * weight
			out[1] += col.y * weight
			out[2] += col.z * weight
			out[3] += _is_slab(cell) * weight
			total += weight
	if total <= 0.0:
		_fail("the whole-window blend accumulated no coverage — the nearest "
			+ "cell must always contribute one")
		return out
	for k in range(0, out.size()):
		out[k] /= total
	return out


## The whole-window equivalent of the cavity's per-cell factor. The plateau
## height is clamped and squared BEFORE weighting, exactly as the shaders do;
## averaging the slab mask first would be a different nonlinear operation.
func _full_window_cavity_amps(
		uv: Vector2,
		p: Dictionary,
		footprint: float = FOOTPRINT,
		radius: int = 2) -> float:
	var e1 := uv - p["c1"] as Vector2
	var e2 := uv - p["c2"] as Vector2
	var k: float = (
		e2.normalized() - e1.normalized()
	).length() * (AMP_GAIN / CRACK_WIDTH) * PLATE_SCALE
	var base := Vector2(floor(uv.x), floor(uv.y))
	var w: float = maxf(footprint, 1e-6)
	var total := 0.0
	var out := 0.0
	for j in range(-radius, radius + 1):
		for i in range(-radius, radius + 1):
			var cell := base + Vector2(float(i), float(j))
			var jitter := Vector2(
				_hash3(Vector3(cell.x, cell.y, 0.0)),
				_hash3(Vector3(cell.x, cell.y, 7.0)))
			var centre := cell + Vector2(0.15, 0.15) + 0.7 * jitter
			var d := uv.distance_to(centre)
			var weight: float = 1.0 - smoothstep(
				0.0, w, d - float(p["f1"]))
			var amp := minf(k * _is_slab(cell), AMP_CEILING)
			out += amp * amp * weight
			total += weight
	if total <= 0.0:
		_fail("the whole-window cavity accumulated no coverage — the nearest "
			+ "cell must always contribute one")
		return out
	return out / total


func _window_activation(p: Dictionary, footprint: float) -> float:
	var w: float = maxf(footprint, 1e-6)
	var reach_margin: float = maxf(
		w - (float(p["f4"]) - float(p["f1"])), 0.0)
	var within_reach := _glsl_step(1e-6, reach_margin)
	return within_reach * (1.0 - smoothstep(
		0.0, maxf(reach_margin, 1e-6),
		float(p["f4"]) - float(p["f3"])))


func _window_junction(p: Dictionary, footprint: float) -> float:
	return 1.0 - smoothstep(
		0.0, maxf(footprint, 1e-6),
		float(p["f3"]) - float(p["f2"]))


func _window_reachable(p: Dictionary, footprint: float) -> bool:
	return float(p["f4"]) - float(p["f1"]) <= maxf(footprint, 1e-6)


func _synthetic_three_way_value(
		f2: float, f3: float, pair_w: float, footprint: float) -> float:
	var g2 := 1.0 - smoothstep(0.0, footprint, f2)
	var g3 := 1.0 - smoothstep(0.0, footprint, f3)
	var symmetric := (
		0.20 + 0.80 * g2 + 0.10 * g3
	) / (1.0 + g2 + g3)
	var pairwise := lerpf(0.20, 0.80, pair_w)
	var junction := 1.0 - smoothstep(0.0, footprint, f3 - f2)
	return lerpf(pairwise, symmetric, junction)


func _synthetic_window_value(
		f2: float, f3: float, f4: float, footprint: float) -> float:
	var g2 := 1.0 - smoothstep(0.0, footprint, f2)
	var g3 := 1.0 - smoothstep(0.0, footprint, f3)
	var g4 := 1.0 - smoothstep(0.0, footprint, f4)
	return (
		0.20 + 0.80 * g2 + 0.10 * g3 + 0.90 * g4
	) / (1.0 + g2 + g3 + g4)


## The pre-fix scalar handoff. Kept as the positive control for the exact
## third/fourth swap at the footprint boundary.
func _synthetic_legacy_reach_value(
		f3: float, f4: float, footprint: float) -> float:
	var f2 := footprint * 0.50
	var pair_w := 0.50
	var current := _synthetic_three_way_value(
		f2, f3, pair_w, footprint)
	var full := _synthetic_window_value(f2, f3, f4, footprint)
	var partition := {"f1": 0.0, "f3": f3, "f4": f4}
	return lerpf(current, full, _window_activation(partition, footprint))


## Mirrors the shipping composition at the reach cutoff.
func _synthetic_reach_value(
		f3: float, f4: float, footprint: float) -> float:
	var f2 := footprint * 0.50
	var pair_w := 0.50
	var current := _synthetic_three_way_value(
		f2, f3, pair_w, footprint)
	var partition := {"f1": 0.0, "f2": f2, "f3": f3, "f4": f4}
	if not _window_reachable(partition, footprint):
		return current
	var pairwise := lerpf(0.20, 0.80, pair_w)
	var full := _synthetic_window_value(f2, f3, f4, footprint)
	return lerpf(pairwise, full, _window_junction(partition, footprint))


## Keep the established three-way answer bit-identical except where the fourth
## candidate enters the same pixel footprint. At the exact third/fourth identity
## swap this is wholly the symmetric window answer, so the discontinuous
## fixed-list term has zero authority.
func _window_blend(uv: Vector2) -> PackedFloat64Array:
	var p := _plates(uv)
	var current := _blend(uv, true)
	if not _window_reachable(p, FOOTPRINT):
		return current
	var pairwise := _blend(uv, false)
	var full := _full_window_blend(uv, p)
	var junction := _window_junction(p, FOOTPRINT)
	for k in range(0, current.size()):
		current[k] = lerpf(pairwise[k], full[k], junction)
	return current


## Generalize the nonlinear per-cell cavity factor through the same composition
## as slab/surface/roughness/crack: pairwise base toward the normalized 5x5
## window under the junction ramp. The reach check may skip work only after the
## fourth candidate's weight has converged to zero.
func _window_cavity_amps(uv: Vector2) -> float:
	var p := _plates(uv)
	var current: float = _cavity_parts(uv, true)["amps"]
	if not _window_reachable(p, FOOTPRINT):
		var gain := _junction_read_gain(p)
		return current * gain * gain
	var pairwise: float = _cavity_parts(uv, false)["amps"]
	var full := _full_window_cavity_amps(uv, p)
	var junction := _window_junction(p, FOOTPRINT)
	var gain := _junction_read_gain(p)
	return lerpf(pairwise, full, junction) * gain * gain


## The SEAM CAVITY's per-fragment value, `seam_slope_var` (#554, #584).
##
## This is a separate probe from `_blend` rather than another component of it,
## because the cavity is not a linear blend of a per-cell quantity. Each cell's
## contribution passes through a CEILING (`min(..., 0.4)`) and is then SQUARED,
## and it is scaled by `spread` — a property of the footprint and the seam that
## every candidate shares. A rule that is continuous for a linear blend is not
## automatically continuous once the per-cell term is clamped and squared, so
## the cavity is measured as the shader actually computes it.
##
## `sheet` and `plate_resolved` are 1.0 here, exactly as `_blend` assumes: that
## is the resolved case, where the per-cell contrast — and so the step being
## probed — is largest.
## The cavity splits into two factors that fail differently, so it is returned
## decomposed and the arms below assert against each:
##
##   `amps`   — the coverage-weighted sum of squared per-cell heights. This is
##              the per-cell quantity #584 re-points at `plate_w`, and it is what
##              that change makes continuous.
##   `spread` — the top hat's variance over the pixel, common to every candidate.
##              Its `edge_fw` must be symmetric in the second and third
##              separator gradients at a junction so exchanging their labels
##              cannot change the footprint.
func _cavity_parts(uv: Vector2, use_third: bool) -> Dictionary:
	var p := _plates(uv)
	var pair_w: float = _edge_weight(p, uv)
	var w := (_blend_weights(p, pair_w) if use_third
		else Vector3(1.0 - pair_w, pair_w, 0.0))
	var e1 := uv - p["c1"] as Vector2
	var e2 := uv - p["c2"] as Vector2
	var gsep := e2.normalized() - e1.normalized()
	# The per-cell plateau, through the shipped ceiling. `plate_mask_relief*` is
	# `sheet * slab_*`, and `sheet` is 1.0 here, so the gate is the binary slab.
	var k: float = gsep.length() * (AMP_GAIN / CRACK_WIDTH) * PLATE_SCALE
	var a1: float = minf(k * _is_slab(p["id"]), AMP_CEILING)
	var a2: float = minf(k * _is_slab(p["id2"]), AMP_CEILING)
	var a3: float = minf(k * _is_slab(p["id3"]), AMP_CEILING)
	var edge_fw := _separator_footprint(p, uv)
	var spread := _cavity_spread(p, edge_fw)
	return {
		"amps": a1 * a1 * w.x + a2 * a2 * w.y + a3 * a3 * w.z,
		"spread": spread,
		"read_gain": _junction_read_gain(p),
	}


## The integrated top-hat variance for a supplied separator footprint. Keeping
## this separate lets the regression arm feed the old c1/c2-only footprint
## through the same cavity algebra as the fixed path.
func _cavity_spread(p: Dictionary, edge_fw: float) -> float:
	var seam_h: float = maxf(edge_fw, 1e-6)
	var half_h: float = 0.5 * seam_h
	var s_sep: float = p["f2"] - p["f1"]
	var prof: float = (minf(s_sep + half_h, CRACK_WIDTH)
		- minf(absf(s_sep - half_h), CRACK_WIDTH)) / seam_h
	var covered: float = clampf(maxf(minf(s_sep + half_h, CRACK_WIDTH)
		- maxf(s_sep - half_h, -CRACK_WIDTH), 0.0) / seam_h, 0.0, 1.0)
	return maxf(covered - prof * prof, 0.0)


func _legacy_cavity_spread(uv: Vector2) -> float:
	var p := _plates(uv)
	var edge_fw := _pair_separator_footprint(uv, p["c1"], p["c2"])
	return _cavity_spread(p, edge_fw)


## `seam_slope_var` as both shaders compute it — the product of the two factors
## above, written once so the closed form has a single copy.
func _cavity(uv: Vector2, use_third: bool) -> float:
	var parts := _cavity_parts(uv, use_third)
	var gain: float = parts["read_gain"]
	return float(parts["amps"]) * float(parts["spread"]) * gain * gain


# ---------------------------------------------------------------------------
# The probe
# ---------------------------------------------------------------------------

## Locate a point where the three nearest centres are near-equidistant. Coarse
## grid, then a shrinking local search — the objective is smooth, so this
## converges without needing a derivative.
##
## `isolated` selects between the two cases, which carry DIFFERENT guarantees:
##
##   true  — a genuine triple junction: exactly three plates within reach, the
##           fourth a clear footprint further out. This is the case #499
##           describes, and the blend is exactly continuous here.
##   false — a degenerate vertex where a fourth plate is equidistant with the
##           third. The shaders carry three candidates, so the third's LABEL can
##           still swap with an uncarried fourth while it holds weight. That
##           residual is bounded and measured rather than claimed absent.
func _find_triple_junction(isolated: bool) -> Dictionary:
	var best_uv := Vector2.ZERO
	var best := INF
	for gy in range(0, 160):
		for gx in range(0, 160):
			var uv := Vector2(float(gx) * 0.05, float(gy) * 0.05) + Vector2(3.3, 7.1)
			var score := _junction_score(uv, isolated)
			if score < best:
				best = score
				best_uv = uv
	var stepsize := 0.05
	for _refine in range(0, 40):
		var improved := false
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var uv := best_uv + Vector2(float(dx), float(dy)) * stepsize
				var score := _junction_score(uv, isolated)
				if score < best:
					best = score
					best_uv = uv
					improved = true
		if not improved:
			stepsize *= 0.5
	# A genuine vertex has the three within a hair. Anything looser and the arc
	# may never cross the second/third bisector.
	if best > 0.002:
		return {}
	return {"uv": best_uv, "score": best}


## How far a point is from being the wanted kind of vertex. Rejecting outright
## (rather than penalising) keeps the isolated search from converging on a
## degenerate vertex, which is what the unconstrained objective naturally finds —
## maximal degeneracy minimises it best.
func _junction_score(uv: Vector2, isolated: bool) -> float:
	var p := _plates(uv)
	var score: float = maxf(p["f2"] - p["f1"], p["f3"] - p["f2"])
	var fourth_gap: float = p["f4"] - p["f3"]
	if isolated:
		# Reject rather than penalise: the unconstrained objective is minimised
		# BEST by maximal degeneracy, so a soft penalty would still converge on a
		# four-plate vertex and the isolated arm would silently measure the wrong
		# case.
		if fourth_gap <= FOOTPRINT:
			return INF
		return score
	# The degenerate arm seeks a four-fold vertex directly, by folding the fourth
	# plate's gap into the objective.
	return maxf(score, fourth_gap)


## Walk a circle around the junction and return the largest step between
## adjacent samples of the blended signature.
func _max_adjacent_step(centre: Vector2, samples: int, use_third: bool) -> float:
	var worst := 0.0
	var prev := PackedFloat64Array()
	for i in range(0, samples + 1):
		var a := TAU * float(i) / float(samples)
		var uv := centre + Vector2(cos(a), sin(a)) * ARC_RADIUS
		var cur := _blend(uv, use_third)
		if not prev.is_empty():
			var d := 0.0
			for k in range(0, cur.size()):
				d = maxf(d, absf(cur[k] - prev[k]))
			worst = maxf(worst, d)
		prev = cur
	return worst


func _max_adjacent_window_step(centre: Vector2, samples: int) -> float:
	var worst := 0.0
	var prev := PackedFloat64Array()
	for i in range(0, samples + 1):
		var a := TAU * float(i) / float(samples)
		var uv := centre + Vector2(cos(a), sin(a)) * ARC_RADIUS
		var cur := _window_blend(uv)
		if not prev.is_empty():
			var d := 0.0
			for k in range(0, cur.size()):
				d = maxf(d, absf(cur[k] - prev[k]))
			worst = maxf(worst, d)
		prev = cur
	return worst


func _max_adjacent_window_cavity_amp_step(
		centre: Vector2, samples: int) -> float:
	var worst := 0.0
	var prev := INF
	for i in range(0, samples + 1):
		var a := TAU * float(i) / float(samples)
		var uv := centre + Vector2(cos(a), sin(a)) * ARC_RADIUS
		var cur := _window_cavity_amps(uv)
		if prev != INF:
			worst = maxf(worst, absf(cur - prev))
		prev = cur
	return worst


## Confirms the arc actually sits inside the averaging band and actually crosses
## a second/third identity swap. Without both, every continuity assertion would
## pass on an arc where nothing was ever being blended.
func _arc_is_live(centre: Vector2) -> Dictionary:
	var swaps := 0
	var max_w := 0.0
	var prev_id2 := Vector2.INF
	for i in range(0, ARC_SAMPLES + 1):
		var a := TAU * float(i) / float(ARC_SAMPLES)
		var uv := centre + Vector2(cos(a), sin(a)) * ARC_RADIUS
		var p := _plates(uv)
		max_w = maxf(max_w, _edge_weight(p, uv))
		var id2 := p["id2"] as Vector2
		if prev_id2 != Vector2.INF and id2 != prev_id2:
			swaps += 1
		prev_id2 = id2
	return {"swaps": swaps, "max_weight": max_w}


func _check_junction_continuity(centre: Vector2) -> void:
	var live := _arc_is_live(centre)
	# VACUITY GUARD. An arc that never crosses an identity swap, or that sits
	# where the neighbour weight is zero, would report a tiny step under BOTH
	# rules and this test would pass while proving nothing.
	if int(live["swaps"]) < 2:
		_fail("the probe arc crosses %d second-nearest identity changes — it is "
			% int(live["swaps"])
			+ "not circling a triple junction, so the continuity result below "
			+ "would be vacuous")
		return
	if float(live["max_weight"]) <= 0.0:
		_fail("the probe arc never carries a non-zero neighbour weight, so "
			+ "nothing is being blended and the continuity result would be "
			+ "vacuous — acceptance criterion 1 is specifically about a "
			+ "discontinuity while that weight is non-zero")
		return

	var fixed_coarse := _max_adjacent_step(centre, ARC_SAMPLES, true)
	var fixed_fine := _max_adjacent_step(centre, ARC_SAMPLES * 4, true)
	var old_coarse := _max_adjacent_step(centre, ARC_SAMPLES, false)
	var old_fine := _max_adjacent_step(centre, ARC_SAMPLES * 4, false)

	# THE CONTROL, and the reason this test is not self-confirming. The #482 rule
	# must show a step that does NOT shrink when the sampling is refined — that
	# is what a jump discontinuity is, and it is the defect #499 names. If this
	# arm ever goes quiet, the probe has stopped being able to see the thing it
	# claims to have fixed and the arm below means nothing.
	if old_fine < CONTROL_STEP_MIN:
		_fail("control: the pairwise rule's largest step across the junction is "
			+ "%.5f, under the %.5f this probe needs to see — the arc is not "
			% [old_fine, CONTROL_STEP_MIN]
			+ "resolving the identity jump, so the three-way result proves "
			+ "nothing")
	if old_fine < old_coarse * CONTINUITY_RATIO:
		_fail("control: the pairwise rule's step FELL from %.5f to %.5f when the "
			% [old_coarse, old_fine]
			+ "sampling was refined 4x — a jump does not shrink under refinement, "
			+ "so this is smooth variation and the probe is not on the junction")

	# The fix: refining the sampling 4x must shrink the largest step, which is
	# what continuity means and what a jump cannot do.
	if fixed_fine > fixed_coarse * CONTINUITY_RATIO:
		_fail("the three-way rule's largest step across the junction did not "
			+ "shrink under refinement (%.5f at %d samples, %.5f at %d) — the "
			% [fixed_coarse, ARC_SAMPLES, fixed_fine, ARC_SAMPLES * 4]
			+ "blend is still discontinuous where three plates meet (#499)")
	if fixed_fine > CONTINUOUS_STEP_MAX:
		_fail("the three-way rule still steps %.5f across the junction, above "
			% fixed_fine
			+ "the %.5f a continuous blend may show at this sampling density"
			% CONTINUOUS_STEP_MAX)
	print("JUNCTION uv=(%.4f, %.4f) swaps=%d max_weight=%.3f"
		% [centre.x, centre.y, int(live["swaps"]), float(live["max_weight"])])
	print("JUNCTION pairwise(#482) step %.5f -> %.5f under 4x refinement"
		% [old_coarse, old_fine])
	print("JUNCTION three-way(#499) step %.5f -> %.5f under 4x refinement"
		% [fixed_coarse, fixed_fine])


func _max_step_of(centre: Vector2, samples: int, use_third: bool,
		key: String) -> float:
	var worst := 0.0
	var prev := INF
	for i in range(0, samples + 1):
		var a := TAU * float(i) / float(samples)
		var uv := centre + Vector2(cos(a), sin(a)) * ARC_RADIUS
		var cur: float = _cavity_parts(uv, use_third)[key]
		if prev != INF:
			worst = maxf(worst, absf(cur - prev))
		prev = cur
	return worst


func _max_legacy_spread_step(centre: Vector2, samples: int) -> float:
	var worst := 0.0
	var prev := INF
	for i in range(0, samples + 1):
		var a := TAU * float(i) / float(samples)
		var uv := centre + Vector2(cos(a), sin(a)) * ARC_RADIUS
		var cur := _legacy_cavity_spread(uv)
		if prev != INF:
			worst = maxf(worst, absf(cur - prev))
		prev = cur
	return worst


func _max_adjacent_cavity_step(centre: Vector2, samples: int,
		use_third: bool) -> float:
	var worst := 0.0
	var prev := INF
	for i in range(0, samples + 1):
		var a := TAU * float(i) / float(samples)
		var uv := centre + Vector2(cos(a), sin(a)) * ARC_RADIUS
		var cur := _cavity(uv, use_third)
		if prev != INF:
			worst = maxf(worst, absf(cur - prev))
		prev = cur
	return worst


## The largest cavity value anywhere on the arc. A vacuity guard: if the cavity
## is zero everywhere the probe circles, every step below is zero under both
## rules and the arm would pass while proving nothing.
func _max_cavity(centre: Vector2) -> float:
	var peak := 0.0
	for i in range(0, ARC_SAMPLES + 1):
		var a := TAU * float(i) / float(ARC_SAMPLES)
		var uv := centre + Vector2(cos(a), sin(a)) * ARC_RADIUS
		peak = maxf(peak, _cavity(uv, true))
	return peak


## Acceptance criterion 1 of #584, measured on the CAVITY rather than inferred
## from the substance arm above.
##
## That arm proves the three-way weighting is continuous for a LINEAR per-cell
## blend. The cavity is not one: each cell's height passes through a ceiling and
## is then squared before the weights apply, and the whole thing is scaled by
## `spread`. So the cavity is measured directly, and DECOMPOSED, because the two
## factors fail differently and only one of them is #584's to fix:
##
##   - `amps` is the per-cell quantity. Under the pairwise rule it inherits the
##     second-nearest cell's identity swap; under `plate_w` it does not. That is
##     the fix, and it is asserted as continuity — a step that shrinks under
##     refinement, against a control that does not.
##   - `spread` is a footprint quantity. Its legacy c1/c2-only answer is the
##     control; the symmetric footprint is the fix.
func _check_cavity_continuity(centre: Vector2) -> void:
	var peak := _max_cavity(centre)
	if peak <= 0.0:
		_fail("the cavity is zero everywhere on the probe arc, so both rules "
			+ "would report no step and this arm would be vacuous — the arc is "
			+ "not sitting where the seam variance is live")
		return

	var amp_old_coarse := _max_step_of(centre, ARC_SAMPLES, false, "amps")
	var amp_old_fine := _max_step_of(centre, ARC_SAMPLES * 4, false, "amps")
	var amp_new_coarse := _max_step_of(centre, ARC_SAMPLES, true, "amps")
	var amp_new_fine := _max_step_of(centre, ARC_SAMPLES * 4, true, "amps")

	# THE CONTROL. The pairwise per-cell term must actually jump here, or the
	# three-way result below is measuring nothing and this arm cannot fail.
	if amp_old_fine < CAVITY_CONTROL_STEP_MIN:
		_fail("control: the pairwise cavity amplitudes' largest step across the "
			+ "junction is %.5f, under the %.5f this probe needs to see — the "
			% [amp_old_fine, CAVITY_CONTROL_STEP_MIN]
			+ "arc is not resolving the identity jump, so the three-way result "
			+ "proves nothing")
	if amp_old_fine < amp_old_coarse * CONTINUITY_RATIO:
		_fail("control: the pairwise cavity amplitudes' step FELL from %.5f to "
			% amp_old_coarse
			+ "%.5f when the sampling was refined 4x — a jump does not shrink "
			% amp_old_fine
			+ "under refinement, so this is smooth variation and the probe is "
			+ "not on the junction")

	# THE FIX. Splitting the squared heights over `plate_w` must make the
	# per-cell term continuous.
	if amp_new_fine > amp_new_coarse * CONTINUITY_RATIO:
		_fail("the three-way cavity amplitudes' largest step did not shrink "
			+ "under refinement (%.5f at %d samples, %.5f at %d) — the seam "
			% [amp_new_coarse, ARC_SAMPLES, amp_new_fine, ARC_SAMPLES * 4]
			+ "variance still carries the second-nearest cell's identity swap "
			+ "(#584)")
	if amp_new_fine > CAVITY_CONTINUOUS_STEP_MAX:
		_fail("the three-way cavity amplitudes still step %.5f across the "
			% amp_new_fine
			+ "junction, above the %.5f a continuous per-cell blend may show at "
			% CAVITY_CONTINUOUS_STEP_MAX
			+ "this sampling density")

	# THE FOOTPRINT FIX. Refining the same arc must now shrink both the spread
	# step and the composed cavity step. A label-swap jump stays flat.
	var legacy_spread_coarse := _max_legacy_spread_step(
		centre, ARC_SAMPLES)
	var legacy_spread_fine := _max_legacy_spread_step(
		centre, ARC_SAMPLES * 4)
	if legacy_spread_fine < CAVITY_CONTROL_STEP_MIN:
		_fail("control: the c1/c2-only seam footprint's spread step is %.5f, "
			% legacy_spread_fine
			+ "under the %.5f this probe needs to see — the arc cannot prove "
			% CAVITY_CONTROL_STEP_MIN
			+ "that the symmetric footprint removed the identity jump")
	if legacy_spread_fine < legacy_spread_coarse * CONTINUITY_RATIO:
		_fail("control: the c1/c2-only seam footprint's spread step FELL from "
			+ "%.5f to %.5f under 4x refinement — the probe is seeing smooth "
			% [legacy_spread_coarse, legacy_spread_fine]
			+ "variation rather than the #589 label jump")
	var spread_coarse := _max_step_of(
		centre, ARC_SAMPLES, true, "spread")
	var spread_fine := _max_step_of(
		centre, ARC_SAMPLES * 4, true, "spread")
	if spread_fine > spread_coarse * CONTINUITY_RATIO:
		_fail("the seam footprint spread did not shrink under refinement "
			+ "(%.5f at %d samples, %.5f at %d) — `edge_fw` still jumps when "
			% [spread_coarse, ARC_SAMPLES, spread_fine, ARC_SAMPLES * 4]
			+ "the second- and third-nearest plate labels exchange (#589)")
	if spread_fine > CAVITY_CONTINUOUS_STEP_MAX:
		_fail("the symmetric seam footprint still steps %.5f across the "
			% spread_fine
			+ "junction, above the %.5f a continuous spread may show at this "
			% CAVITY_CONTINUOUS_STEP_MAX
			+ "sampling density")
	var full_coarse := _max_adjacent_cavity_step(
		centre, ARC_SAMPLES, true)
	var full_fine := _max_adjacent_cavity_step(
		centre, ARC_SAMPLES * 4, true)
	if full_fine > full_coarse * CONTINUITY_RATIO:
		_fail("the full seam cavity did not shrink under refinement "
			+ "(%.5f at %d samples, %.5f at %d) — the footprint still leaves "
			% [full_coarse, ARC_SAMPLES, full_fine, ARC_SAMPLES * 4]
			+ "a visible identity step at the plate junction (#589)")
	if full_fine > CAVITY_CONTINUOUS_STEP_MAX:
		_fail("the composed seam cavity still steps %.5f across the junction, "
			% full_fine
			+ "above the %.5f a continuous cavity may show at this sampling "
			% CAVITY_CONTINUOUS_STEP_MAX
			+ "density")
	print("CAVITY peak %.5f on the arc" % peak)
	print("CAVITY amps pairwise(#554) %.5f -> %.5f, three-way(#584) %.5f -> %.5f"
		% [amp_old_coarse, amp_old_fine, amp_new_coarse, amp_new_fine])
	print("CAVITY spread control(#589) %.5f -> %.5f"
		% [legacy_spread_coarse, legacy_spread_fine])
	print("CAVITY spread(#589) %.5f -> %.5f under 4x refinement"
		% [spread_coarse, spread_fine])
	print("CAVITY full(#589) %.5f -> %.5f under 4x refinement"
		% [full_coarse, full_fine])


## The four-plate case. The three-candidate answer is the positive control: its
## third label swaps with an uncarried fourth and the step does not shrink under
## refinement. The whole-window answer must turn that jump into smooth variation.
func _check_degenerate_vertex_bound(centre: Vector2) -> void:
	var live := _arc_is_live(centre)
	if int(live["swaps"]) < 2 or float(live["max_weight"]) <= 0.0:
		print("DEGENERATE arc at (%.4f, %.4f) is not live (swaps=%d weight=%.3f)"
			% [centre.x, centre.y, int(live["swaps"]),
				float(live["max_weight"])])
		return
	var limited_coarse := _max_adjacent_step(centre, ARC_SAMPLES, true)
	var limited_fine := _max_adjacent_step(centre, ARC_SAMPLES * 4, true)
	var window_coarse := _max_adjacent_window_step(centre, ARC_SAMPLES)
	var window_fine := _max_adjacent_window_step(centre, ARC_SAMPLES * 4)
	var cavity_limited_coarse := _max_step_of(
		centre, ARC_SAMPLES, true, "amps")
	var cavity_limited_fine := _max_step_of(
		centre, ARC_SAMPLES * 4, true, "amps")
	var cavity_window_coarse := _max_adjacent_window_cavity_amp_step(
		centre, ARC_SAMPLES)
	var cavity_window_fine := _max_adjacent_window_cavity_amp_step(
		centre, ARC_SAMPLES * 4)
	var footprint_coarse := _max_step_of(
		centre, ARC_SAMPLES, true, "spread")
	var footprint_fine := _max_step_of(
		centre, ARC_SAMPLES * 4, true, "spread")
	if limited_fine < CONTROL_STEP_MIN:
		_fail("control: the three-candidate rule's four-plate step is %.5f, "
			% limited_fine
			+ "under the %.5f this probe needs to see — the arc cannot prove "
			% CONTROL_STEP_MIN
			+ "that the whole-window rule removed the carried-list tail")
	if limited_fine < limited_coarse * CONTINUITY_RATIO:
		_fail("control: the three-candidate four-plate step FELL from %.5f to "
			% limited_coarse
			+ "%.5f under 4x refinement — the probe is seeing smooth variation, "
			% limited_fine
			+ "not the third/fourth identity jump #573 requires")
	if window_fine > window_coarse * CONTINUITY_RATIO:
		_fail("the whole-window rule's four-plate step did not shrink under "
			+ "refinement (%.5f at %d samples, %.5f at %d) — the blend still "
			% [window_coarse, ARC_SAMPLES, window_fine, ARC_SAMPLES * 4]
			+ "depends on an ordered candidate identity")
	if window_fine > CONTINUOUS_STEP_MAX:
		_fail("the whole-window rule still steps %.5f at the four-plate vertex, "
			% window_fine
			+ "above the %.5f a continuous blend may show at this density"
			% CONTINUOUS_STEP_MAX)
	if cavity_limited_fine < CAVITY_CONTROL_STEP_MIN:
		_fail("control: the three-candidate cavity amplitudes' four-plate step "
			+ "is %.5f, under the %.5f this probe needs to see — the arc cannot "
			% [cavity_limited_fine, CAVITY_CONTROL_STEP_MIN]
			+ "prove that the whole-window rule removed the fixed third-cell "
			+ "tail")
	if cavity_limited_fine < cavity_limited_coarse * CONTINUITY_RATIO:
		_fail("control: the three-candidate cavity amplitudes' four-plate step "
			+ "FELL from %.5f to %.5f under 4x refinement — the probe is seeing "
			% [cavity_limited_coarse, cavity_limited_fine]
			+ "smooth variation, not the third/fourth identity jump")
	if cavity_window_fine > cavity_window_coarse * CONTINUITY_RATIO:
		_fail("the whole-window cavity amplitudes' four-plate step did not "
			+ "shrink under refinement (%.5f at %d samples, %.5f at %d) — the "
			% [cavity_window_coarse, ARC_SAMPLES, cavity_window_fine,
				ARC_SAMPLES * 4]
			+ "variance still depends on the fixed third candidate")
	if cavity_window_fine > CAVITY_CONTINUOUS_STEP_MAX:
		_fail("the whole-window cavity amplitudes still step %.5f at the "
			% cavity_window_fine
			+ "four-plate vertex, above the %.5f a continuous per-cell blend "
			% CAVITY_CONTINUOUS_STEP_MAX
			+ "may show at this density")
	if footprint_fine > footprint_coarse * CONTINUITY_RATIO:
		_fail("the seam footprint's four-plate step did not shrink under "
			+ "refinement (%.5f at %d samples, %.5f at %d) — the harmonic "
			% [footprint_coarse, ARC_SAMPLES, footprint_fine,
				ARC_SAMPLES * 4]
			+ "footprint still depends on the carried third centre when it "
			+ "exchanges with an uncarried fourth")
	print("DEGENERATE uv=(%.4f, %.4f) three-way step %.5f -> %.5f; "
		% [centre.x, centre.y, limited_coarse, limited_fine]
		+ "whole-window step %.5f -> %.5f under 4x refinement"
		% [window_coarse, window_fine])
	print("DEGENERATE cavity amps three-way %.5f -> %.5f; whole-window "
		% [cavity_limited_coarse, cavity_limited_fine]
		+ "%.5f -> %.5f under 4x refinement"
		% [cavity_window_coarse, cavity_window_fine])
	print("DEGENERATE footprint %.5f -> %.5f under 4x refinement"
		% [footprint_coarse, footprint_fine])


## A normalized symmetric width must lose authority continuously as the third
## plate's coverage vanishes. The junction ramp alone only sees `f3 - f2`, so it
## remains one when both remote candidates are mutually close but outside the
## nearest plate's pixel footprint. That also must not activate the read gain.
func _check_footprint_coverage_authority() -> void:
	var uv := Vector2.ZERO
	var high := {
		"c1": Vector2(1.0, 0.0),
		"c2": Vector2(-1.0, 0.0),
		"c3": Vector2(-1.0, -1.0),
		"f1": 0.0,
		"f2": FOOTPRINT * 0.50,
		"f3": FOOTPRINT * 0.50,
		"f4": FOOTPRINT * 3.0,
	}
	var low := high.duplicate()
	low["f2"] = FOOTPRINT * 0.99
	low["f3"] = FOOTPRINT * 0.99
	var pair := _pair_separator_footprint(uv, high["c1"], high["c2"])
	var high_delta := absf(_separator_footprint(high, uv) - pair)
	var low_delta := absf(_separator_footprint(low, uv) - pair)
	if high_delta <= 0.0001:
		_fail("control: the synthetic covered junction changes the footprint by "
			+ "only %.9f — the probe cannot see the symmetric handoff"
			% high_delta)
	if low_delta > high_delta * 0.01:
		_fail("the symmetric footprint keeps %.9f of authority as candidate "
			% low_delta
			+ "coverage vanishes, against %.9f while covered — fade the "
			% high_delta
			+ "handoff by actual third-plate coverage before its cutoff")
	var remote := {
		"f1": 0.0,
		"f2": FOOTPRINT * 2.0,
		"f3": FOOTPRINT * 2.0,
	}
	var remote_gain := _junction_read_gain(remote)
	if remote_gain != 1.0:
		_fail("two uncovered remote candidates activate junction read gain "
			+ "%.6f — compensation must stay exactly 1.0 unless the third "
			% remote_gain
			+ "plate reaches the fragment")
	print("FOOTPRINT COVERAGE high delta %.9f, tail %.9f; remote gain %.6f"
		% [high_delta, low_delta, remote_gain])


## At an exact c3/c4 identity swap the carried c3 centre may change while every
## sorted distance remains equal. Coverage fading may retire the correction,
## but it cannot leave any coefficient on that ordered centre during the fade.
func _check_exact_higher_order_swap_footprint() -> void:
	var uv := Vector2.ZERO
	var before := {
		"c1": Vector2(0.70, 0.20),
		"c2": Vector2(-1.00, 0.10),
		"c3": Vector2(0.15, 1.00),
		"f1": 0.0,
		"f2": FOOTPRINT * 0.94,
		"f3": FOOTPRINT * 0.94,
		"f4": FOOTPRINT * 0.94,
	}
	var after := before.duplicate()
	after["c3"] = Vector2(-0.80, -0.60)
	var fourth_coverage := _candidate_coverage(
		float(before["f4"]), float(before["f1"]))
	var coverage_authority := _coverage_authority(fourth_coverage)
	if coverage_authority <= 0.0 or coverage_authority >= 1.0:
		_fail("control: the exact higher-order swap probe has coverage authority "
			+ "%.9f — it must exercise the interior of the fade" % coverage_authority)
	var a := _separator_footprint(before, uv)
	var b := _separator_footprint(after, uv)
	var jump := absf(a - b)
	if jump > 0.000000001:
		_fail("the exact c3/c4 swap leaves %.9f of ordered c3 footprint inside "
			% jump
			+ "the %.6f coverage-authority fade — the carried triple must have "
			% coverage_authority
			+ "zero authority at the swap independently of coverage")
	print("FOOTPRINT HIGHER SWAP coverage authority %.6f, jump %.9f"
		% [coverage_authority, jump])


## The fourth-candidate reach must fade continuously. A hard cutoff at
## `f4 - f1 == footprint` creates a zero-width contour even though the
## whole-window and three-candidate answers are still different there.
func _check_window_activation_continuity() -> void:
	var w := 0.60
	var epsilon := 0.000001
	var before := {
		"f1": 0.0,
		"f3": w * 0.75,
		"f4": w - epsilon,
	}
	var after := before.duplicate()
	after["f4"] = w + epsilon
	var a := _window_activation(before, w)
	var b := _window_activation(after, w)
	var jump := absf(a - b)
	if jump > 0.001:
		_fail("the fourth-candidate reach activation jumps %.9f across "
			% jump
			+ "`f4 - f1 == footprint` — the whole-window handoff must fade "
			+ "continuously instead of drawing a zero-width contour")
	print("WINDOW ACTIVATION reach-boundary jump %.9f" % jump)


## At an exact third/fourth swap the old activation stays one until the fourth
## distance leaves the footprint, then drops to zero. The complete window and
## established three-way rules assign the first/second candidates differently,
## so that scalar cutoff draws a contour even though the fourth candidate's own
## coverage has converged to zero. The generalized composition must converge to
## the established result before the cutoff is allowed to skip its window.
func _check_exact_swap_reach_handoff() -> void:
	var footprint := 0.60
	var epsilon := 0.000001
	var before := footprint - epsilon
	var after := footprint + epsilon
	var old_before := _synthetic_legacy_reach_value(
		before, before, footprint)
	var old_after := _synthetic_legacy_reach_value(
		after, after, footprint)
	var old_jump := absf(old_before - old_after)
	var new_before := _synthetic_reach_value(before, before, footprint)
	var new_after := _synthetic_reach_value(after, after, footprint)
	var new_jump := absf(new_before - new_after)
	if old_jump < 0.02:
		_fail("control: the legacy exact-swap reach handoff jumps only %.9f — "
			% old_jump
			+ "the probe cannot see the differing first/second weighting on "
			+ "either side of the cutoff")
	if new_jump > 0.001:
		_fail("the exact third/fourth reach handoff still jumps %.9f when the "
			% new_jump
			+ "fourth coverage leaves the footprint — the generalized window "
			+ "must converge to the established answer before its cutoff")
	print("WINDOW HANDOFF legacy jump %.9f; generalized jump %.9f"
		% [old_jump, new_jump])


func _max_window_grid_boundary_jump(radius: int, footprint: float) -> Dictionary:
	var worst := 0.0
	var worst_uv := Vector2.ZERO
	var epsilon := 0.000001
	for grid_x in range(3, 13):
		for gy in range(0, 180):
			var y := 2.3 + float(gy) * 0.05
			var left := Vector2(float(grid_x) - epsilon, y)
			var right := Vector2(float(grid_x) + epsilon, y)
			var a := _full_window_blend(
				left, _plates(left), footprint, radius)
			var b := _full_window_blend(
				right, _plates(right), footprint, radius)
			for k in range(0, a.size()):
				var d: float = absf(a[k] - b[k])
				if d > worst:
					worst = d
					worst_uv = Vector2(float(grid_x), y)
	return {"jump": worst, "uv": worst_uv}


## During the 0.30–0.85 resolution fade, weights can reach beyond the 3x3
## nearest-candidate search. The whole-window sum must cover every cell that can
## receive non-zero weight; otherwise `floor(plate_uv)` drops a weighted outer
## column and inserts another at every integer grid boundary.
func _check_window_grid_boundary_continuity() -> void:
	var footprint := 0.60
	var three := _max_window_grid_boundary_jump(1, footprint)
	var five := _max_window_grid_boundary_jump(2, footprint)
	if float(three["jump"]) < 0.01:
		_fail("control: the 3x3 whole-window sum jumps only %.9f at grid "
			% float(three["jump"])
			+ "boundaries — the probe cannot see the weighted-column seam it "
			+ "claims the larger domain removes")
	if float(five["jump"]) > 0.001:
		var uv: Vector2 = five["uv"]
		_fail("the expanded whole-window sum still jumps %.9f at grid boundary "
			% float(five["jump"])
			+ "uv=(%.4f, %.4f) while the resolution fade is active"
			% [uv.x, uv.y])
	print("WINDOW GRID 3x3 jump %.9f; 5x5 jump %.9f"
		% [float(three["jump"]), float(five["jump"])])


## The activation order statistics must come from the same invariant support as
## the weighted sum. This shipping-hash point is the exact review reduction: an
## outer-column centre is one of the true four nearest during the resolution
## fade, so a 3x3 `f4` changes identity when `floor(plate_uv)` changes.
func _check_activation_order_domain() -> void:
	var footprint := 0.695
	var epsilon := 0.000001
	var left := Vector2(-3.0 - epsilon, 0.84255)
	var right := Vector2(-3.0 + epsilon, 0.84255)
	var three_left := _window_activation(_plates(left, 1), footprint)
	var three_right := _window_activation(_plates(right, 1), footprint)
	var five_left := _window_activation(_plates(left, 2), footprint)
	var five_right := _window_activation(_plates(right, 2), footprint)
	var three_jump := absf(three_left - three_right)
	var five_jump := absf(five_left - five_right)
	if three_jump < 0.10:
		_fail("control: the 3x3 fourth-distance activation jumps only %.9f at "
			% three_jump
			+ "the shipping-hash grid boundary — the probe cannot see the "
			+ "order-statistic seam it claims the invariant domain removes")
	if five_jump > 0.001:
		_fail("the 5x5 fourth-distance activation still jumps %.9f at the "
			% five_jump
			+ "shipping-hash grid boundary — activation and accumulation must "
			+ "use the same invariant support")
	print("ACTIVATION DOMAIN 3x3 %.9f -> %.9f (jump %.9f); "
		% [three_left, three_right, three_jump]
		+ "5x5 %.9f -> %.9f (jump %.9f)"
		% [five_left, five_right, five_jump])


## Acceptance criterion 3, proven by construction rather than by frame evidence:
## away from a junction the third candidate carries no weight, so the blend is
## the two-cell one EXACTLY. Anything else would mean the fix had reached
## fragments it has no business touching.
func _check_two_cell_reduction() -> void:
	var checked := 0
	var worst := 0.0
	var worst_footprint := 0.0
	var worst_uv := Vector2.ZERO
	for gy in range(0, 90):
		for gx in range(0, 90):
			var uv := Vector2(float(gx) * 0.11, float(gy) * 0.11) + Vector2(1.7, 2.9)
			var p := _plates(uv)
			# Away from a junction: the third candidate is past the footprint the
			# split is keyed on, so its share is exactly zero.
			if p["f3"] - p["f2"] <= FOOTPRINT:
				continue
			checked += 1
			# Exercise the production whole-window path too. Comparing only the
			# established three-way answer cannot catch a fourth-cell gate that
			# activates merely because two FAR candidates happen to be close.
			var a := _window_blend(uv)
			var b := _blend(uv, false)
			var legacy_fw := _pair_separator_footprint(
				uv, p["c1"], p["c2"])
			worst_footprint = maxf(
				worst_footprint,
				absf(_separator_footprint(p, uv) - legacy_fw))
			for k in range(0, a.size()):
				var d: float = absf(a[k] - b[k])
				if d > worst:
					worst = d
					worst_uv = uv
	if checked < 1000:
		_fail("only %d off-junction samples were checked — too few to claim the "
			% checked
			+ "two-cell case is unchanged")
		return
	if worst != 0.0:
		_fail("the whole-window rule changed an off-junction fragment by %.9f at "
			% worst
			+ "uv=(%.4f, %.4f) — away from a junction it must reduce to the "
			% [worst_uv.x, worst_uv.y]
			+ "two-cell blend EXACTLY, or it is altering ground the fix has no "
			+ "business touching")
	if worst_footprint != 0.0:
		_fail("the junction-safe separator changed an off-junction footprint by "
			+ "%.9f — outside the third plate's reach it must return the "
			% worst_footprint
			+ "established two-cell width bit-identically (#589)")
	print("REDUCTION %d off-junction samples, largest difference from the "
		% checked + "two-cell rule: %.9f; footprint difference: %.9f"
		% [worst, worst_footprint])


# ---------------------------------------------------------------------------
# Source guards — the join between this mirror and the shaders it stands for
# ---------------------------------------------------------------------------

func _check_source_guards() -> void:
	var partition := _source(PARTITION_PATH)
	var ground := _source(GROUND_SHADER_PATH)
	var contact := _source(CONTACT_SHADER_PATH)
	# MISSING-SOURCE GUARD, same reasoning as crack_relief_parity_test: a file
	# that cannot be read satisfies every "contains" check below, so a rename
	# would turn these guards green while checking nothing.
	if partition == "" or ground == "" or contact == "":
		_fail("a shader source could not be read (partition=%d ground=%d "
			% [partition.length(), ground.length()]
			+ "contact=%d bytes) — the guards below would pass vacuously"
			% contact.length())
		return
	if not partition.contains("vec3 terrain_plate_blend_weights("):
		_fail("`terrain_plate_blend_weights` is gone from %s — coverage is no "
			% PARTITION_PATH
			+ "longer split across the three nearest plates, so the junction "
			+ "step this test measures is back (#499)")
	if not partition.contains("float terrain_plate_window_junction(") \
			or not partition.contains("float terrain_plate_window_reachable("):
		_fail("the generalized junction weight or converged reach gate is absent "
			+ "from %s — coverage either still ends at a fixed candidate list "
			% PARTITION_PATH
			+ "or cuts over before the two compositions agree (#573)")
	if not partition.contains("float terrain_plate_separator_footprint(") \
			or not partition.contains(
				"g2 / max(edge12, 1e-6) + g3 / max(edge13, 1e-6)"):
		_fail("the permutation-safe three-separator footprint is absent from "
			+ "%s — `edge_fw` can jump when the second and third plate labels "
			% PARTITION_PATH
			+ "exchange even while their distances remain continuous (#589)")
	if not partition.contains(
			"float f1, float f2, float f3, float f4, float plate_fw,\n"
				+ "\t\tfloat plate_resolved, vec2 uv_dx, vec2 uv_dy)") \
			or not partition.contains("if (plate_resolved <= 0.0)"):
		_fail("the separator footprint does not take the plate-resolution "
			+ "cutoff before its 5x5 higher-order search — fully unresolved "
			+ "ground still pays for a result that cannot affect the material")
	if not partition.contains("for (int j = -2; j <= 2; j++)") \
			or not partition.contains("for (int i = -2; i <= 2; i++)"):
		_fail("`terrain_plates` does not select its first four distances from "
			+ "the same 5x5 support as the whole-window sum — `f4` can jump "
			+ "when the floor-based 3x3 candidate set changes")
	# Both callers must pass the ISOTROPIC plate footprint to the junction
	# authority. A width built from `c1` survives the owner swap on the OWNING
	# separator only because it negates there and the projection takes absolute
	# values; against the third candidate there is no such cancellation, so it
	# would jump whenever the owner's label moved and put a smaller copy of the
	# defect back inside the fix. The anisotropic derivatives belong only to the
	# separator projection. Nothing else in the suite would notice.
	for entry in [[GROUND_SHADER_PATH, ground], [CONTACT_SHADER_PATH, contact]]:
		var path: String = entry[0]
		var src: String = entry[1]
		if not src.contains(
				"terrain_plate_blend_weights(f1, f2, f3, plate_edge_w, plate_fw)"):
			_fail("%s does not call `terrain_plate_blend_weights(f1, f2, f3, "
				% path
				+ "plate_edge_w, plate_fw)` — either it takes the second-nearest "
				+ "plate outright again, or it keys the split on a footprint "
				+ "built from `c1`, which jumps when the owning cell swaps and "
				+ "puts the defect back (#499)")
		if not src.contains("edge_fw = terrain_plate_separator_footprint(") \
				or not src.contains(
					"plate_uv, plate_c1, plate_c2, plate_c3,") \
				or not src.contains(
					"f1, f2, f3, f4, plate_fw, plate_resolved,") \
				or not src.contains("plate_uv_dx, plate_uv_dy"):
			_fail("%s does not derive `edge_fw` from all four carried plate "
				% path
				+ "centres — its seam cavity can still inherit the "
				+ "ordered tail's label swap at a junction (#589)")
		if not partition.contains(
				"float terrain_plate_junction_read_gain(float covered_junction)") \
				or not partition.contains(
					"float terrain_plate_covered_junction(") \
				or not src.contains(
					"junction_read_authority = terrain_plate_covered_junction(") \
				or not src.contains(
					"junction_read_gain = terrain_plate_junction_read_gain(") \
				or not src.contains("junction_read_authority);") \
				or not src.contains(
					"mean_tilt *= junction_read_gain") \
				or not src.contains(
					"seam_slope_var *= junction_read_gain * junction_read_gain"):
			_fail("%s does not restore the measured near-field seam read under "
				% path
				+ "the same smooth junction authority as the footprint fix — "
				+ "closing the old jump may silently soften the 6 m control")
		if not src.contains("terrain_plate_window_junction(") \
				or not src.contains("terrain_plate_window_reachable("):
			_fail("%s does not derive whole-window junction authority separately "
				% path
				+ "from its converged reach gate — the fourth candidate either "
				+ "has no continuous path into the surface or the cutoff can "
				+ "still draw a contour (#573)")
		if not src.contains("terrain_plate_window_weight(d, f1, plate_fw)"):
			_fail("%s does not weight every search-window cell with "
				% path
				+ "`terrain_plate_window_weight(d, f1, plate_fw)` — the fix "
				+ "still has an ordered last candidate whose label can swap")
		if src.count("for (int j = -2; j <= 2; j++)") < 2 \
				or src.count("for (int i = -2; i <= 2; i++)") < 2:
			_fail("%s does not use the proven 5x5 domain for both whole-window "
				% path
				+ "sums — a 3x3 domain drops weighted columns at integer grid "
				+ "boundaries while the resolution fade is active")
		if not src.contains(
				"plate_window_gate = plate_resolved * "
				+ "terrain_plate_window_reachable("):
			_fail("%s does not retire whole-window sampling with the plate "
				% path
				+ "resolution fade — outside the 0.30–0.85 active range there "
				+ "is no cell-specific plate signal left to resolve")
		if not src.contains("pair_surface = mix(surf_own, surf_nb, plate_edge_w)") \
				or not src.contains("surface = mix(\n\t\t\tpair_surface,"):
			_fail("%s does not compose the generalized window from the "
				% path
				+ "established pairwise base — it cannot converge to the "
				+ "three-way answer before the fourth-cell cutoff")
		if not src.contains(
				"window_slab_share += cell_is_slab * weight") \
				or not src.contains("float window_amp_sq = mix(") \
				or not src.contains("seam_amp_sq = mix(") \
				or not src.contains("pair_amp_sq,"):
			_fail("%s does not compose the nonlinear seam-cavity amplitude "
				% path
				+ "through the same symmetric whole-window weights — the fixed "
				+ "third amplitude can still swap with an uncarried fourth")


func _source(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


func _fail(msg: String) -> void:
	_failures.append(msg)


## `tools/run-client-test.sh` greps the log for the literal `TEST PASS`, and
## fails the run when it is absent even on a zero exit — so the verdict has to be
## spelled exactly that way, and `TEST FAIL` likewise.
func _report() -> void:
	if _failures.is_empty():
		print("TEST PASS — the neighbour blend is continuous across triple and "
			+ "four-fold junctions and unchanged away from them")
		get_tree().quit(0)
		return
	for msg in _failures:
		push_error(msg)
		print("TEST FAIL — %s" % msg)
	get_tree().quit(1)
