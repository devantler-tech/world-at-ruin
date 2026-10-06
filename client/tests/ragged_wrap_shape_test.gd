extends Node
## Measure the actual composed closed shell. Source coordinates select bands
## and paired panel faces; they never compute the acceptance dimensions.

const FLAG := "WAR_RAGGED_CLOTH_DRAPE"
var _failed := false


func _ready() -> void:
	var state := TestEnvironment.snapshot([FLAG, RaggedDrape.REFINEMENT_FLAG_ENV])
	OS.unset_environment(FLAG)
	OS.set_environment(RaggedDrape.REFINEMENT_FLAG_ENV, "1")
	var recipe: Dictionary = CharacterFactory.load_recipe("res://recipes/wanderer.json")
	var original: Dictionary = recipe.duplicate(true)
	var off := CharacterFactory.build(recipe)
	var source := _garment(off).mesh as ArrayMesh
	OS.set_environment(FLAG, "1")
	var on := CharacterFactory.build(recipe)
	var garment := _garment(on)
	var dimensions := _dimensions(source, garment.mesh as ArrayMesh)
	var control := _dimensions(source, source)
	print("WRAP SHAPE — band_mm=%.6f panel_mm=%.6f old_band_mm=%.6f old_panel_mm=%.6f" % [
		dimensions[0] * 1000.0, dimensions[1] * 1000.0, control[0] * 1000.0, control[1] * 1000.0])
	_check(dimensions[0] <= 0.026, "opt-in waist band is at most 26 mm high, rather than the original 52 mm board")
	_check(dimensions[1] <= 0.0031, "closed hanging panel shell is at most 3 mm thick")
	_check(control[0] > 0.05 and control[1] > 0.007, "unchanged imported geometry fails both shape criteria")
	_check(_closed(garment.mesh as ArrayMesh), "refinement retains a closed opaque manifold at every seam")
	_check(_closed(source), "the manifold oracle also recognizes the imported closed shell")
	var broken := ArrayMesh.new()
	var arrays := garment.mesh.surface_get_arrays(0)
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	indices.resize(indices.size() - 3)
	arrays[Mesh.ARRAY_INDEX] = indices
	broken.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, garment.mesh.surface_get_format(0) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS)
	_check(not _closed(broken), "a deliberately removed face cannot pass the closure oracle")
	_check(recipe == original, "shape refinement preserves every saved field")
	on.free()
	off.free()
	TestEnvironment.restore(state)
	if not _failed:
		print("TEST PASS — opted-in waist and panel dimensions, closed seams and discriminating old/open controls")
	get_tree().quit(1 if _failed else 0)


func _dimensions(source: ArrayMesh, changed: ArrayMesh) -> Vector2:
	var base: PackedVector3Array = source.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var points: PackedVector3Array = changed.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var low := INF
	var high := -INF
	var pairs := {}
	for i in base.size():
		var p := base[i]
		if absf(p.y - 0.888) < 0.000001 or absf(p.y - 0.940) < 0.000001:
			low = minf(low, points[i].y)
			high = maxf(high, points[i].y)
		else:
			var key := "%d:%d:%d" % [roundi(p.x * 1000000.0), roundi(p.y * 1000000.0), signi(roundi(p.z * 1000000.0))]
			if key not in pairs:
				pairs[key] = Vector2(points[i].z, points[i].z)
			var pair: Vector2 = pairs[key]
			pairs[key] = Vector2(minf(pair.x, points[i].z), maxf(pair.y, points[i].z))
	var thick := 0.0
	var measured := 0
	for pair: Vector2 in pairs.values():
		if pair.y - pair.x > 0.00001:
			thick = maxf(thick, pair.y - pair.x)
			measured += 1
	_check(measured >= 60 and is_finite(low) and is_finite(high), "dimension oracle measures both real panels and both waist rings")
	return Vector2(high - low, thick)


func _closed(mesh: ArrayMesh) -> bool:
	var arrays := mesh.surface_get_arrays(0)
	var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var edges := {}
	for i in range(0, indices.size(), 3):
		for j in 3:
			var a := _point_key(points[indices[i + j]])
			var b := _point_key(points[indices[i + (j + 1) % 3]])
			if a == b:
				return false
			var key := a + "/" + b if a < b else b + "/" + a
			edges[key] = int(edges.get(key, 0)) + 1
	for count: int in edges.values():
		if count != 2:
			return false
	return not edges.is_empty()


func _point_key(point: Vector3) -> String:
	return "%d,%d,%d" % [roundi(point.x * 100000.0), roundi(point.y * 100000.0), roundi(point.z * 100000.0)]


func _garment(character: Node3D) -> MeshInstance3D:
	return CharacterFactory.find_skeleton(character).get_node("Equip_loincloth_ragged") as MeshInstance3D


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error(message)
		print("TEST FAIL — " + message)
