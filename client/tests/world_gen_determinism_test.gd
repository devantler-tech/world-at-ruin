extends Node
## Regression test for the WorldGen procedural foundation (issue #58).
##
## Pins the product laws world_gen.gd states only in comments:
##  1. DETERMINISM — "the same world every boot". A fingerprint of the WHOLE
##     generated world (the full baked terrain grid + every terrain, ruin,
##     shrine and cave node's placement, rotation and mesh dimensions) is
##     asserted two ways:
##       (a) equal between two builds whose process-global RNG was seeded to
##           DIFFERENT values — proving generation ignores the global RNG (the
##           realistic process-scoped source; Godot 4 Dictionaries iterate in
##           insertion order and hash() is unsalted);
##       (b) equal to a COMMITTED golden — each CI run is a fresh boot, so any
##           once-per-process source (a clock-seeded static, entropy) affecting
##           ANY generated state, or an intentional world change, turns it red.
##           Like the server sim's demoGoldenHash, a change here is a reviewed
##           act. The whole fingerprint is millimetre / 1e-4-rad quantised, so
##           it is stable across boots AND runners (the generator has no
##           transcendental-heavy or FMA-sensitive path; placement even runs
##           through cos/sin and still matches the Linux CI runner bit-for-bit).
##  2. RUIN KEEP-OUTS — every ruin piece stays clear of the shrine clearing
##     (checked against its true radius, since the clearing has no built-in
##     margin) AND the starter cave (a centre test against cave_protects, whose
##     3 m hull padding exceeds every piece's radius — a precondition the test
##     asserts); sites lie within world bounds and number exactly RUIN_SITES.
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
## The same world every boot — a golden over ALL generated state (see
## _world_fingerprint). Captured from a headless build; regenerate deliberately
## (the test prints it in record mode) only when the world is intentionally
## changed — like the server sim's demoGoldenHash, a change here is a reviewed
## act.
## Ruin silhouettes (#151): columns, walls and rubble are generated meshes with
## broken profiles rather than primitives, and this fingerprint now hashes mesh
## VERTICES as well as AABB size — a bounding box cannot see a changed break, so
## without that the golden would bless a reshaped ruin silently.
## v0.1.17: torches became wall-anchored and gained bracket/head/flame parts,
## which moves and re-shapes their nodes. Regenerated ON TOP of main's foliage
## golden (f5dcfa96) rather than taking either side of the merge — both changes
## are in this value. The cave rock mesh itself is BYTE-IDENTICAL across seeds
## 42/7/1234, so the torch contribution is fixtures-only, not terrain.
## v0.12.0 (#282): ruin and shrine pieces are now seated from the LOWEST
## walkable surface under their own footprint instead of one `height_at` sample
## at their origin, so 72 of 188 pieces that hung in the air — one by 1076 mm —
## come down into the ground. Only the pieces' Y moves: the placement rng stream
## is untouched (the rotation draws were reordered ahead of seating with no
## other draw between them), which the global-RNG-invariance assertion above
## independently confirms.
## v0.15.1 (#282): ruin and shrine pieces are seated from the LOWEST walkable
## surface under their own footprint instead of one `height_at` sample at their
## origin, so 72 of 188 pieces that hung in the air — one by 1076 mm — come down
## into the ground. Regenerated a second time after review: the footprint is now
## the piece's ACTUAL rectangle (a generated mesh's AABB is not centred on its
## origin, and a fallen column's in-body offset rotates into a horizontal shift)
## and the sweep also visits the quad-diagonal crossings on its edges, which
## together take the worst residual float from 13 mm to 0. Only the pieces' Y
## moves: the placement rng stream is untouched, which the global-RNG-invariance
## assertion above confirms independently.
## v0.19.1 (#282): ruin and shrine pieces are seated from the LOWEST walkable
## surface under their own footprint instead of one `height_at` sample at their
## origin, so 72 of 188 pieces that hung in the air — one by 1076 mm — come down
## into the ground. Regenerated across three review rounds: the footprint is now
## the piece's TRUE rotated outline (the XZ convex hull of its box) rather than
## that outline's enclosing rectangle, which was sinking pieces a mean 83 mm and
## up to 641 mm too deep into ground they never covered; it carries a fallen
## column's in-body offset through the rotation; and the sweep visits the
## quad-diagonal crossings on its edges. Worst residual float: 0 mm. Only the
## pieces' Y moves — the placement rng stream is untouched, which the
## global-RNG-invariance assertion above confirms independently.
const GOLDEN_FINGERPRINT := "65f927d"



