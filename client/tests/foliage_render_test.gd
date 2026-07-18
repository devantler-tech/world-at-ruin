extends Node
## Regression test for foliage RENDERED into the real world (issue #101).
##
## foliage_scatter_test (#81) pins the FoliageGen library against synthetic
## params and an analytic ground plane. This pins the thing that library exists
## for: that WorldGen actually scatters props into the Ashfall Reach, against the
## REAL terrain, the REAL landmarks and hundreds of props at once.
##
## What it holds:
##  1. PRESENT — foliage really is in the world, in quantity, across several
##     cosmetic kinds (an unwired library was exactly the bug #101 fixed, and it
##     would pass every library-level test).
##  2. DETERMINISTIC — two builds whose process-global RNG was seeded DIFFERENTLY
##     produce byte-identical foliage, so "the same world every boot" covers
##     scenery too (the #58 law, extended to props).
##  3. CLEAR OF EVERY LANDMARK — no prop inside the shrine clearing, on a ruin
##     site's footprint, or over the starter cave (cave_protects), and none
##     outside world bounds.
##  4. ON THE GROUND — every prop rests within a hand's width of the sampled
##     surface, so nothing hovers or sinks out of sight.
##  5. COLLISION-FREE — foliage adds no physics body at all, so it cannot change
##     traversal. This is the guardrail that keeps scenery from becoming terrain.
##  6. CROSS-BOOT GOLDEN (#152) — the real composition matches a committed
##     fingerprint, the #58 reviewed-act discipline. Foliage never entered the
##     WORLD golden (MultiMesh instances are unreadable headlessly), so without
##     this a drifted density or kind field would be invisible to CI.
##  7. COMPOSED, NOT CONFETTI (#152) — per-cell dispersion of the real
##     composition sits well above a uniform scatter's, so thickets and
##     clearings are a pinned property of the shipped world, not a hope.
##
## Pure and headless: builds WorldGen directly (never main.tscn), so it never
## touches the player's save.
##
## Run: godot --headless --path client res://tests/foliage_render_test.tscn

const HALF := WorldGen.SIZE / 2.0
## The same composition every boot — a golden over every prop position (see
## _fingerprint). Regenerate deliberately (record mode prints it) only when
## placement is intentionally changed; like the #58 world golden, a change
## here is a reviewed act.
const GOLDEN_FINGERPRINT := "75dc1a3"


