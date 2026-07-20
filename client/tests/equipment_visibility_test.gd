extends Node
## Regression guard for #250: an equipped garment must actually CONTRIBUTE to
## the rendered frame.
##
## #250 was filed as "the ragged shirt does not render". It does — but the
## suite could not have told the difference, because every equipment assertion
## we had stops at "the mesh node exists, carries the kit shapes and takes the
## recipe's weights". A garment can satisfy all of that and still be invisible,
## in two independent ways:
##
##   1. GEOMETRY — it sits inside the body surface, so the skin draws over it.
##   2. COLOUR   — its albedo matches the skin it covers, so it reads as bare.
##
## Both are measured on the CPU against the same morphed, skinned geometry the
## renderer draws, so this runs on CI's software renderer, where a real frame
## capture cannot (#232). It is a FLOOR against "contributes nothing", not an
## art-quality gate: the taste call on how a garment should read is #1's.
##
## Run: godot --headless --path client res://tests/equipment_visibility_test.tscn

const WANDERER := "res://recipes/wanderer.json"
const SKINS_DIR := "res://assets/characters/humanoid_kit/skins/"
## Spatial-hash cell for the nearest-body-vertex query. Comfortably larger
## than the clearances being measured, so a 3x3x3 neighbourhood is complete.
const CELL := 0.04
## A garment vertex counts as CONTRIBUTING when it sits at least this far
## outside the nearest body vertex, measured outward from the body's vertical
## axis. Below a tenth of a millimetre the two surfaces are coincident and the
## renderer picks a winner by depth-fighting, not by intent.
const CONTRIBUTING_MM := 0.1
## Measured on the shipped kit (2026-07-20): shirt_ragged 80.7% of vertices
## contributing, pants_wool 72.9%, shoes_cloth 54.2%. The floor sits under the
## worst shipped piece with margin, and well over a buried one — the controls
## below score 0.0% (coincident) and 7.6% (sunk 50mm).
const MIN_CONTRIBUTING := 0.40
## Largest single-channel albedo difference from the skin the garment covers.
## Measured: shirt_ragged 0.283, pants_wool 0.483, shoes_cloth 0.533. A
## luma-only comparison is blind to hue, so this is deliberately per-channel.
const MIN_CHROMA := 0.12

var _failed := false


func _fail(msg: String) -> void:
	_failed = true
	printerr("FAIL: " + msg)


func _morphed(mi: MeshInstance3D) -> PackedVector3Array:
	var mesh := mi.mesh
	var base: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var mixed := PackedVector3Array(base)
	var blends := mesh.surface_get_blend_shape_arrays(0)
	var normalized: bool = mesh is ArrayMesh \
		and (mesh as ArrayMesh).blend_shape_mode == Mesh.BLEND_SHAPE_MODE_NORMALIZED
	for si in mesh.get_blend_shape_count():
		var w := mi.get_blend_shape_value(si)
		if is_zero_approx(w):
			continue
		var targets: PackedVector3Array = blends[si][Mesh.ARRAY_VERTEX]
		for v in mixed.size():
			var delta := targets[v] - base[v] if normalized else targets[v]
			mixed[v] += delta * w
	return mixed


func _cell_of(p: Vector3) -> Vector3i:
	return Vector3i(int(floor(p.x / CELL)), int(floor(p.y / CELL)), int(floor(p.z / CELL)))


func _hash(verts: PackedVector3Array) -> Dictionary:
	var grid := {}
	for i in verts.size():
		var key := _cell_of(verts[i])
		if not grid.has(key):
			grid[key] = PackedInt32Array()
		grid[key].append(i)
	return grid


func _nearest(grid: Dictionary, verts: PackedVector3Array, p: Vector3) -> int:
	var centre := _cell_of(p)
	for r in range(1, 6):
		var best := -1
		var best_d := INF
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				for dz in range(-r, r + 1):
					var key := centre + Vector3i(dx, dy, dz)
					if not grid.has(key):
						continue
					for i: int in grid[key]:
						var d := verts[i].distance_squared_to(p)
						if d < best_d:
							best_d = d
							best = i
		if best >= 0:
			return best
	return -1


