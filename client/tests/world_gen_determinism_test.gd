extends Node
## Regression test for the WorldGen procedural foundation (issue #58).
##
## Pins the product laws world_gen.gd states only in comments:
##  1. DETERMINISM — "the same world every boot". Two builds produce an
##     identical terrain-height fingerprint and identical ruin placements,
##     AND stay identical when the process-global RNG is perturbed between
##     them — proving generation depends only on its own seeded RNGs, never on
##     process-scoped state (the global RNG is the one such source in Godot 4;
##     Dictionaries iterate in insertion order and hash() is unsalted, so
##     same-process comparison is a faithful stand-in for a fresh boot here).
##  2. RUIN KEEP-OUTS — every scattered ruin, down to its individual pieces
##     (a colonnade spreads ~12 m from its site origin), stays clear of the
##     shrine clearing AND the starter cave; sites lie within world bounds and
##     number exactly RUIN_SITES. A refactor could drop a column inside the
##     shrine or across the cave mouth otherwise.
##  3. surface_height_at CONTRACT — the NO_GROUND sentinel outside the
##     terrain, a FINITE value inside (a NaN would silently defeat both the
##     sentinel and the tolerance comparison), and node-exactness against the
##     baked height grid (height_at).
##
## Pure and headless: builds WorldGen directly (never main.tscn), so it never
## touches the player's save. Physics-vs-analytic mesh agreement is a separate
## concern (surface_consistency_test); this pins GENERATION, not physics.
##
## Run: godot --headless --path client res://tests/world_gen_determinism_test.tscn

const HALF := WorldGen.SIZE / 2.0

func _ready() -> void:
	# Perturb the process-global RNG to DIFFERENT states before each build: a
	# generator that leaked global randf()/randi() would then diverge (as the
	# determinism RED-probe confirms), so identical worlds here prove the
	# generation is independent of process-scoped state — a stronger guarantee
	# than comparing two vanilla same-process builds.
	var w1 := _build_world(0x5f3759df)
	var w2 := _build_world(0x1eb54a3d)

	# 1. DETERMINISM — identical terrain surface between two builds.
	var fp1 := _terrain_fingerprint(w1)
	var fp2 := _terrain_fingerprint(w2)
	if fp1 != fp2:
		_fail("two builds disagree on terrain — determinism broken (%s vs %s)" % [fp1, fp2])
		return

	# 1b. DETERMINISM — identical ruin placement (order and position).
	var sites1 := _ruin_sites(w1)
	var sites2 := _ruin_sites(w2)
	if _centres(sites1) != _centres(sites2):
		_fail("two builds disagree on ruin placement — determinism broken (%d vs %d sites)" %
			[sites1.size(), sites2.size()])
		return

	# 2. RUIN KEEP-OUTS and exact count.
	if sites1.size() != WorldGen.RUIN_SITES:
		_fail("expected %d ruin sites, built %d" % [WorldGen.RUIN_SITES, sites1.size()])
		return
	var shrine_min := WorldGen.SHRINE_CLEAR_RADIUS + 6.0
	for site: Node3D in sites1:
		var c := Vector2(site.position.x, site.position.z)
		if c.length() < shrine_min:
			_fail("ruin site at (%.1f, %.1f) intrudes on the shrine clearing (%.1f < %.1f)" %
				[c.x, c.y, c.length(), shrine_min])
			return
		if absf(c.x) > HALF or absf(c.y) > HALF:
			_fail("ruin site at (%.1f, %.1f) is outside the world bounds (+/-%.1f)" % [c.x, c.y, HALF])
			return
		# Every PIECE (column/wall/rubble body), not just the site origin: a
		# colonnade reaches ~12 m inward, so a site just past the threshold can
		# still drop geometry into the flat shrine clearing or onto the cave.
		for piece: Node in site.get_children():
			if not (piece is Node3D):
				continue
			var wp: Vector3 = (piece as Node3D).global_position
			var pd := Vector2(wp.x, wp.z).length()
			if pd < WorldGen.SHRINE_CLEAR_RADIUS:
				_fail("a ruin piece at (%.1f, %.1f) sits inside the shrine clearing (%.1f < %.1f)" %
					[wp.x, wp.z, pd, WorldGen.SHRINE_CLEAR_RADIUS])
				return
			if w1.cave_protects(wp.x, wp.z):
				_fail("a ruin piece at (%.1f, %.1f) sits on the starter cave (cave_protects)" % [wp.x, wp.z])
				return

	# 3. surface_height_at CONTRACT.
	# Outside the terrain grid -> the NO_GROUND sentinel, both axes.
	if w1.surface_height_at(HALF + 10.0, 0.0) != WorldGen.NO_GROUND:
		_fail("surface_height_at past the +X edge should be NO_GROUND")
		return
	if w1.surface_height_at(0.0, -HALF - 10.0) != WorldGen.NO_GROUND:
		_fail("surface_height_at past the -Z edge should be NO_GROUND")
		return
	# Inside -> FINITE, and node-exact against the baked grid (height_at). The
	# finiteness check is explicit: a NaN would slip past the sentinel test and
	# make the |drift| tolerance comparison vacuously false.
	var step := WorldGen.SIZE / WorldGen.QUADS
	var worst := 0.0
	var sampled := 0
	for iz in range(4, WorldGen.QUADS, 11):
		for ix in range(4, WorldGen.QUADS, 11):
			var x := ix * step - HALF
			var z := iz * step - HALF
			var s := w1.surface_height_at(x, z)
			var ref := w1.height_at(x, z)
			if s == WorldGen.NO_GROUND:
				_fail("surface_height_at returned NO_GROUND inside the grid at (%.2f, %.2f)" % [x, z])
				return
			if not is_finite(s) or not is_finite(ref):
				_fail("non-finite interior height at (%.2f, %.2f): surface=%s height_at=%s" % [x, z, s, ref])
				return
			worst = maxf(worst, absf(s - ref))
			sampled += 1
	if worst > 0.001:
		_fail("surface_height_at drifts from the baked grid at nodes (worst %.4f m over %d)" %
			[worst, sampled])
		return

	print("TEST PASS — world_gen deterministic (%s, global-RNG-invariant), %d ruins (pieces) clear of shrine+cave, surface node-exact (worst %.4f m over %d)" %
		[fp1, sites1.size(), worst, sampled])
	get_tree().quit(0)


## Builds a fresh WorldGen into the tree (its _ready runs the full generation
## synchronously), after seeding the process-global RNG to `salt` — a correct
## generator ignores it, so two builds with different salts must be identical.
func _build_world(salt: int) -> WorldGen:
	seed(salt)
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


## The scattered ruin SITE nodes, in build order. Ruin sites are scriptless
## native Node3Ds; Godot uniquifies their duplicate "Ruin" names to "@Node3D@N"
## (the CLASS, not the assigned name), so match on structure instead: the other
## children are excluded by class (Terrain = MeshInstance3D, TerrainBody =
## StaticBody3D) or by script (StarterCave = CaveSystemGen); the shrine is
## excluded by its stable name.
func _ruin_sites(w: WorldGen) -> Array:
	var out: Array = []
	for child in w.get_children():
		if child.get_class() != "Node3D" or child.get_script() != null:
			continue
		if str(child.name) == "WardensShrine":
			continue
		out.append(child)
	return out


func _centres(sites: Array) -> Array:
	var out: Array = []
	for site: Node3D in sites:
		out.append(Vector2(site.position.x, site.position.z))
	return out


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