func _ready() -> void:
	# Perturb the process-global RNG differently before each build: foliage that
	# leaked randf()/randi() would diverge between the two.
	var w1 := _build_world(0x51ed270b)
	var w2 := _build_world(0x2f8a13c4)

	# 1. PRESENT — the library is actually wired in, and the density field
	# composes the SAME prop budget it inherited (#152's guardrail): clustering
	# must never quietly starve the world of cover.
	var props1 := _props(w1)
	if props1.size() != WorldGen.FOLIAGE_COUNT:
		_fail("the world scattered %d props, not the budgeted %d — the density field must recompose the budget, never shrink it" % [props1.size(), WorldGen.FOLIAGE_COUNT])
		return
	var kinds_seen := {}
	for batch: MultiMeshInstance3D in _batches(w1):
		kinds_seen[str(batch.name)] = true
	if kinds_seen.size() < 2:
		_fail("foliage uses only %d kind batch(es) — the cosmetic variety is not reaching the world" % kinds_seen.size())
		return
	# The placement record must account for EVERY rendered instance. instance_count
	# IS readable headlessly (only the transforms are not), so this is what stops
	# the record silently drifting from the MultiMeshes the player actually sees —
	# without it, every assertion below could pass against a stale list.
	var instanced := 0
	for batch: MultiMeshInstance3D in _batches(w1):
		if batch.multimesh != null:
			instanced += batch.multimesh.instance_count
	if instanced != props1.size():
		_fail("%d rendered instances but %d recorded placements — the record has drifted from the world" %
			[instanced, props1.size()])
		return

	# 2. DETERMINISTIC — two builds agree exactly.
	var fp1 := _fingerprint(props1)
	var fp2 := _fingerprint(_props(w2))
	if fp1 != fp2:
		_fail("two builds scattered different foliage — determinism broken or the global RNG leaked (%s vs %s)" % [fp1, fp2])
		return

	# 2b. CROSS-BOOT — the composition matches the committed golden. Placement
	# is now driven by the density and kind fields (#152); a drift in either
	# is invisible to the world golden, so it must be red HERE.
	if GOLDEN_FINGERPRINT == "__RECORD__":
		print("RECORD foliage placement golden: %s" % fp1)
	elif fp1 != GOLDEN_FINGERPRINT:
		_fail("foliage placement fingerprint %s != golden %s — the composition changed (intended? update the golden) or a boot-varying source crept in" % [fp1, GOLDEN_FINGERPRINT])
		return

	# 7. COMPOSED, NOT CONFETTI (#152) — the acceptance criterion made a law:
	# per-cell dispersion (count variance / mean, 10×10 grid) of the real
	# composition must sit well above the uniform wiring's. Measured: 1.70
	# with the density field ablated (keep-outs alone clump a little), 8.99
	# with it live — the 2.0 floor splits them, and the world is
	# deterministic, so this number is a constant, not a flake surface.
	var vmr := _dispersion(props1)
	if vmr < 2.0:
		_fail("foliage dispersion %.2f — the composition reads as uniform confetti, not thickets and clearings" % vmr)
		return

	# 8. SHELTER (#152 review) — cover must prefer the low ground: on
	# comparably FLAT terrain, the density field responds to ELEVATION, so a
	# flat ridge-top and a flat hollow never read the same. The raw class
	# means are confounded: the few flat hilltops sit under whatever the
	# independent thicket-noise happens to be (measured live: it cancelled a
	# real 0.66× exposure factor), so divide the noise term OUT — it is
	# public spec (the field's own noise object + the BARE/FULL band) — and
	# compare the residual height-and-slope response between the classes.
	var low_sum := 0.0
	var low_n := 0
	var high_sum := 0.0
	var high_n := 0
	# High ground is rarely dead-flat (peaks curve), so the "comparably flat"
	# cap is generous (slope01 < 0.45, identical for both classes) and the
	# probe pitch fine (2 m) — otherwise the high class is too small to mean
	# anything, which is exactly what the vacuity floor below guards.
	var probe := -104.0
	while probe <= 104.0:
		var pz := -104.0
		while pz <= 104.0:
			var h := w1.surface_height_at(probe, pz)
			if h > WorldGen.NO_GROUND and w1._foliage_slope01(probe, pz) < 0.45:
				var n01: float = w1._foliage_density.get_noise_2d(probe, pz) * 0.5 + 0.5
				var noise_term := smoothstep(WorldGen.FOLIAGE_BARE_BELOW, WorldGen.FOLIAGE_FULL_ABOVE, n01)
				# In the bare band the density is 0 whatever the height says —
				# nothing to divide, nothing to learn about elevation there.
				if noise_term >= 0.1:
					var residual: float = w1._foliage_density_at(probe, pz) / noise_term
					if h < 0.0:
						low_sum += residual
						low_n += 1
					elif h > 3.5:
						high_sum += residual
						high_n += 1
			pz += 2.0
		probe += 2.0
	if low_n < 40 or high_n < 40:
		_fail("shelter check is vacuous: only %d low-flat and %d high-flat samples" % [low_n, high_n])
		return
	var low_mean := low_sum / float(low_n)
	var high_mean := high_sum / float(high_n)
	if low_mean < high_mean * 1.15:
		_fail("noise-normalised density response on flat low ground (%.3f) is not materially above flat high ground (%.3f) — elevation is not sheltering the hollows" % [low_mean, high_mean])
		return

	# 3. CLEAR OF EVERY LANDMARK.
	var ruins := _ruin_sites(w1)
	if ruins.size() != WorldGen.RUIN_SITES:
		_fail("expected %d ruin sites, found %d — foliage nodes are polluting the ruin scan" % [WorldGen.RUIN_SITES, ruins.size()])
		return
	for pos: Vector3 in props1:
		var planar := Vector2(pos.x, pos.z)
		if absf(pos.x) > HALF or absf(pos.z) > HALF:
			_fail("a prop at (%.1f, %.1f) is outside the world bounds (+/-%.1f)" % [pos.x, pos.z, HALF])
			return
		if planar.length() < WorldGen.SHRINE_CLEAR_RADIUS:
			_fail("a prop at (%.1f, %.1f) grew inside the shrine clearing (%.1f < %.1f)" %
				[pos.x, pos.z, planar.length(), WorldGen.SHRINE_CLEAR_RADIUS])
			return
		if w1.cave_protects(pos.x, pos.z):
			_fail("a prop at (%.1f, %.1f) grew over the starter cave" % [pos.x, pos.z])
			return
		for site: Node3D in ruins:
			var d := planar.distance_to(Vector2(site.position.x, site.position.z))
			if d < WorldGen.FOLIAGE_RUIN_CLEARANCE:
				_fail("a prop at (%.1f, %.1f) sits on a ruin footprint (%.1f < %.1f)" %
					[pos.x, pos.z, d, WorldGen.FOLIAGE_RUIN_CLEARANCE])
				return

	# 4. ON THE GROUND — a prop is lifted to rest on the surface, never hovering.
	var worst := 0.0
	for pos: Vector3 in props1:
		var ground := w1.surface_height_at(pos.x, pos.z)
		if ground == WorldGen.NO_GROUND:
			_fail("a prop at (%.1f, %.1f) has no ground under it" % [pos.x, pos.z])
			return
		worst = maxf(worst, absf(pos.y - ground))
	if worst > 1.0:
		_fail("a prop floats or sinks %.2f m from the surface — foliage is not resting on the ground" % worst)
		return

	# 5. COLLISION-FREE — scenery must never become terrain.
	for batch: MultiMeshInstance3D in _batches(w1):
		if _has_physics(batch):
			_fail("foliage batch '%s' carries a physics body — scenery must not change traversal" % str(batch.name))
			return

	print("TEST PASS — foliage rendered into the world (%s, golden-matched): %d props across %d kind batches, deterministic, clustered (dispersion %.2f), clear of shrine/ruins/cave, grounded within %.2f m, collision-free" %
		[fp1, props1.size(), kinds_seen.size(), vmr, worst])
	get_tree().quit(0)


