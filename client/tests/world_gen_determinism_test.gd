extends Node
## Regression test for the WorldGen procedural foundation (issue #58).
##
## Pins the product laws world_gen.gd states only in comments:
##  1. DETERMINISM — "the same world every boot". A comprehensive world
##     fingerprint (the FULL baked terrain grid + every ruin/shrine piece's
##     placement, rotation and dimensions) is asserted three ways:
##       (a) equal between two builds whose process-global RNG was seeded to
##           DIFFERENT values — proving generation ignores the global RNG (the
##           realistic process-scoped source; Dictionaries iterate in insertion
##           order and hash() is unsalted in Godot 4);
##       (b) equal to a COMMITTED golden — a fresh boot each CI run must
##           reproduce it, so any once-per-process source (a clock-seeded
##           static, entropy) or an intentional world change turns it red. The
##           generator has no such source today (WORLD_SEED/CAVE_SEED constants
##           only), exactly as the server tier pins demoGoldenHash.
##  2. RUIN KEEP-OUTS — every ruin piece, expanded by a conservative bounding
##     radius (a colonnade spreads ~12 m from its site origin, and a piece's
##     own mesh adds a few metres), stays clear of the shrine clearing AND the
##     starter cave; sites lie within world bounds and number exactly
##     RUIN_SITES.
##  3. surface_height_at CONTRACT — the NO_GROUND sentinel outside the terrain,
##     a FINITE value inside (a NaN would defeat both the sentinel and the
##     tolerance test), and node-exactness against the baked grid (height_at).
##
## Pure and headless: builds WorldGen directly (never main.tscn), so it never
## touches the player's save. Physics-vs-analytic mesh agreement is a separate
## concern (surface_consistency_test); this pins GENERATION, not physics.
##
## Run: godot --headless --path client res://tests/world_gen_determinism_test.tscn

const HALF := WorldGen.SIZE / 2.0
## The same world every boot — a golden over the RNG-derived ruin/shrine
## placement (see _placement_fingerprint). Captured from a headless build;
## regenerate deliberately (the test prints it in record mode) only when the
## world is intentionally changed — like the server sim's demoGoldenHash, a
## change here is a reviewed act.
const GOLDEN_FINGERPRINT := "5f1dc3ab"

