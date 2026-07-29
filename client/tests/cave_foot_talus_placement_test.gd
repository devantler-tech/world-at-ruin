extends Node
## Placement regression for #558: cave-foot talus must come from the cave
## contact surface, not from an unrelated world scatter.
##
## Run: godot --headless --path client res://tests/cave_foot_talus_placement_test.tscn

const TALUS_SCRIPT := "res://scripts/cave_foot_talus.gd"
const SEED := 42
const MAX_PLACEMENTS := 72
const MIN_PLACEMENTS := 8
const MIN_SEPARATION := 1.25
const CONTACT_REACH := 2.5
const MOUTH_BACK := 4.0
const MOUTH_HALF_WIDTH := 4.5
const CONTACT_QUANTUM := 1.0 / 255.0


func _ready() -> void:
	var script := load(TALUS_SCRIPT) as GDScript
	if script == null:
		_fail("the cave-foot placement library does not exist")
		return
	var generator: Object = script.new()
	if generator == null or not generator.has_method(&"placements"):
		_fail("the cave-foot placement library exposes no placements API")
		return

	var flat_ground := func(_x: float, _z: float) -> float:
		return 0.0
	var material := func(_x: float, _z: float) -> Dictionary:
		return {
			&"color": Color(0.30, 0.27, 0.23),
			&"roughness": 0.88,
			&"normal": Vector3.UP,
			&"height": 0.0,
		}
	var built := CaveSystemGen.build_geometry(SEED, flat_ground, material)
	var contact := built[&"terrain_contact_mesh"] as ArrayMesh
	var mouth: Vector3 = (built[&"layout"] as Dictionary)[&"mouth"]
	if contact == null:
		_fail("the real cave build supplied no terrain-contact mesh")
		return

	seed(0x5f3759df)
	var first: Array = generator.call(&"placements", contact, flat_ground, mouth, SEED)
	seed(0x1eb54a3d)
	var second: Array = generator.call(&"placements", contact, flat_ground, mouth, SEED)
	if _fingerprint(first) != _fingerprint(second):
		_fail("the same contact mesh and seed produced different talus")
		return
	if first.size() < MIN_PLACEMENTS or first.size() > MAX_PLACEMENTS:
		_fail("the contact mesh produced %d placements, outside %d..%d" %
			[first.size(), MIN_PLACEMENTS, MAX_PLACEMENTS])
		return
	if not FoliageGen.find_forbidden(first).is_empty():
		_fail("talus carries fields outside the cosmetic placement schema")
		return

	var contact_points := _contact_centroids(contact)
	if contact_points.is_empty():
		_fail("the contact-derived check has no source triangles")
		return
	for i in first.size():
		var placement := first[i] as Dictionary
		if int(placement[&"kind"]) != FoliageGen.Kind.RUBBLE:
			_fail("placement %d is not the existing rubble kind" % i)
			return
		var pos: Vector3 = placement[&"pos"]
		if not pos.is_finite() or absf(pos.y) > 0.0001:
			_fail("placement %d does not rest on the supplied flat ground: %s" % [i, pos])
			return
		if pos.x >= mouth.x - MOUTH_BACK and absf(pos.z - mouth.z) < MOUTH_HALF_WIDTH:
			_fail("placement %d intrudes on the cave mouth corridor at %s" % [i, pos])
			return
		var nearest := INF
		for source: Vector2 in contact_points:
			nearest = minf(nearest, source.distance_to(Vector2(pos.x, pos.z)))
		if nearest > CONTACT_REACH:
			_fail("placement %d sits %.3f m from the nearest contact triangle" % [i, nearest])
			return
		for j in range(i + 1, first.size()):
			var other: Vector3 = (first[j] as Dictionary)[&"pos"]
			var separation := Vector2(pos.x, pos.z).distance_to(Vector2(other.x, other.z))
			if separation < MIN_SEPARATION:
				_fail("placements %d and %d are %.3f m apart, below %.2f m" %
					[i, j, separation, MIN_SEPARATION])
				return

	var changed: Array = generator.call(&"placements", contact, flat_ground, mouth, SEED + 1)
	if _fingerprint(first) == _fingerprint(changed):
		_fail("changing the authored seed did not change the placement fingerprint")
		return
	var missing_mesh: Array = generator.call(
		&"placements", null, flat_ground, mouth, SEED)
	if not missing_mesh.is_empty():
		_fail("missing contact data produced %d placements instead of failing closed" %
			missing_mesh.size())
		return
	var missing_ground: Array = generator.call(
		&"placements", contact, Callable(), mouth, SEED)
	if not missing_ground.is_empty():
		_fail("a missing ground sampler produced %d placements instead of failing closed" %
			missing_ground.size())
		return

	print("TEST PASS: cave-foot talus placement — %d cosmetic stones, contact-derived, mouth-clear, %.2f m separated, deterministic %s" %
		[first.size(), MIN_SEPARATION, _fingerprint(first)])
	get_tree().quit(0)


func _contact_centroids(mesh: ArrayMesh) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	for tri in range(0, indices.size(), 3):
		var ia := indices[tri]
		var ib := indices[tri + 1]
		var ic := indices[tri + 2]
		if maxf(colors[ia].a, maxf(colors[ib].a, colors[ic].a)) < CONTACT_QUANTUM:
			continue
		var centre := (verts[ia] + verts[ib] + verts[ic]) / 3.0
		out.append(Vector2(centre.x, centre.z))
	return out


func _fingerprint(placements: Array) -> String:
	var acc := PackedInt32Array()
	acc.append(placements.size())
	for raw: Variant in placements:
		if raw is not Dictionary:
			acc.append(-1)
			continue
		var placement := raw as Dictionary
		acc.append(int(placement.get(&"kind", -1)))
		var pos: Vector3 = placement.get(&"pos", Vector3.INF)
		acc.append(roundi(pos.x * 1000.0))
		acc.append(roundi(pos.y * 1000.0))
		acc.append(roundi(pos.z * 1000.0))
		acc.append(roundi(float(placement.get(&"yaw", 0.0)) * 10000.0))
		acc.append(roundi(float(placement.get(&"scale", 0.0)) * 1000.0))
	return "%x" % hash(acc)


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL: cave-foot talus placement — %s" % message)
	get_tree().quit(1)
