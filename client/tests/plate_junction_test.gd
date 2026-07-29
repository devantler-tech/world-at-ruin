extends Node
## Proves the plate boundary average stays CONTINUOUS where three plates meet
## (#499), and that it is unchanged everywhere else.
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
## the shaders stop calling `terrain_plate_junction_split`, or stop feeding it
## the isotropic footprint, this test fails even though its own arithmetic is
## untouched. Continuity proven here plus that call proven present in both
## shaders is the join.
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
	var degenerate := _find_triple_junction(false)
	if degenerate.is_empty():
		# Not a failure. A region may genuinely contain no four-plate vertex; the
		# guarantee being measured there is a bound, not a law.
		print("DEGENERATE none found in the scanned region — skipping the "
			+ "four-plate bound")
	else:
		_check_degenerate_vertex_bound(degenerate["uv"])
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


## The three nearest cells, as `terrain_plates` reports them.
func _plates(uv: Vector2) -> Dictionary:
	var base := Vector2(floor(uv.x), floor(uv.y))
	var f1 := 1000.0
	var f2 := 1000.0
	var f3 := 1000.0
	var id := base
	var c1 := base
	var c2 := base
	var id2 := base
	var id3 := base
	for j in range(-1, 2):
		for i in range(-1, 2):
			var cell := base + Vector2(float(i), float(j))
			var jitter := Vector2(
				_hash3(Vector3(cell.x, cell.y, 0.0)),
				_hash3(Vector3(cell.x, cell.y, 7.0)))
			var centre := cell + Vector2(0.15, 0.15) + 0.7 * jitter
			var d := uv.distance_to(centre)
			if d < f1:
				f3 = f2
				id3 = id2
				f2 = f1
				c2 = c1
				id2 = id
				f1 = d
				c1 = centre
				id = cell
			elif d < f2:
				f3 = f2
				id3 = id2
				f2 = d
				c2 = centre
				id2 = cell
			elif d < f3:
				f3 = d
				id3 = cell
	return {
		"id": id, "id2": id2, "id3": id3,
		"f1": f1, "f2": f2, "f3": f3,
		"c1": c1, "c2": c2,
		"f4": _fourth_distance(uv, base),
	}


## The FOURTH-nearest distance. The shaders do not compute it and this mirror
## does not blend with it — it exists only so the probe can tell an isolated
## triple junction from a degenerate vertex where four plates meet at once, which
## are different cases with different guarantees (see `_check_junction_*`).
func _fourth_distance(uv: Vector2, base: Vector2) -> float:
	var ds: Array[float] = []
	for j in range(-1, 2):
		for i in range(-1, 2):
			var cell := base + Vector2(float(i), float(j))
			var jitter := Vector2(
				_hash3(Vector3(cell.x, cell.y, 0.0)),
				_hash3(Vector3(cell.x, cell.y, 7.0)))
			ds.append(uv.distance_to(cell + Vector2(0.15, 0.15) + 0.7 * jitter))
	ds.sort()
	return ds[3]


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


## `terrain_plate_edge_blend(f1, f2, edge_fw * 0.5)`, with `edge_fw` built from
## the analytic separator exactly as both shaders build it: the separator
## gradient projected through both screen derivatives. Axis-aligned derivatives
## of magnitude FOOTPRINT stand in for the pixel.
func _edge_weight(p: Dictionary, uv: Vector2) -> float:
	var e1 := uv - p["c1"] as Vector2
	var e2 := uv - p["c2"] as Vector2
	var gsep := e2.normalized() - e1.normalized()
	var edge_fw: float = FOOTPRINT * (absf(gsep.x) + absf(gsep.y))
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


## The four-plate case, where the guarantee is a BOUND rather than continuity.
##
## The shaders carry three candidates. At a vertex where a fourth plate is
## equidistant with the third, the third's LABEL swaps with that uncarried fourth
## while it still holds weight, so a step survives — this is the tail of any
## fixed-size candidate list, not the second/third swap #499 names, and removing
## it needs a weighting with no ordering at all (a coverage sum over the whole
## search window). Recorded here as a measured bound so the remaining step is a
## number rather than a surprise, and so a regression in the three carried
## candidates still shows up.
func _check_degenerate_vertex_bound(centre: Vector2) -> void:
	var live := _arc_is_live(centre)
	if int(live["swaps"]) < 2 or float(live["max_weight"]) <= 0.0:
		print("DEGENERATE arc at (%.4f, %.4f) is not live (swaps=%d weight=%.3f)"
			% [centre.x, centre.y, int(live["swaps"]),
				float(live["max_weight"])])
		return
	var fixed := _max_adjacent_step(centre, ARC_SAMPLES * 4, true)
	var old := _max_adjacent_step(centre, ARC_SAMPLES * 4, false)
	if old <= 0.0:
		print("DEGENERATE arc at (%.4f, %.4f) shows no pairwise step to improve "
			% [centre.x, centre.y] + "on")
		return
	var ratio := fixed / old
	if ratio > DEGENERATE_STEP_RATIO_MAX:
		_fail("at the four-plate vertex the three-candidate blend still steps "
			+ "%.5f against the pairwise rule's %.5f (%.0f%%, over the %.0f%% "
			% [fixed, old, ratio * 100.0, DEGENERATE_STEP_RATIO_MAX * 100.0]
			+ "this bound allows) — the three carried candidates are no longer "
			+ "sharing coverage symmetrically")
	print("DEGENERATE uv=(%.4f, %.4f) pairwise %.5f -> three-way %.5f (%.0f%% "
		% [centre.x, centre.y, old, fixed, ratio * 100.0]
		+ "of the original step; the remainder is the third/fourth label swap, "
		+ "which three candidates cannot cover)")


## Acceptance criterion 3, proven by construction rather than by frame evidence:
## away from a junction the third candidate carries no weight, so the blend is
## the two-cell one EXACTLY. Anything else would mean the fix had reached
## fragments it has no business touching.
func _check_two_cell_reduction() -> void:
	var checked := 0
	var worst := 0.0
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
			var a := _blend(uv, true)
			var b := _blend(uv, false)
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
		_fail("the three-way rule changed an off-junction fragment by %.9f at "
			% worst
			+ "uv=(%.4f, %.4f) — away from a junction it must reduce to the "
			% [worst_uv.x, worst_uv.y]
			+ "two-cell blend EXACTLY, or it is altering ground the fix has no "
			+ "business touching")
	print("REDUCTION %d off-junction samples, largest difference from the "
		% checked + "two-cell rule: %.9f" % worst)


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
	# Both callers must pass the ISOTROPIC footprint. A width built from `c1`
	# survives the owner swap on the OWNING separator only because it negates
	# there and the projection takes absolute values; against the third candidate
	# there is no such cancellation, so it would jump whenever the owner's label
	# moved and put a smaller copy of the defect back inside the fix. Nothing
	# else in the suite would notice.
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


func _source(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


func _fail(msg: String) -> void:
	_failures.append(msg)


func _report() -> void:
	if _failures.is_empty():
		print("PLATE JUNCTION OK — the neighbour blend is continuous across a "
			+ "triple junction and unchanged away from one")
		get_tree().quit(0)
		return
	for msg in _failures:
		push_error(msg)
		print("PLATE JUNCTION FAIL — %s" % msg)
	get_tree().quit(1)
