extends Node
## The real compositor must opt into isolated geometry without losing saved
## morphs, skin bindings, material independence or the permanent base.

const FLAG := "WAR_RAGGED_CLOTH_DRAPE"
const MATERIAL_FLAG := "WAR_RAGGED_CLOTH_DETAIL"
var _failed := false


func _ready() -> void:
	var old_flags := {}
	for flag: String in [FLAG, MATERIAL_FLAG]:
		old_flags[flag] = [OS.has_environment(flag), OS.get_environment(flag)]
		OS.unset_environment(flag)
	var recipe: Dictionary = CharacterFactory.load_recipe("res://recipes/wanderer.json")
	var original := recipe.duplicate(true)
	var off := CharacterFactory.build(recipe)
	var source := _piece(off).mesh as ArrayMesh
	var before: Array = source.surface_get_arrays(0)
	OS.set_environment(FLAG, "1")
	var on := CharacterFactory.build(recipe)
	var garment := _piece(on)
	_check(garment.mesh != source, "opt-in must change the actual equipped mesh without mutating the shared asset")
	var changed := garment.mesh.surface_get_arrays(0)
	_check(changed[Mesh.ARRAY_VERTEX] != before[Mesh.ARRAY_VERTEX], "geometric folds must move actual vertices")
	_check(garment.skin == _piece(off).skin, "geometry keeps the exact skin binding")
	_check(garment.get_active_material(0) == _piece(off).get_active_material(0), "geometry and material previews are independent")
	for slot: int in [Mesh.ARRAY_INDEX, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS]:
		_check(changed[slot] == before[slot], "geometry preserves topology, UVs and skin arrays")
	_check(garment.mesh.get_blend_shape_count() == source.get_blend_shape_count(), "no historical morph is removed")
	for shape in source.get_blend_shape_count():
		_check(garment.mesh.get_blend_shape_name(shape) == source.get_blend_shape_name(shape), "morph names and ordering stay compatible")
		var old_targets: PackedVector3Array = source.surface_get_blend_shape_arrays(0)[shape][Mesh.ARRAY_VERTEX]
		var new_targets: PackedVector3Array = garment.mesh.surface_get_blend_shape_arrays(0)[shape][Mesh.ARRAY_VERTEX]
		for vertex in old_targets.size():
			var old_delta: Vector3 = old_targets[vertex] - before[Mesh.ARRAY_VERTEX][vertex]
			var new_delta: Vector3 = new_targets[vertex] - changed[Mesh.ARRAY_VERTEX][vertex]
			_check(old_delta.distance_to(new_delta) < 0.000001, "every saved morph retains its original positional delta")
	var moved := 0
	for vertex in before[Mesh.ARRAY_VERTEX].size():
		var a: Vector3 = before[Mesh.ARRAY_VERTEX][vertex]
		var b: Vector3 = changed[Mesh.ARRAY_VERTEX][vertex]
		if a.y >= 0.888:
			_check(a == b, "the closed waist belt stays pinned")
		else:
			moved += 1
			_check(absf(b.x) >= absf(a.x) and absf(b.z) >= absf(a.z), "the draped panel never narrows opaque coverage")
	_check(moved > 100, "folds affect the hanging panels rather than a token vertex")
	for normal: Vector3 in changed[Mesh.ARRAY_NORMAL]:
		_check(normal.is_finite() and absf(normal.length() - 1.0) < 0.001, "deformed lighting normals remain finite and unit length")
	var another := CharacterFactory.build(recipe)
	_check(_piece(another).mesh != garment.mesh, "each character owns its derived mesh")
	_check(source.surface_get_arrays(0) == before, "the imported resource remains byte-identical")
	OS.set_environment(FLAG, "true")
	var malformed := CharacterFactory.build(recipe)
	_check(_piece(malformed).mesh == source, "only the exact explicit value 1 opts in")
	OS.unset_environment(FLAG)
	var after := CharacterFactory.build(recipe)
	_check(_piece(after).mesh == source and recipe == original, "opting out restores the source and never rewrites recipes")
	for character: Node3D in [off, on, another, malformed, after]:
		character.free()
	_historical()
	for flag: String in old_flags:
		if old_flags[flag][0]:
			OS.set_environment(flag, old_flags[flag][1])
		else:
			OS.unset_environment(flag)
	if not _failed:
		print("TEST PASS — cloth drape preserves private mesh, historical recipes and CPU skinning in every flag state")
		get_tree().quit(0)


func _historical() -> void:
	for recipe: Dictionary in [
		{"version": 1, "shapes": {"hips_wide": CharacterFactory.SHAPE_WEIGHT_MAX + 0.01, "torso_vshape": -0.1}},
		{"version": 2, "equipment": {"torso": "shirt_ragged"}},
		{"version": 3, "skin": "skin_male_light", "shapes": {"hips_wide": 0.8}},
		{"version": 4, "equipment": {"feet": ["shoes_cloth", "boots_worn"]}},
	]:
		var stored := recipe.duplicate(true)
		for drape: String in ["0", "1"]:
			for detail: String in ["0", "1"]:
				OS.set_environment(FLAG, drape)
				OS.set_environment(MATERIAL_FLAG, detail)
				var character := CharacterFactory.build(recipe)
				_check(character != null, "all historical formats build in all four flag combinations")
				if character == null:
					continue
				add_child(character)
				var skeleton := CharacterFactory.find_skeleton(character)
				var garment := _piece(character)
				var oracle := load("res://tests/equipment_visibility_test.gd").new() as Node
				var vertices: PackedVector3Array = oracle.call("drawn", skeleton, garment)[0]
				oracle.free()
				_check(vertices.size() == garment.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size(), "the entire deformed garment reaches CPU skinning")
				for point: Vector3 in vertices:
					_check(point.is_finite(), "historical deformation keeps finite skinned positions")
				_check((garment.get_surface_override_material(0) != null) == (detail == "1"), "material selection is independent of geometry")
				_check(recipe == stored and CharacterFactory.refusal_reason(recipe) == "", "saved recipe fields and values are preserved")
				character.free()


func _piece(character: Node3D) -> MeshInstance3D:
	return CharacterFactory.find_skeleton(character).get_node("Equip_loincloth_ragged") as MeshInstance3D


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error(message)
		print("TEST FAIL — " + message)
		get_tree().quit(1)
