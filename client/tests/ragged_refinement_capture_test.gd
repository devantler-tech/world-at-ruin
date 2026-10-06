extends Node
## The control must remove this refinement alone, retaining the older folds.

var _failed := false


func _ready() -> void:
	var capture := load("res://tools/frame_capture.gd").new() as Node
	if not capture.has_method("ragged_unrefined_mesh"):
		_check(false, "actual frame capture needs an independent waist/shell-only control")
	else:
		var state := TestEnvironment.snapshot([RaggedDrape.FLAG_ENV])
		OS.set_environment(RaggedDrape.FLAG_ENV, "1")
		var recipe: Dictionary = CharacterFactory.load_recipe("res://recipes/wanderer.json")
		var character := CharacterFactory.build(recipe)
		var garment := CharacterFactory.find_skeleton(character).get_node("Equip_loincloth_ragged") as MeshInstance3D
		var source := garment.get_meta(RaggedDrape.SOURCE_META) as ArrayMesh
		var control := capture.call("ragged_unrefined_mesh", garment) as ArrayMesh
		var ruler := load("res://tests/ragged_wrap_shape_test.gd").new() as Node
		var old: Vector2 = ruler.call("_dimensions", source, control)
		_check(old.x > 0.05 and old.y > 0.007, "control restores the old band and shell dimensions")
		var base: PackedVector3Array = source.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var kept: PackedVector3Array = control.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var hanging := 0
		for i in base.size():
			if base[i].y < 0.84 and kept[i].distance_to(base[i]) > 0.01:
				hanging += 1
		_check(hanging > 100, "waist/shell control retains the previously gathered hanging drape")
		_check(garment.mesh != control, "constructing the control does not replace the live mesh")
		OS.unset_environment(RaggedDrape.FLAG_ENV)
		var off := CharacterFactory.build(recipe)
		var off_piece := CharacterFactory.find_skeleton(off).get_node("Equip_loincloth_ragged") as MeshInstance3D
		_check(capture.call("ragged_unrefined_mesh", off_piece) == off_piece.mesh, "disabled geometry stays byte-identical in both capture arms")
		ruler.free()
		off.free()
		character.free()
		TestEnvironment.restore(state)
	capture.free()
	if not _failed:
		print("TEST PASS — capture control removes only waist/shell refinement and retains previous drape")
	get_tree().quit(1 if _failed else 0)


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error(message)
		print("TEST FAIL — " + message)
