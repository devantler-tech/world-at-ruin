extends Node
## Regression test for the WorldGen procedural foundation (issue #58).
##
## Pins the product laws world_gen.gd states only in comments:
##  1. DETERMINISM — "the same world every boot". Two independent builds
##     produce an identical terrain-height fingerprint and identical ruin
##     placements. A leaked non-seeded randf(), a reordered Dictionary
##     iteration, or a stray global would break this silently, with no CI
##     signal.
##  2. RUIN KEEP-OUTS — every scattered ruin stays clear of the shrine
##     clearing AND the starter cave (cave_protects), lies within world
##     bounds, and the count is exactly RUIN_SITES. A refactor could drop a
##     column inside the shrine or across the cave mouth otherwise.
##  3. surface_height_at CONTRACT — the NO_GROUND sentinel outside the
##     terrain, a finite value inside, and node-exactness against the baked
##     height grid (height_at).
##
## Pure and headless: builds WorldGen directly (never main.tscn), so it never
## touches the player's save. Physics-vs-analytic mesh agreement is a separate
## concern (surface_consistency_test); this pins GENERATION, not physics.
##
## Run: godot --headless --path client res://tests/world_gen_determinism_test.tscn

const HALF := WorldGen.SIZE / 2.0

func _ready() -> void:
	var w1 := _build_world()
	var w2 := _build_world()

	# 1. DETERMINISM — identical terrain surface between two builds.
	var fp1 := _terrain_fingerprint(w1)
	var fp2 := _terrain_fingerprint(w2)
	if fp1 != fp2:
		_fail("two builds disagree on terrain — determinism broken (%s vs %s)" % [fp1, fp2])
		return

	# 1b. DETERMINISM — identical ruin placement (order and position).
	var ruins1 := _ruin_centres(w1)
	var ruins2 := _ruin_centres(w2)
	if ruins1 != ruins2:
		_fail("two builds disagree on ruin placement — determinism broken (%d vs %d sites)" %
			[ruins1.size(), ruins2.size()])
		return

	# 2. RUIN KEEP-OUTS and exact count.
	if ruins1.size() != WorldGen.RUIN_SITES:
		_fail("expected %d ruin sites, built %d" % [WorldGen.RUIN_SITES, ruins1.size()])
		return
	var shrine_min := WorldGen.SHRINE_CLEAR_RADIUS + 6.0
	for c: Vector2 in ruins1:
		if c.length() < shrine_min:
			_fail("ruin at (%.1f, %.1f) intrudes on the shrine clearing (%.1f < %.1f)" %
				[c.x, c.y, c.length(), shrine_min])
			return
		if w1.cave_protects(c.x, c.y):
			_fail("ruin at (%.1f, %.1f) sits on the starter cave (cave_protects)" % [c.x, c.y])
			return
		if absf(c.x) > HALF or absf(c.y) > HALF:
			_fail("ruin at (%.1f, %.1f) is outside the world bounds (+/-%.1f)" % [c.x, c.y, HALF])
			return

	# 3. surface_height_at CONTRACT.
	# Outside the terrain grid -> the NO_GROUND sentinel, both axes.
	if w1.surface_height_at(HALF + 10.0, 0.0) != WorldGen.NO_GROUND:
		_fail("surface_height_at past the +X edge should be NO_GROUND")
		return
	if w1.surface_height_at(0.0, -HALF - 10.0) != WorldGen.NO_GROUND:
		_fail("surface_height_at past the -Z edge should be NO_GROUND")
		return
	# Inside -> finite, and node-exact against the baked grid (height_at).
	var step := WorldGen.SIZE / WorldGen.QUADS
	var worst := 0.0
	var sampled := 0
	for iz in range(4, WorldGen.QUADS, 11):
		for ix in range(4, WorldGen.QUADS, 11):
			var x := ix * step - HALF
			var z := iz * step - HALF
			var s := w1.surface_height_at(x, z)
			if s == WorldGen.NO_GROUND:
				_fail("surface_height_at returned NO_GROUND inside the grid at (%.2f, %.2f)" % [x, z])
				return
			worst = maxf(worst, absf(s - w1.height_at(x, z)))
			sampled += 1
	if worst > 0.001:
		_fail("surface_height_at drifts from the baked grid at nodes (worst %.4f m over %d)" %
			[worst, sampled])
		return

	print("TEST PASS — world_gen deterministic (%s), %d ruins clear of shrine+cave, surface node-exact (worst %.4f m over %d)" %
		[fp1, ruins1.size(), worst, sampled])
	get_tree().quit(0)


## Builds a fresh WorldGen into the tree (its _ready runs the full generation
## synchronously), so each call is an independent "boot" of the same world.
func _build_world() -> WorldGen:
	var w := WorldGen.new()
	add_child(w)
	return w


## A stable fingerprint of the terrain surface: surface_height_at on a coarse
## lattice, quantised to the millimetre, hashed. Quantisation is robust to
## platform float noise while still catching any real drift between builds.
func _terrain_fingerprint(w: WorldGen) -> String:
	var step := WorldGen.SIZE / 32.0
	var acc := PackedInt32Array()
	for iz in 33:
		for ix in 33:
			var x := ix * step - HALF
			var z := iz * step - HALF
			acc.append(roundi(w.surface_height_at(x, z) * 1000.0))
	return "%x" % hash(acc)


## The world-space XZ centres of every scattered ruin site, in build order.
## Ruin sites are scriptless native Node3Ds; Godot uniquifies their duplicate
## "Ruin" names to "@Node3D@N" (the CLASS, not the assigned name), so match on
## structure instead: the only scriptless bare-Node3D children are the ruins
## and the shrine. The other fixtures are excluded by class (Terrain =
## MeshInstance3D, TerrainBody = StaticBody3D) or by script (StarterCave =
## CaveSystemGen); the shrine is excluded by its stable name.
func _ruin_centres(w: WorldGen) -> Array:
	var out: Array = []
	for child in w.get_children():
		if child.get_class() != "Node3D" or child.get_script() != null:
			continue
		if str(child.name) == "WardensShrine":
			continue
		var p := (child as Node3D).position
		out.append(Vector2(p.x, p.z))
	return out


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