## world_gen's cave_protects pads the cave hull by this many metres. A piece
## whose bounding radius is within that padding cannot reach the hull when its
## centre is outside cave_protects, which makes the cheap centre test a SOUND
## keep-out guard (the assertion below keeps that precondition true).
const CAVE_KEEPOUT_PADDING := 3.0

func _ready() -> void:
	# Perturb the process-global RNG to DIFFERENT states before each build: a
	# generator that leaked global randf()/randi() would then diverge, so
	# identical worlds here prove independence from that process-scoped source.
	var w1 := _build_world(0x5f3759df)
	var w2 := _build_world(0x1eb54a3d)

	# 1a. DETERMINISM — two builds agree on the WHOLE world.
	var fp1 := _world_fingerprint(w1)
	var fp2 := _world_fingerprint(w2)
	if fp1 != fp2:
		_fail("two builds disagree — determinism broken (%s vs %s)" % [fp1, fp2])
		return

	# 1b. DETERMINISM — the whole world matches the committed golden (cross-boot).
	if GOLDEN_FINGERPRINT == "__RECORD__":
		print("RECORD world golden: %s" % fp1)
	elif fp1 != GOLDEN_FINGERPRINT:
		_fail("world fingerprint %s != golden %s — the world changed (intended? update the golden) or a boot-varying source crept in" %
			[fp1, GOLDEN_FINGERPRINT])
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
		# Each PIECE expanded by its bounding radius, against BOTH keep-outs: a
		# wall/fallen column can reach metres past its centre into the flat
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
			# cave_protects is the cave hull padded by CAVE_KEEPOUT_PADDING, so a
			# piece whose centre is outside it cannot reach the hull as long as
			# the piece's radius is within that padding — the centre test is then
			# exact (no false positive on a piece resting in the safety buffer).
			if r > CAVE_KEEPOUT_PADDING:
				_fail("ruin piece radius %.1f m exceeds the cave keep-out padding %.1f m — the centre-based cave guard is no longer sound; widen it" %
					[r, CAVE_KEEPOUT_PADDING])
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


## A fingerprint of the WHOLE generated world: the full baked terrain grid
## (all (QUADS+1)^2 nodes), then every direct child's subtree (terrain, ruins,
## shrine AND the starter cave) captured as node placement, rotation and mesh
## dimensions. Millimetre / 1e-4-rad quantised so it is robust to platform
## float noise while catching any real drift (a shifted vertex, a changed ruin
## kind/offset/rotation/size, or altered cave geometry).
func _world_fingerprint(w: WorldGen) -> String:
	var acc := PackedInt32Array()
	var step := WorldGen.SIZE / WorldGen.QUADS
	for iz in WorldGen.QUADS + 1:
		for ix in WorldGen.QUADS + 1:
			acc.append(roundi(w.surface_height_at(ix * step - HALF, iz * step - HALF) * 1000.0))
	for child in w.get_children():
		_fingerprint_subtree(child, acc)
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
		var mesh := (node as MeshInstance3D).mesh
		var s := mesh.get_aabb().size
		acc.append(roundi(s.x * 1000.0))
		acc.append(roundi(s.y * 1000.0))
		acc.append(roundi(s.z * 1000.0))
		# The AABB alone cannot see SHAPE: the ruins are now generated meshes
		# whose breaks and jags can change completely while the bounding box
		# stays put, and the golden would bless that silently. Hash the actual
		# vertices (millimetre-quantised, like everything else here) so a
		# changed break is a reviewed act rather than an invisible one.
		for surface in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(surface)
			if arrays.size() > Mesh.ARRAY_VERTEX:
				var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				for v in verts:
					acc.append(roundi(v.x * 1000.0))
					acc.append(roundi(v.y * 1000.0))
					acc.append(roundi(v.z * 1000.0))
	for child in node.get_children():
		_fingerprint_subtree(child, acc)


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
