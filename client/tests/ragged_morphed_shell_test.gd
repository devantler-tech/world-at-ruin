extends Node
## A closed mesh can still be inside out. Judge paired faces after the real
## compositor applies accepted saved morphs and the standing skeleton.

var _failed := false


func _ready() -> void:
	var state := TestEnvironment.snapshot([RaggedDrape.FLAG_ENV, RaggedDrape.REFINEMENT_FLAG_ENV])
	OS.set_environment(RaggedDrape.REFINEMENT_FLAG_ENV, "1")
	var oracle := load("res://tests/equipment_visibility_test.gd").new() as Node
	for case: Array in [[{"belly": -1.0}, false], [{"belly": -1.0, "buttocks_full": -1.0}, false],
			[{"belly": 2.0}, false], [{"hips_wide": 2.0}, false], [{"belly": -1.0}, true]]:
		var shapes: Dictionary = case[0]
		var recipe := {"version": 4, "shapes": shapes, "equipment": {}}
		var saved := recipe.duplicate(true)
		OS.unset_environment(RaggedDrape.FLAG_ENV)
		var off := CharacterFactory.build(recipe)
		add_child(off)
		var off_skeleton := CharacterFactory.find_skeleton(off)
		var off_piece := _piece(off_skeleton)
		var reference: PackedVector3Array = oracle.call("drawn", off_skeleton, off_piece)[0]
		OS.set_environment(RaggedDrape.FLAG_ENV, "1")
		var on := CharacterFactory.build({"version": 4, "equipment": {}} if case[1] else recipe)
		add_child(on)
		if case[1]:
			CharacterFactory.set_shape_weight(on, "belly", -1.0)
		var skeleton := CharacterFactory.find_skeleton(on)
		var garment := _piece(skeleton)
		var actual: PackedVector3Array = oracle.call("drawn", skeleton, garment)[0]
		var source: PackedVector3Array = off_piece.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var pairs := {}
		for i in source.size():
			var p := source[i]
			if absf(p.y - 0.888) < 0.000001 or absf(p.y - 0.940) < 0.000001:
				continue
			var key := "%d:%d:%d" % [roundi(p.x * 1000000.0), roundi(p.y * 1000000.0), signi(roundi(p.z * 1000000.0))]
			if key not in pairs:
				pairs[key] = Vector2i(i, i)
			var pair: Vector2i = pairs[key]
			if p.z < source[pair.x].z:
				pair.x = i
			if p.z > source[pair.y].z:
				pair.y = i
			pairs[key] = pair
		var minimum := INF
		var old_minimum := INF
		var count := 0
		for pair: Vector2i in pairs.values():
			if pair.x == pair.y:
				continue
			var previous := reference[pair.y] - reference[pair.x]
			var gap := (actual[pair.y] - actual[pair.x]).dot(previous.normalized())
			minimum = minf(minimum, gap)
			old_minimum = minf(old_minimum, previous.length())
			count += 1
		print("MORPHED SHELL — shapes=%s pairs=%d signed_minimum_mm=%.6f source_minimum_mm=%.6f" % [
			JSON.stringify(shapes), count, minimum * 1000.0, old_minimum * 1000.0])
		_check(count == 70 and old_minimum > 0.003, "oracle exercises both original, correctly ordered closed panels")
		_check(minimum > 0.0005, "valid saved body shapes must never cross the refined inner and outer cloth faces")
		_check(recipe == saved, "safe thinning never clamps, rejects or rewrites an accepted saved shape")
		on.free()
		off.free()
	oracle.free()
	TestEnvironment.restore(state)
	if not _failed:
		print("TEST PASS — actual saved-morph/skinned cloth keeps positively ordered panel faces")
	get_tree().quit(1 if _failed else 0)


func _piece(skeleton: Skeleton3D) -> MeshInstance3D:
	return skeleton.get_node("Equip_loincloth_ragged") as MeshInstance3D


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error(message)
		print("TEST FAIL — " + message)
