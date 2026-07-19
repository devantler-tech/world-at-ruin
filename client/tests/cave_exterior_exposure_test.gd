extends Node
## Exposure-mask regression test (issue #156). `CaveSystemGen.build_geometry`
## bakes into each vertex COLOR's alpha how exposed to open sky that surface
## point is — 1.0 on the massif's outer hull, 0.0 on a carved cave wall — so
## `cave_rock.gdshader` can weather the exterior while interior walls keep
## their exact look (every exterior shader term is weighted by the mask).
##
## The mask is proven against an INDEPENDENT oracle: surface normals point
## toward the void they face, so a ray marched along the normal from an
## exterior vertex escapes into open sky without re-entering rock, while from
## an interior wall it must cross the carved void and strike the far side —
## the cave is enclosed. The mask compares the two SDF branches; the oracle
## marches the COMPOSED density field. They share no decision logic, so
## agreement is evidence rather than an echo.
##
## Run: godot --headless --path client res://tests/cave_exterior_exposure_test.tscn

const SEED := 42
const DECISIVE_HI := 0.9 ## Alpha above this counts as a confident "exterior".
const DECISIVE_LO := 0.1 ## Alpha below this counts as a confident "interior".
const SAMPLE_STRIDE := 23 ## Prime, so sampling does not beat with the grid.
const MARCH_START := 0.6 ## Clear of the vertex's own surface before sampling.
const MARCH_STEP := 0.5
const MARCH_RANGE := 24.0 ## Longer than any carved void is wide.
const ROCK_MARGIN := 0.1 ## Same "solidly rock" margin the vantage test uses.
## Minimum oracle agreement per class. Not 1.0: a wall vertex near the mouth
## can legitimately aim its normal out through the bore, and a grazing
## exterior ray can clip the undulating hull.
const MIN_AGREEMENT := 0.95
## Both classes must be substantial or the mask is vacuous. Seed 42 measures
## far above these floors; they only guard against a class quietly vanishing.
const MIN_CLASS_FRACTION := 0.15
const MIN_SAMPLED := 40 ## Agreement over a trivial sample proves nothing.

var _lay: Dictionary
var _noise: FastNoiseLite


func _ready() -> void:
	var built := CaveSystemGen.build_geometry(SEED)
	_lay = built["layout"]
	_noise = CaveSystemGen.make_noise(SEED)
	var arrays := (built["mesh"] as ArrayMesh).surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	if colors.size() != verts.size() or normals.size() != verts.size():
		_fail("mesh arrays disagree: %d verts, %d normals, %d colors" %
			[verts.size(), normals.size(), colors.size()])
		return

	# 1. Both classes exist in force — a constant mask is vacuous.
	var n_hi := 0
	var n_lo := 0
	for c in colors:
		if c.a > DECISIVE_HI:
			n_hi += 1
		elif c.a < DECISIVE_LO:
			n_lo += 1
	var frac_hi := float(n_hi) / float(colors.size())
	var frac_lo := float(n_lo) / float(colors.size())
	if frac_hi < MIN_CLASS_FRACTION or frac_lo < MIN_CLASS_FRACTION:
		_fail("mask is lopsided: %.2f exterior / %.2f interior — a class has vanished" %
			[frac_hi, frac_lo])
		return

	# 2. Anchors whose class is knowable without the mask.
	var err := _anchor_errors(verts, colors)
	if err != "":
		_fail(err)
		return

	# 3. The independent oracle agrees with the mask on both classes.
	var sweep := _oracle_agreement(verts, normals, colors)
	if sweep["ext_n"] < MIN_SAMPLED or sweep["int_n"] < MIN_SAMPLED:
		_fail("oracle sample too small to mean anything: %d exterior, %d interior" %
			[sweep["ext_n"], sweep["int_n"]])
		return
	var ext_rate := float(sweep["ext_ok"]) / float(sweep["ext_n"])
	var int_rate := float(sweep["int_ok"]) / float(sweep["int_n"])
	if ext_rate < MIN_AGREEMENT:
		_fail("exterior mask disagrees with the escape oracle: %.3f of %d rays re-entered rock" %
			[1.0 - ext_rate, sweep["ext_n"]])
		return
	if int_rate < MIN_AGREEMENT:
		_fail("interior mask disagrees with the enclosure oracle: %.3f of %d rays escaped the massif" %
			[1.0 - int_rate, sweep["int_n"]])
		return

	# 4a. CONTROL — the interior anchor can fail: a doctored all-exterior mask
	# must be caught, and for the interior reason, not some other trip-wire.
	var all_hi := PackedColorArray()
	all_hi.resize(colors.size())
	for i in colors.size():
		var c := colors[i]
		c.a = 1.0
		all_hi[i] = c
	if all_hi[_nearest_index(verts, _lay["rooms"][2]["center"])].a != 1.0:
		_fail("control fixture: the doctored all-exterior mask is not exterior at the interior anchor")
		return
	var hi_err := _anchor_errors(verts, all_hi)
	if not hi_err.contains("chamber wall"):
		_fail("control: an all-exterior mask slipped past the interior anchor (got: %s)" % hi_err)
		return

	# 4b. CONTROL — the exterior anchor can fail, for its own reason.
	var all_lo := PackedColorArray()
	all_lo.resize(colors.size())
	for i in colors.size():
		var c := colors[i]
		c.a = 0.0
		all_lo[i] = c
	var lo_err := _anchor_errors(verts, all_lo)
	if not lo_err.contains("crest"):
		_fail("control: an all-interior mask slipped past the exterior anchor (got: %s)" % lo_err)
		return

	# 4c. CONTROL — the oracle can refuse a wrong label: swapped expectations
	# at both anchors must come back contradicted.
	var top := verts[_highest_index(verts)]
	var top_n := normals[_highest_index(verts)]
	if _ray_hits_rock(top, top_n):
		_fail("control: the escape oracle called the dome crest enclosed — it could never refute a wrong interior label")
		return
	var anchor_i := _nearest_index(verts, _lay["rooms"][2]["center"])
	if not _ray_hits_rock(verts[anchor_i], normals[anchor_i]):
		_fail("control: the enclosure oracle called a chamber wall open — it could never refute a wrong exterior label")
		return

	print("TEST PASS — exposure mask %.2f exterior / %.2f interior; oracle agreement %.3f/%.3f over %d+%d sampled rays; anchors and oracle each proven falsifiable by an isolated control" %
		[frac_hi, frac_lo, ext_rate, int_rate, sweep["ext_n"], sweep["int_n"]])
	get_tree().quit(0)