## THE MEASUREMENT, isolated so the negative controls below can feed it
## ablated inputs: what fraction of this garment's surface sits outside the
## body, and therefore can be drawn at all?
func contributing_fraction(garment: PackedVector3Array, body_grid: Dictionary,
		body: PackedVector3Array) -> float:
	var outside := 0
	var total := 0
	for gi in garment.size():
		var gp := garment[gi]
		var bi := _nearest(body_grid, body, gp)
		if bi < 0:
			continue
		var bp := body[bi]
		var outward := Vector3(bp.x, 0.0, bp.z)
		if outward.length() < 1e-5:
			continue
		if (gp - bp).dot(outward.normalized()) > CONTRIBUTING_MM * 0.001:
			outside += 1
		total += 1
	return 0.0 if total == 0 else float(outside) / float(total)


## Largest single-channel separation between a garment albedo and the skin it
## covers. Hue-aware on purpose: recolouring a whole surface can leave luma
## untouched, so a luma metric would report a confident zero.
func chroma_separation(garment: Color, skin: Color) -> float:
	return maxf(maxf(absf(garment.r - skin.r), absf(garment.g - skin.g)),
		absf(garment.b - skin.b))


func _skin_mean(texture_path: String) -> Color:
	var tex: Texture2D = load(texture_path)
	if tex == null:
		return Color(0, 0, 0, 0)
	var img := tex.get_image()
	if img == null:
		return Color(0, 0, 0, 0)
	if img.is_compressed():
		img.decompress()
	var acc := Vector3.ZERO
	var n := 0
	for y in range(0, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			var c := img.get_pixel(x, y)
			if c.a < 0.5:
				continue
			acc += Vector3(c.r, c.g, c.b)
			n += 1
	if n == 0:
		return Color(0, 0, 0, 0)
	return Color(acc.x / n, acc.y / n, acc.z / n, 1.0)


func _ready() -> void:
	var recipe: Dictionary = CharacterFactory.load_recipe(WANDERER)
	if recipe == null or not recipe.has("equipment"):
		_fail("the wanderer preset is unreadable or lost its equipment")
		_done()
		return
	var instance := CharacterFactory.build(recipe)
	if instance == null:
		_fail("the wanderer preset no longer builds")
		_done()
		return
	var skeleton := CharacterFactory.find_skeleton(instance)
	var body_mesh := CharacterFactory.find_skinned_mesh(skeleton)
	if body_mesh == null:
		_fail("no body mesh on the built wanderer")
		_done()
		return
	var body := _morphed(body_mesh)
	var body_grid := _hash(body)

	var skins: Dictionary = CharacterFactory.skins_registry()["skins"]
	var skin_name := String(recipe.get("skin", ""))
	if skin_name not in skins:
		_fail("the wanderer's skin '%s' is not in the skins registry" % skin_name)
		_done()
		return
	var skin := _skin_mean(SKINS_DIR + String(skins[skin_name]["texture"]))
	if skin.a == 0.0:
		_fail("skin texture for '%s' is unreadable — the colour floor cannot be measured" % skin_name)
		_done()
		return

	# 1+2. Every garment the shipped preset wears must contribute geometry the
	#      renderer can draw, in a colour that separates it from bare skin.
	var checked := 0
	var worn := CharacterFactory.pieces_to_wear(recipe["equipment"])
	for piece_name in worn:
		var mi := skeleton.get_node_or_null(
			NodePath(CharacterFactory.EQUIP_PREFIX + piece_name)) as MeshInstance3D
		if mi == null:
			_fail("worn piece '%s' built no mesh on the skeleton" % piece_name)
			continue
		var garment := _morphed(mi)
		if garment.is_empty():
			_fail("worn piece '%s' has no vertices" % piece_name)
			continue
		var fraction := contributing_fraction(garment, body_grid, body)
		if fraction < MIN_CONTRIBUTING:
			_fail(("piece '%s' CONTRIBUTES NOTHING: only %.1f%% of its surface sits outside "
				+ "the body (floor %.0f%%) — it is buried in the skin and cannot render")
				% [piece_name, fraction * 100.0, MIN_CONTRIBUTING * 100.0])
		var material := mi.get_active_material(0) as StandardMaterial3D
		if material == null:
			_fail("piece '%s' has no StandardMaterial3D — nothing defines its colour" % piece_name)
			continue
		var separation := chroma_separation(material.albedo_color, skin)
		if separation < MIN_CHROMA:
			_fail(("piece '%s' READS AS BARE: its albedo is within %.3f of the skin it covers "
				+ "on every channel (floor %.3f)") % [piece_name, separation, MIN_CHROMA])
		print("  %-13s contributing=%5.1f%%  chroma_vs_skin=%.3f" \
			% [piece_name, fraction * 100.0, separation])
		checked += 1

	if checked == 0:
		_fail("NON-VACUITY: the wanderer wore no garments, so nothing was measured")

	# 3. NEGATIVE CONTROL (geometry): the body's own surface, offered as a
	#    garment, is coincident with itself — the definition of contributing
	#    nothing. If this passes, the geometry floor is not load-bearing.
	var buried := contributing_fraction(body, body_grid, body)
	if buried >= MIN_CONTRIBUTING:
		_fail(("CONTROL FAILED: a surface coincident with the body scored %.1f%% contributing, "
			+ "at or above the %.0f%% floor — the geometry check cannot detect a buried garment")
			% [buried * 100.0, MIN_CONTRIBUTING * 100.0])
	else:
		print("  control(buried geometry)  contributing=%5.1f%% — correctly below the floor" \
			% [buried * 100.0])

	# 4. NEGATIVE CONTROL (geometry, second form): take a real garment and pull
	#    it inside the skin. This ablates ONLY the clearance, keeping vertex
	#    count, morphs and skinning intact — so a pass here would mean the
	#    floor is measuring something other than clearance.
	if not worn.is_empty():
		var sample := skeleton.get_node_or_null(
			NodePath(CharacterFactory.EQUIP_PREFIX + worn[0])) as MeshInstance3D
		if sample != null:
			var sunk := _morphed(sample)
			for i in sunk.size():
				var radial := Vector3(sunk[i].x, 0.0, sunk[i].z)
				if radial.length() > 1e-5:
					sunk[i] -= radial.normalized() * 0.05
			var sunk_fraction := contributing_fraction(sunk, body_grid, body)
			if sunk_fraction >= MIN_CONTRIBUTING:
				_fail(("CONTROL FAILED: '%s' sunk 50mm into the body still scored %.1f%% "
					+ "contributing") % [worn[0], sunk_fraction * 100.0])
			else:
				print("  control(sunk 50mm)        contributing=%5.1f%% — correctly below the floor" \
					% [sunk_fraction * 100.0])

	# 5. NEGATIVE CONTROL (colour): a garment painted the colour of the skin it
	#    covers separates by zero and must fail the colour floor.
	var camouflaged := chroma_separation(skin, skin)
	if camouflaged >= MIN_CHROMA:
		_fail(("CONTROL FAILED: a garment painted exactly the skin colour separated by %.3f, "
			+ "at or above the %.3f floor") % [camouflaged, MIN_CHROMA])
	else:
		print("  control(skin-coloured)    chroma=%.3f — correctly below the floor" % camouflaged)

	# 6. NEGATIVE CONTROL (colour, hue-only): a garment differing from the skin
	#    only in HUE, at matched luma, must still pass. This is what pins the
	#    metric as per-channel rather than luma — the check that would have
	#    handed every recolour a confident zero.
	var hue_shifted := Color(skin.b, skin.r, skin.g)
	var hue_sep := chroma_separation(hue_shifted, skin)
	if hue_sep < MIN_CHROMA:
		_fail(("CONTROL FAILED: a hue-swapped garment separated by only %.3f — the colour "
			+ "metric is blind to hue") % hue_sep)
	else:
		print("  control(hue-swapped)      chroma=%.3f — correctly above the floor" % hue_sep)

	instance.free()
	_done()


func _done() -> void:
	if _failed:
		printerr("TEST FAIL")
	else:
		print("TEST PASS")
	get_tree().quit()
