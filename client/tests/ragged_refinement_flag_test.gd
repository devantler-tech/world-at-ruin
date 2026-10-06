extends Node
## The prior drape contract survives unless its separate refinement is opted in.

const REFINEMENT := "WAR_RAGGED_WRAP_REFINEMENT"
var _failed := false


func _ready() -> void:
	var state := TestEnvironment.snapshot([RaggedDrape.FLAG_ENV, RaggedCloth.FLAG_ENV, REFINEMENT])
	OS.unset_environment(RaggedDrape.FLAG_ENV)
	OS.unset_environment(RaggedCloth.FLAG_ENV)
	OS.unset_environment(REFINEMENT)
	var recipe: Dictionary = CharacterFactory.load_recipe("res://recipes/wanderer.json")
	var off := CharacterFactory.build(recipe)
	var source := _piece(off).mesh as ArrayMesh
	OS.set_environment(REFINEMENT, "1")
	var alone := CharacterFactory.build(recipe)
	_check(_piece(alone).mesh == source, "refinement alone never activates the prerequisite drape")
	OS.set_environment(RaggedDrape.FLAG_ENV, "1")
	for value: String in ["", "0", "true", "1"]:
		if value.is_empty():
			OS.unset_environment(REFINEMENT)
		else:
			OS.set_environment(REFINEMENT, value)
		var character := CharacterFactory.build(recipe)
		var points: PackedVector3Array = _piece(character).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var base: PackedVector3Array = source.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var changed := 0
		for i in base.size():
			if base[i].y >= 0.888 and points[i] != base[i]:
				changed += 1
		_check((changed > 0) == (value == "1"), "only exact refinement opt-in changes the previously pinned waist: " + value)
		var body := CharacterFactory.find_skinned_mesh(CharacterFactory.find_skeleton(character))
		_check(body.has_meta(RaggedDrape.SKIN_SOURCE_META) == (value == "1"), "only exact refinement opt-in restores exposed skin")
		character.free()
	_check(recipe == CharacterFactory.load_recipe("res://recipes/wanderer.json"), "preview selection never rewrites the recipe")
	alone.free()
	off.free()
	TestEnvironment.restore(state)
	if not _failed:
		print("TEST PASS — independent refinement defaults off, requires drape and preserves its pinned-waist contract")
	get_tree().quit(1 if _failed else 0)


func _piece(character: Node3D) -> MeshInstance3D:
	return CharacterFactory.find_skeleton(character).get_node("Equip_loincloth_ragged") as MeshInstance3D


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error(message)
		print("TEST FAIL — " + message)
