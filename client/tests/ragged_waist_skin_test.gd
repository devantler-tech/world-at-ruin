extends Node
## Narrowing the band must reveal intact skin, not the old equipment inset.
## Compare actual morphed/skinned vertices to an independently untucked body.

var _failed := false


func _ready() -> void:
	var state := TestEnvironment.snapshot([RaggedDrape.FLAG_ENV, RaggedDrape.REFINEMENT_FLAG_ENV])
	OS.set_environment(RaggedDrape.REFINEMENT_FLAG_ENV, "1")
	var oracle := load("res://tests/equipment_visibility_test.gd").new() as Node
	var recipes := [
		CharacterFactory.load_recipe("res://recipes/wanderer.json"),
		CharacterFactory.load_recipe("res://recipes/villager.json"),
		CharacterFactory.load_recipe("res://recipes/elder.json"),
		CharacterFactory.load_recipe("res://recipes/brute.json"),
		{"version": 1, "shapes": {"hips_wide": 2.01, "torso_vshape": -0.1}},
		{"version": 2, "equipment": {}},
		{"version": 3, "shapes": {"hips_wide": 0.8}},
		{"version": 4, "equipment": {}},
	]
	for recipe: Dictionary in recipes:
		var saved := recipe.duplicate(true)
		OS.unset_environment(RaggedDrape.FLAG_ENV)
		var off := CharacterFactory.build(recipe)
		add_child(off)
		var off_skeleton := CharacterFactory.find_skeleton(off)
		var off_body := CharacterFactory.find_skinned_mesh(off_skeleton)
		var hide := off_body.find_blend_shape_by_name("equip_hide_loincloth_ragged")
		_check(hide >= 0, "reference body has the actual ragged inset shape")
		var old_drawn: PackedVector3Array = oracle.call("drawn", off_skeleton, off_body)[0]
		off_body.set_blend_shape_value(hide, 0.0)
		var reference: PackedVector3Array = oracle.call("drawn", off_skeleton, off_body)[0]
		OS.set_environment(RaggedDrape.FLAG_ENV, "1")
		var on := CharacterFactory.build(recipe)
		add_child(on)
		var skeleton := CharacterFactory.find_skeleton(on)
		var body := CharacterFactory.find_skinned_mesh(skeleton)
		var actual: PackedVector3Array = oracle.call("drawn", skeleton, body)[0]
		var base: PackedVector3Array = off_body.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var exposed := 0
		var dented := 0
		var worst := 0.0
		for i in base.size():
			if base[i].y >= 0.915 and base[i].y <= 0.944 and old_drawn[i].distance_to(reference[i]) > 0.003:
				exposed += 1
				worst = maxf(worst, actual[i].distance_to(reference[i]))
				if old_drawn[i].distance_to(reference[i]) > 0.006:
					dented += 1
		print("EXPOSED WAIST — version=%d samples=%d largest_dent_mm=%.6f old_dented=%d" % [
			int(recipe.get("version", 1)), exposed, worst * 1000.0, dented])
		_check(exposed > 20 and dented > 20, "the skin oracle exercises the real formerly covered upper waist")
		_check(worst < 0.00001, "newly exposed skin matches the intact drawn body instead of retaining a 12 mm equipment dent")
		_check(body.mesh != off_body.mesh, "skin restoration is private to the opted-in character")
		_check(recipe == saved, "restoring exposed skin preserves all historical recipe fields")
		on.free()
		off.free()
	oracle.free()
	TestEnvironment.restore(state)
	if not _failed:
		print("TEST PASS — narrowed waist reveals intact morphed/skinned skin for presets and historical recipes")
	get_tree().quit(1 if _failed else 0)


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error(message)
		print("TEST FAIL — " + message)
