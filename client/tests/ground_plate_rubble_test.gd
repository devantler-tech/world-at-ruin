extends Node
## The real world owns the batch, while its original terrain/cover remain intact.

const NODE := "GroundPlateRubble"
const MAX_PLACEMENTS := 1152


func _ready() -> void:
	OS.unset_environment("WAR_GROUND_PLATES")
	var world := WorldGen.new()
	add_child(world)
	var baseline := world.foliage_placements()
	var terrain := _terrain_fingerprint(world)
	if world.get_node_or_null(NODE) != null:
		_fail("default-off world built slab rubble")
		return
	OS.set_environment("WAR_GROUND_PLATES", "true")
	var malformed := WorldGen.new()
	add_child(malformed)
	OS.unset_environment("WAR_GROUND_PLATES")
	if malformed.get_node_or_null(NODE) != null \
			or malformed.get_node_or_null(WorldGen.GROUND_PLATES_NODE) != null:
		_fail("a malformed opt-in value built plates or rubble")
		return
	world.set_ground_plates_enabled(true)
	var batch := world.get_node_or_null(NODE) as MultiMeshInstance3D
	if batch == null:
		_fail("opted-in built slabs have no edge-derived rubble batch")
		return
	if world.get(&"ground_plate_rubble") is not Dictionary:
		_fail("the real batch has no inspectable source/placement records")
		return
	var records: Dictionary = world.get(&"ground_plate_rubble")
	var placements: Array = records[&"placements"]
	var aprons: Array = records[&"aprons"]
	if placements.is_empty() or placements.size() > MAX_PLACEMENTS \
			or batch.multimesh.instance_count != placements.size() or aprons.is_empty():
		_fail("the world batch is empty, exceeds the bound or disagrees with its placement inventory")
		return
	var mesh := batch.multimesh.mesh as ArrayMesh
	if mesh == null or mesh.get_surface_count() != 1 \
			or batch.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF \
			or batch.material_override == null:
		_fail("cosmetic rubble exceeds one opaque unshadowed surface/batch")
		return
	if not batch.get_children().is_empty():
		_fail("cosmetic rubble gained a child or collision surface")
		return
	var radius := ExposedSlabRubble.mesh_radius(mesh)
	var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for vertex: Vector3 in vertices:
		if Vector2(vertex.x, vertex.z).length() > radius + 0.000001:
			_fail("the clearance radius does not enclose the actual rendered cluster mesh")
			return
	var plate_mesh := _plate_fingerprint(world)
	var visible := world.visible_foliage_placements
	var tops := world.ground_plate_tops()
	for apron: Dictionary in aprons:
		if not _graded_apron(apron, placements):
			_fail("a real apron lost all larger lip chips or its outward grade into finer grit")
			return
		var source_found := false
		for top: Dictionary in tops:
			if top.get(&"identity") != apron[&"identity"]:
				continue
			var polygon: PackedVector2Array = top[&"polygon"]
			var edge := int(apron[&"edge_index"])
			var ash: PackedFloat32Array = top[&"edge_ash"]
			if polygon[edge] != apron[&"a"] \
					or polygon[(edge + 1) % polygon.size()] != apron[&"b"] \
					or ash[edge] < 0.5:
				_fail("a rendered apron has no actual ash-facing fracture edge")
				return
			source_found = true
			break
		if not source_found:
			_fail("rubble derives from an unbuilt or unrelated slab")
			return
	for placement: Dictionary in placements:
		var pos: Vector3 = placement["pos"]
		if world.ground_plate_at(pos.x, pos.z) >= 0 \
				or absf(pos.y - world.surface_height_at(pos.x, pos.z)) > 0.00001:
			_fail("a cluster instance roots inside an intact top or misses the actual terrain")
			return
		var at := Vector2(pos.x, pos.z)
		var footprint := radius * float(placement["scale"])
		if not _whole_footprint_clear(world, tops, at, footprint):
			_fail("a rendered cluster footprint partially intersects a raised slab or protected circle")
			return
		if Vector2(pos.x, pos.z).length() < WorldGen.SHRINE_CLEAR_RADIUS + 2.0 \
				or world.cave_protects(pos.x, pos.z):
			_fail("a cluster instance intrudes on a protected shrine or cave approach")
			return
	var doorway: Array = world.get("_cave_apron")
	if not doorway.is_empty():
		for placement: Dictionary in placements:
			var pos: Vector3 = placement["pos"]
			var footprint := radius * float(placement["scale"])
			if Vector2(pos.x, pos.z).distance_to(doorway[0]) <= float(doorway[1]) + footprint:
				_fail("a cluster instance intrudes on the real doorway's walk-out apron")
				return
	OS.set_environment("WAR_GROUND_PLATES", "1")
	var fresh := WorldGen.new()
	add_child(fresh)
	OS.unset_environment("WAR_GROUND_PLATES")
	if fresh.get(&"ground_plate_rubble") != records:
		_fail("a fresh opted-in boot differs from lazy activation")
		return
	for _toggle in 3:
		world.set_ground_plates_enabled(false)
		if batch.visible or world.foliage_placements() != baseline \
				or world.visible_foliage_placements != baseline \
				or _terrain_fingerprint(world) != terrain:
			_fail("opt-out left rubble visible or changed baseline terrain/cover")
			return
		world.set_ground_plates_enabled(true)
		if world.get_node(NODE) != batch or not batch.visible \
				or world.get(&"ground_plate_rubble") != records \
				or world.visible_foliage_placements != visible \
				or _plate_fingerprint(world) != plate_mesh:
			_fail("repeated preview changed source geometry, original instances or visible cover")
			return
	var copied: Array = (world.get(&"ground_plate_rubble") as Dictionary)[&"placements"]
	(copied[0] as Dictionary)["pos"] = Vector3.INF
	if world.get(&"ground_plate_rubble") != records:
		_fail("a caller changed the world's original rubble placements")
		return
	if _terrain_fingerprint(world) != terrain or world.foliage_placements() != baseline:
		_fail("the cosmetic preview changed the baseline world")
		return
	print("TEST PASS: real slab rubble — %d cluster instances from %d graded ash-facing aprons in one batch; exact footprints clear, fresh/live converge, opt-out restores terrain/foliage" % [placements.size(), aprons.size()])
	get_tree().quit(0)