## A fresh WorldGen built into the tree, after seeding the process-global RNG to
## `salt` — correct generation ignores it, so two salts must agree.
func _build_world(salt: int) -> WorldGen:
	seed(salt)
	var w := WorldGen.new()
	add_child(w)
	return w


## Every foliage batch node (one MultiMeshInstance3D per cosmetic kind).
func _batches(w: WorldGen) -> Array[MultiMeshInstance3D]:
	var out: Array[MultiMeshInstance3D] = []
	for child in w.get_children():
		if child is MultiMeshInstance3D:
			out.append(child as MultiMeshInstance3D)
	return out


## Every rendered prop's WORLD position, in render order.
##
## Read from WorldGen's placement record, NOT from the MultiMeshes: a MultiMesh
## keeps its instance transforms in the RenderingServer, which `--headless` does
## not back (every transform reads back as identity and `buffer` is empty), so a
## readback-based assertion would be vacuously wrong in CI. The record is written
## in the same order the MultiMeshes are filled.
func _props(w: WorldGen) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for placement: Dictionary in w.foliage_placements():
		out.append(placement["pos"] as Vector3)
	return out


## A millimetre-quantised fingerprint of every prop position — robust to platform
## float noise, sensitive to any real placement drift.
func _fingerprint(props: Array[Vector3]) -> String:
	var acc := PackedInt32Array()
	for pos: Vector3 in props:
		acc.append(roundi(pos.x * 1000.0))
		acc.append(roundi(pos.y * 1000.0))
		acc.append(roundi(pos.z * 1000.0))
	return "%x" % hash(acc)


## Index of dispersion (variance-to-mean) of per-cell prop counts over a 10×10
## grid covering the world — ~1 for a uniform scatter of a fixed count, several
## times that once cover gathers into thickets. Edge cells clamp so a prop at
## the exact bound is counted, never dropped.
func _dispersion(props: Array[Vector3]) -> float:
	var cells := {}
	var cell_size := HALF * 2.0 / 10.0
	for pos: Vector3 in props:
		var gx := clampi(floori((pos.x + HALF) / cell_size), 0, 9)
		var gz := clampi(floori((pos.z + HALF) / cell_size), 0, 9)
		var key := Vector2i(gx, gz)
		cells[key] = int(cells.get(key, 0)) + 1
	var mean := float(props.size()) / 100.0
	if mean <= 0.0:
		return 0.0
	var var_acc := 0.0
	for gx in 10:
		for gz in 10:
			var c := float(cells.get(Vector2i(gx, gz), 0))
			var_acc += (c - mean) * (c - mean)
	return (var_acc / 100.0) / mean


## Whether `node` or any descendant is a physics body or collision shape.
func _has_physics(node: Node) -> bool:
	if node is CollisionObject3D or node is CollisionShape3D:
		return true
	for child in node.get_children():
		if _has_physics(child):
			return true
	return false


## The scattered ruin SITE nodes: scriptless native Node3Ds that are not the
## shrine (Godot uniquifies their duplicate names by CLASS, so match structure).
func _ruin_sites(w: WorldGen) -> Array[Node3D]:
	var out: Array[Node3D] = []
	for child in w.get_children():
		if child.get_class() != "Node3D" or child.get_script() != null:
			continue
		if str(child.name) == "WardensShrine":
			continue
		out.append(child as Node3D)
	return out


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