func _ready() -> void:
	# Perturb the process-global RNG to DIFFERENT states before each build: a
	# generator that leaked global randf()/randi() would then diverge, so
	# identical worlds here prove independence from that process-scoped source.
	var w1 := _build_world(0x5f3759df)
	var w2 := _build_world(0x1eb54a3d)

	# 1a. DETERMINISM — two builds agree on the WHOLE world (terrain + geometry).
	var fp1 := _world_fingerprint(w1)
	var fp2 := _world_fingerprint(w2)
	if fp1 != fp2:
		_fail("two builds disagree — determinism broken (%s vs %s)" % [fp1, fp2])
		return

	# 1b. DETERMINISM — placement matches the committed golden (cross-boot).
	# The golden fingerprints only the seeded-RNG-derived placement (ruin/shrine
	# x,z and rotations), NOT the noise-derived heights or generated mesh AABBs:
	# RNG placement is bit-identical across platforms (PCG integers + IEEE
	# add/mul, mm-quantised), so one committed value holds on every boot AND
	# every runner, whereas a noise/mesh golden could diverge between the
	# macOS capture and the Linux-only test runner (the float-determinism trap
	# the server tier avoids by going integer-only).
	var pf1 := _placement_fingerprint(w1)
	if GOLDEN_FINGERPRINT == "__RECORD__":
		print("RECORD placement golden: %s (full-world fp %s)" % [pf1, fp1])
	elif pf1 != GOLDEN_FINGERPRINT:
		_fail("placement fingerprint %s != golden %s — placement changed (intended? update the golden) or a boot-varying source crept in" %
			[pf1, GOLDEN_FINGERPRINT])
		return

	# 2. RUIN KEEP-OUTS and exact count.
	var sites1 := _ruin_sites(w1)
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
		# Each PIECE expanded by its bounding radius, not just its origin: a
		# wall/fallen column can extend metres past its centre into the flat
		# shrine clearing or onto the cave mouth.
		for piece: Node in site.get_children():
			if not (piece is Node3D):
				continue
			var wp: Vector3 = (piece as Node3D).global_position
			var r := _piece_radius(piece as Node3D)
			var pd := Vector2(wp.x, wp.z).length()
			if pd - r < WorldGen.SHRINE_CLEAR_RADIUS:
				_fail("a ruin piece near (%.1f, %.1f) reaches into the shrine clearing (%.1f - %.1f < %.1f)" %
					[wp.x, wp.z, pd, r, WorldGen.SHRINE_CLEAR_RADIUS])
				return
			if w1.cave_protects(wp.x, wp.z):
				_fail("a ruin piece near (%.1f, %.1f) sits on the starter cave (cave_protects)" % [wp.x, wp.z])
				return

	# 3. surface_height_at CONTRACT.
	if w1.surface_height_at(HALF + 10.0, 0.0) != WorldGen.NO_GROUND:
		_fail("surface_height_at past the +X edge should be NO_GROUND")
		return
	if w1.surface_height_at(0.0, -HALF - 10.0) != WorldGen.NO_GROUND:
		_fail("surface_height_at past the -Z edge should be NO_GROUND")
		return
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

	print("TEST PASS — world_gen deterministic (%s, global-RNG-invariant, golden-matched), %d ruins clear of shrine+cave, surface node-exact (worst %.4f m over %d)" %
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


## A comprehensive fingerprint of the whole generated world: the FULL baked
## terrain grid (all (QUADS+1)^2 nodes), then every ruin and shrine piece's
## world placement, rotation and mesh dimensions — so a leak that changes a
## single unsampled vertex, a ruin's kind/offset/rotation, or a piece's size is
## caught, not only a shifted site centre. Millimetre / 1e-4-rad quantisation
## keeps it robust to platform float noise while catching any real drift.
func _world_fingerprint(w: WorldGen) -> String:
	var acc := PackedInt32Array()
	var step := WorldGen.SIZE / WorldGen.QUADS
	for iz in WorldGen.QUADS + 1:
		for ix in WorldGen.QUADS + 1:
			acc.append(roundi(w.surface_height_at(ix * step - HALF, iz * step - HALF) * 1000.0))
	for site: Node3D in _ruin_sites(w):
		_fingerprint_subtree(site, acc)
	var shrine := w.get_node_or_null("WardensShrine")
	if shrine != null:
		_fingerprint_subtree(shrine, acc)
	return "%x" % hash(acc)


## Appends a node and its whole subtree's transforms + mesh sizes to `acc`.
func _fingerprint_subtree(node: Node, acc: PackedInt32Array) -> void:
	if node is Node3D:
		var n3 := node as Node3D
		acc.append(roundi(n3.position.x * 1000.0))
		acc.append(roundi(n3.position.y * 1000.0))
		acc.append(roundi(n3.position.z * 1000.0))
		acc.append(roundi(n3.rotation.x * 10000.0))
		acc.append(roundi(n3.rotation.y * 10000.0))
		acc.append(roundi(n3.rotation.z * 10000.0))
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var s := (node as MeshInstance3D).mesh.get_aabb().size
		acc.append(roundi(s.x * 1000.0))
		acc.append(roundi(s.y * 1000.0))
		acc.append(roundi(s.z * 1000.0))
	for child in node.get_children():
		_fingerprint_subtree(child, acc)


## The cross-platform-stable placement fingerprint used for the committed
## golden: every ruin and shrine piece's world x, z and rotation — all derived
## from the seeded RNGs (PCG integers + IEEE add/mul) and mm/1e-4-quantised, so
## it is identical on every boot and every runner. Deliberately omits the
## noise-derived y height and generated mesh AABBs, whose float math could
## differ between the capture host and the Linux CI runner.
func _placement_fingerprint(w: WorldGen) -> String:
	var acc := PackedInt32Array()
	var nodes: Array = _ruin_sites(w)
	var shrine := w.get_node_or_null("WardensShrine")
	if shrine != null:
		nodes.append(shrine)
	for n: Node in nodes:
		_placement_of(n, acc)
	return "%x" % hash(acc)


## Appends the x, z and rotation of a node's whole Node3D subtree to `acc`.
func _placement_of(node: Node, acc: PackedInt32Array) -> void:
	if node is Node3D:
		var n3 := node as Node3D
		acc.append(roundi(n3.position.x * 1000.0))
		acc.append(roundi(n3.position.z * 1000.0))
		acc.append(roundi(n3.rotation.x * 10000.0))
		acc.append(roundi(n3.rotation.y * 10000.0))
		acc.append(roundi(n3.rotation.z * 10000.0))
	for child in node.get_children():
		_placement_of(child, acc)


## A conservative, rotation-invariant bounding radius for a ruin piece: half
## the diagonal of its mesh AABB. Over-approximates (counts vertical extent as
## horizontal), so `dist - radius >= clearing` is a sound "does not intrude".
func _piece_radius(piece: Node3D) -> float:
	var r := 0.0
	for child in piece.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).mesh != null:
			r = maxf(r, (child as MeshInstance3D).mesh.get_aabb().size.length() * 0.5)
	return r


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


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