## Class-knowable-by-construction anchors. The dome crest is the hull's top
## cap — a cave wall cannot be the highest point, the shell is HULL_ROCK thick
## above every void. The vertex nearest a room's centre bounds that room's
## carved void. (The LOWEST vertex is deliberately not an anchor: the hull's
## buried skirt reaches below the deepest floor, so the minimum is exterior —
## an easy wrong assumption.)
func _anchor_errors(verts: PackedVector3Array, colors: PackedColorArray) -> String:
	var top_i := _highest_index(verts)
	if colors[top_i].a < 0.99:
		return "the dome crest reads as cave (alpha %.3f at %s) — the crest is the outer hull by construction" \
			% [colors[top_i].a, verts[top_i]]
	var wall_i := _nearest_index(verts, _lay["rooms"][2]["center"])
	if colors[wall_i].a > 0.01:
		return "the main chamber wall reads as open sky (alpha %.3f at %s) — it bounds a carved void" \
			% [colors[wall_i].a, verts[wall_i]]
	return ""


## Marches along the vertex normal (which points toward the void the surface
## faces) and reports whether the ray strikes rock again within range.
func _ray_hits_rock(p: Vector3, n: Vector3) -> bool:
	var t := MARCH_START
	while t <= MARCH_RANGE:
		if CaveSystemGen.density(p + n * t, _lay, _noise) > ROCK_MARGIN:
			return true
		t += MARCH_STEP
	return false


func _oracle_agreement(verts: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray) -> Dictionary:
	var out := { "ext_n": 0, "ext_ok": 0, "int_n": 0, "int_ok": 0 }
	for i in range(0, verts.size(), SAMPLE_STRIDE):
		var a := colors[i].a
		if a > DECISIVE_HI:
			out["ext_n"] += 1
			if not _ray_hits_rock(verts[i], normals[i]):
				out["ext_ok"] += 1
		elif a < DECISIVE_LO:
			out["int_n"] += 1
			if _ray_hits_rock(verts[i], normals[i]):
				out["int_ok"] += 1
	return out


func _highest_index(verts: PackedVector3Array) -> int:
	var best := 0
	for i in verts.size():
		if verts[i].y > verts[best].y:
			best = i
	return best


func _nearest_index(verts: PackedVector3Array, to: Vector3) -> int:
	var best := 0
	var best_d := 1.0e12
	for i in verts.size():
		var d := verts[i].distance_squared_to(to)
		if d < best_d:
			best_d = d
			best = i
	return best


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
