extends Node
## Production-writer vocabulary contract (#295).
##
## Reader registries may expand before the retained reader bakes. Character
## creation must keep those future names out of new saves until the explicit
## writer allowlist activates them with a save-capability advance.

var _failed := false


func _ready() -> void:
	var vocabulary := CharacterCreator.writer_vocabulary()
	_check(not vocabulary.is_empty(), "writer vocabulary loads")

	var equipment: Dictionary = vocabulary.get("equipment", {})
	var registry := CharacterFactory.equipment_registry()
	for piece_name: String in equipment:
		var piece: Dictionary = registry.get("pieces", {}).get(piece_name, {})
		_check(not piece.is_empty(), "writable equipment '%s' exists in the reader registry" % piece_name)
		_check(String(piece.get("slot", "")) == String(equipment[piece_name]),
			"writable equipment '%s' keeps its declared slot" % piece_name)

	var expanded_registry := registry.duplicate(true)
	(expanded_registry["pieces"] as Dictionary)["future_reader_boots"] = {
		"slot": "feet", "layer": "armor",
	}
	_check("future_reader_boots" not in CharacterCreator._pieces_in_slot(expanded_registry, "feet"),
		"reader-only equipment stays out of production pickers")

	var skins: Array = vocabulary.get("skins", [])
	var skin_registry := CharacterFactory.skins_registry()
	for skin_name: String in skins:
		_check(skin_name in skin_registry.get("skins", {}),
			"writable skin '%s' exists in the reader registry" % skin_name)
	var expanded_skins := skin_registry.duplicate(true)
	(expanded_skins["skins"] as Dictionary)["future_reader_skin"] = {"texture": "future.png"}
	_check("future_reader_skin" not in CharacterCreator.pickable_skins(expanded_skins),
		"reader-only skin stays out of production pickers")

	var shape_names := PackedStringArray(vocabulary.get("shapes", []))
	var kit: Node3D = load(CharacterFactory.KIT_SCENE_PATH).instantiate()
	var body := CharacterFactory.find_skinned_mesh(CharacterFactory.find_skeleton(kit))
	_check(body != null, "humanoid reader mesh loads")
	var reader_shapes := PackedStringArray()
	if body != null:
		for i in body.mesh.get_blend_shape_count():
			var reader_shape := String(body.mesh.get_blend_shape_name(i))
			if not reader_shape.begins_with(CharacterFactory.HIDE_SHAPE_PREFIX):
				reader_shapes.append(reader_shape)
	for shape_name: String in shape_names:
		_check(shape_name in reader_shapes,
			"writable shape '%s' exists in the reader mesh" % shape_name)
	kit.free()
	var future_shapes := shape_names.duplicate()
	future_shapes.append("future_reader_shape")
	_check("future_reader_shape" not in CharacterCreator.pickable_shape_names(future_shapes),
		"reader-only blend shape stays out of production sliders")

	for field: String in vocabulary.get("bone_keys", {}):
		for key: String in vocabulary["bone_keys"][field]:
			_check(key in (CharacterFactory.GUARDED_BONE_KEYS[field] as Array),
				"writable bone key '%s.%s' exists in the reader contract" % [field, key])

	var allowed := {
		"version": 4,
		"shapes": {shape_names[0]: 0.4},
		"equipment": {String(equipment.values()[0]): String(equipment.keys()[0])},
		"skin": String(skins[0]),
	}
	_check(CharacterCreator.writer_vocabulary_problem({}, allowed) == "",
		"allowlisted vocabulary may be newly originated")
	_check(CharacterCreator.writer_vocabulary_problem({}, {
		"version": 4, "shapes": {"future_reader_shape": 0.4},
	}) != "", "an unactivated shape cannot be newly originated")
	_check(CharacterCreator.writer_vocabulary_problem({}, {
		"version": 4, "bone_scale": {"future_reader_bone": 1.1},
	}) != "", "an unactivated bone key cannot be newly originated")
	_check(CharacterCreator.writer_vocabulary_problem({}, {
		"version": 4, "equipment": {"feet": "future_reader_boots"},
	}) != "", "an unactivated equipment pair cannot be newly originated")
	_check(CharacterCreator.writer_vocabulary_problem({}, {
		"version": 4, "skin": "future_reader_skin",
	}) != "", "an unactivated skin cannot be newly originated")

	var future_initial := {
		"version": 4,
		"shapes": {"future_reader_shape": 0.4},
		"equipment": {"feet": "future_reader_boots"},
		"skin": "future_reader_skin",
	}
	_check(CharacterCreator.writer_vocabulary_problem(future_initial, future_initial) == "",
		"an expansion reader may preserve future vocabulary already present")
	var preserved_with_edit := future_initial.duplicate(true)
	preserved_with_edit["equipment"]["torso"] = "shirt_ragged"
	_check(CharacterCreator.writer_vocabulary_problem(future_initial, preserved_with_edit) == "",
		"an ordinary activated edit may preserve future vocabulary already present")

	for preset_name: String in CharacterCreator.PRESETS:
		var preset = CharacterFactory.load_recipe(CharacterCreator.PRESET_DIR + preset_name + ".json")
		_check(preset is Dictionary, "preset '%s' loads" % preset_name)
		if preset is Dictionary:
			_check(CharacterCreator.writer_vocabulary_problem({}, preset) == "",
				"preset '%s' originates only activated vocabulary" % preset_name)

	if _failed:
		print("TEST FAIL — character writer vocabulary")
		get_tree().quit(1)
	else:
		print("TEST PASS — character writer vocabulary")
		get_tree().quit(0)


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	push_error("character writer vocabulary: %s" % message)