func _graded_apron(apron: Dictionary, placements: Array) -> bool:
	var chips := 0
	var grit := 0
	var far_chip := 0.0
	var near_grit := INF
	var start := int(apron[&"placement_start"])
	var count := int(apron[&"placement_count"])
	if count < 4 or count > 6 or start < 0 or start + count > placements.size():
		return false
	for i in range(start, start + count):
		var item: Dictionary = placements[i]
		var pos: Vector3 = item["pos"]
		var distance := (Vector2(pos.x, pos.z) - (apron[&"a"] as Vector2)).dot(apron[&"outward"])
		var scale := float(item["scale"])
		if scale >= 0.58 and scale <= 0.82:
			chips += 1
			far_chip = maxf(far_chip, distance)
		elif scale >= 0.16 and scale <= 0.28:
			grit += 1
			near_grit = minf(near_grit, distance)
		else:
			return false
	return chips >= 1 and grit >= 2 and far_chip < near_grit


func _whole_footprint_clear(world: WorldGen, tops: Array,
		at: Vector2, radius: float) -> bool:
	# Independently check exact segment distances. This test may scan its
	# inventory; production must use the bounded existing cell index.
	for top: Dictionary in tops:
		var polygon: PackedVector2Array = top[&"polygon"]
		if Geometry2D.is_point_in_polygon(at, polygon):
			return false
		for i in polygon.size():
			var nearest := Geometry2D.get_closest_point_to_segment(
				at, polygon[i], polygon[(i + 1) % polygon.size()])
			if at.distance_to(nearest) <= radius:
				return false
	var circles: Array = world.call("_foliage_keep_outs")
	for circle: Array in circles:
		if at.distance_to(circle[0]) <= float(circle[1]) + radius:
			return false
	return true


func _terrain_fingerprint(world: WorldGen) -> int:
	var mesh := (world.get_node("Terrain") as MeshInstance3D).mesh
	var shape := (world.get_node("TerrainBody").get_child(0) as CollisionShape3D).shape as ConcavePolygonShape3D
	return hash([mesh.surface_get_arrays(0), shape.get_faces()])


func _plate_fingerprint(world: WorldGen) -> int:
	var mesh := (world.get_node(WorldGen.GROUND_PLATES_NODE) as MeshInstance3D).mesh
	var shape := (world.get_node(WorldGen.GROUND_PLATES_BODY).get_child(0) as CollisionShape3D).shape as ConcavePolygonShape3D
	return hash([mesh.surface_get_arrays(0), shape.get_faces()])


func _fail(message: String) -> void:
	print("TEST FAIL: " + message)
	get_tree().quit(1)
