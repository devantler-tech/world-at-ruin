extends Node
## Catch skin breaking through the exterior rear panel, including triangle
## interiors. Imported/rest coordinates are not the drawn character: apply
## saved morphs before the actual standing skeleton through the shared oracle.

const FLAG := "WAR_RAGGED_CLOTH_DRAPE"
const MIN_CLEARANCE := 0.0001
var _failed := false


func _ready() -> void:
	var had_flag := OS.has_environment(FLAG)
	var old_flag := OS.get_environment(FLAG)
	OS.set_environment(FLAG, "1")
	var oracle := load("res://tests/equipment_visibility_test.gd").new() as Node
	_controls()
	var cases := {}
	for name: String in ["wanderer", "villager", "elder", "brute"]:
		var recipe: Dictionary = CharacterFactory.load_recipe("res://recipes/" + name + ".json")
		recipe["equipment"] = {}
		cases[name] = recipe
	cases["v1-wide"] = {"version": 1, "shapes": {"hips_wide": 2.01, "torso_vshape": -0.1}}
	cases["v2"] = {"version": 2, "equipment": {}}
	cases["v3-wide"] = {"version": 3, "shapes": {"hips_wide": 0.8}}
	cases["v4"] = {"version": 4, "equipment": {}}
	for name: String in cases:
		var saved: Dictionary = cases[name].duplicate(true)
		var character := CharacterFactory.build(cases[name])
		_check(character != null, "%s builds through the actual compositor" % name)
		if character == null:
			continue
		add_child(character)
		character.get_node("BreathingIdle").set_process(false)
		var skeleton := CharacterFactory.find_skeleton(character)
		skeleton.force_update_all_bone_transforms()
		var body := CharacterFactory.find_skinned_mesh(skeleton)
		var garment := skeleton.get_node("Equip_loincloth_ragged") as MeshInstance3D
		var body_positions: PackedVector3Array = oracle.call("drawn", skeleton, body)[0]
		var body_indices: PackedInt32Array = body.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
		var triangles := _rear_triangles(body_positions, body_indices)
		var samples := _outer_samples(garment, oracle.call("drawn", skeleton, garment)[0])
		_check(samples.size() > 100 and not triangles.is_empty(), "%s has real exterior panel and body samples" % name)
		var minimum := INF
		var buried := INF
		for point: Vector3 in samples:
			var clearance := _rear_clearance(point, triangles)
			_check(is_finite(clearance), "%s every cloth sample intersects the real body projection" % name)
			minimum = minf(minimum, clearance)
			buried = minf(buried, _rear_clearance(point + Vector3(0.0, 0.0, 0.02), triangles))
		print("REAR COVERAGE %s — samples=%d minimum_mm=%.6f buried_control_mm=%.6f" % [name, samples.size(), minimum * 1000.0, buried * 1000.0])
		_check(minimum >= MIN_CLEARANCE, "%s outer rear cloth must clear the drawn body, including triangle interiors" % name)
		_check(buried < -0.005, "%s a deliberately buried panel must fail the same oracle" % name)
		_check(cases[name] == saved, "%s coverage repair never mutates saved fields" % name)
		character.free()
	oracle.free()
	if had_flag:
		OS.set_environment(FLAG, old_flag)
	else:
		OS.unset_environment(FLAG)
	if not _failed:
		print("TEST PASS — opt-in rear wrap clears actual morphed/skinned bodies; buried and missing-body controls discriminate")
		get_tree().quit(0)
	else:
		get_tree().quit(1)


## Select outward faces by the untouched source's normals. The closed shell's
## inner thickness is deliberately excluded: it is not the visible coverage.
func _outer_samples(garment: MeshInstance3D, drawn: PackedVector3Array) -> PackedVector3Array:
	var source := garment.get_meta(RaggedDrape.SOURCE_META, garment.mesh) as ArrayMesh
	var arrays := source.surface_get_arrays(0)
	var base: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var samples := PackedVector3Array()
	for triangle in range(indices.size() / 3):
		var a := indices[triangle * 3]
		var b := indices[triangle * 3 + 1]
		var c := indices[triangle * 3 + 2]
		var centre := (base[a] + base[b] + base[c]) / 3.0
		var normal := (normals[a] + normals[b] + normals[c]).normalized()
		if centre.z > -0.04 or not _in_panel(centre) or normal.z > -0.6:
			continue
		for i in 7:
			for j in range(7 - i):
				var u := float(i) / 6.0
				var v := float(j) / 6.0
				if _in_panel(base[a] * (1.0 - u - v) + base[b] * u + base[c] * v):
					samples.append(drawn[a] * (1.0 - u - v) + drawn[b] * u + drawn[c] * v)
	return samples


func _in_panel(point: Vector3) -> bool:
	return point.y >= 0.84 and point.y <= 0.888 and absf(point.x) <= 0.06


func _rear_triangles(body: PackedVector3Array, indices: PackedInt32Array) -> Array:
	var triangles := []
	for triangle in range(indices.size() / 3):
		var a := body[indices[triangle * 3]]
		var b := body[indices[triangle * 3 + 1]]
		var c := body[indices[triangle * 3 + 2]]
		if minf(a.y, minf(b.y, c.y)) > 0.95 or maxf(a.y, maxf(b.y, c.y)) < 0.70 or minf(a.z, minf(b.z, c.z)) > 0.0:
			continue
		triangles.append([a, b, c])
	return triangles


## Independent orthographic ray oracle: intersect the actual body triangles
## in XY, then compare the nearest rear Z. No drape formula or source normal
## participates in the clearance verdict; a missing body produces INF.
func _rear_clearance(point: Vector3, triangles: Array) -> float:
	var rear := INF
	for triangle: Array in triangles:
		var a: Vector3 = triangle[0]
		var b: Vector3 = triangle[1]
		var c: Vector3 = triangle[2]
		if point.x < minf(a.x, minf(b.x, c.x)) or point.x > maxf(a.x, maxf(b.x, c.x)) or point.y < minf(a.y, minf(b.y, c.y)) or point.y > maxf(a.y, maxf(b.y, c.y)):
			continue
		var denominator := (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
		if absf(denominator) < 0.00000001:
			continue
		var u := ((b.y - c.y) * (point.x - c.x) + (c.x - b.x) * (point.y - c.y)) / denominator
		var v := ((c.y - a.y) * (point.x - c.x) + (a.x - c.x) * (point.y - c.y)) / denominator
		var w := 1.0 - u - v
		if u >= -0.000001 and v >= -0.000001 and w >= -0.000001:
			rear = minf(rear, a.z * u + b.z * v + c.z * w)
	return rear - point.z


func _controls() -> void:
	var triangles := [[Vector3(0.0, 0.0, -0.1), Vector3(0.1, 0.0, -0.1), Vector3(0.0, 0.1, -0.1)]]
	_check(absf(_rear_clearance(Vector3(0.025, 0.025, -0.12), triangles) - 0.02) < 0.000001, "hand-derived triangle interior is 20 mm clear")
	_check(absf(_rear_clearance(Vector3(0.025, 0.025, -0.08), triangles) + 0.02) < 0.000001, "the same interior is 20 mm buried")
	_check(not is_finite(_rear_clearance(Vector3(0.2, 0.2, -0.12), triangles)), "absent body coverage cannot pass")
	_check(not is_finite(_rear_clearance(Vector3.ZERO, [])), "empty geometry cannot pass")


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error(message)
		print("TEST FAIL — " + message)
