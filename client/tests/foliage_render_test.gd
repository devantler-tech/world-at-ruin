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
##
## Pure and headless: builds WorldGen directly (never main.tscn), so it never
## touches the player's save.
##
## Run: godot --headless --path client res://tests/foliage_render_test.tscn

const HALF := WorldGen.SIZE / 2.0


func _ready() -> void:
	# Perturb the process-global RNG differently before each build: foliage that
	# leaked randf()/randi() would diverge between the two.
	var w1 := _build_world(0x51ed270b)
	var w2 := _build_world(0x2f8a13c4)

	# 1. PRESENT — the library is actually wired in.
	var props1 := _props(w1)
	if props1.size() < 200:
		_fail("only %d foliage props in the world — FoliageGen looks unwired or barely scattering" % props1.size())
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

	print("TEST PASS — foliage rendered into the world (%s): %d props across %d kind batches, deterministic, clear of shrine/ruins/cave, grounded within %.2f m, collision-free" %
		[fp1, props1.size(), kinds_seen.size(), worst])
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
