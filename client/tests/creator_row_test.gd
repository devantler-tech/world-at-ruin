extends Node
## Inspect the actual owning controls; literal layout expectations stay here.
var _failed := false

func _ready() -> void:
	var creator := CharacterCreator.new()
	var host := VBoxContainer.new()
	creator.call("_add_region_outfit_picker", host, "torso")
	creator.set("_outfit_pickers", {})
	creator.call("_add_layer_outfit_picker", host, "torso", "armor")
	creator.call("_add_skin_picker", host)
	var slider: HSlider = creator.call("_labeled_slider", host, "shape", -0.5, 0.75)
	var expected := ["torso", "torso · armour", "skin", "shape"]
	_check(host.get_child_count() == 4, "row count changed")
	for i in host.get_child_count():
		var row := host.get_child(i) as HBoxContainer
		_check(row != null and row.get_child_count() == 2, "row child structure changed")
		if row == null or row.get_child_count() != 2:
			continue
		var label := row.get_child(0) as Label
		_check(label != null and label.text == expected[i], "row label/order changed")
		_check(label != null and label.custom_minimum_size == Vector2(130, 0), "label width changed")
		_check(row.get_theme_constant("separation") == 8, "row spacing changed")
		_check(row.get_child(1) is OptionButton if i < 3 else row.get_child(1) is HSlider,
			"control type/order changed")
		_check((row.get_child(1) as Control).size_flags_horizontal == Control.SIZE_EXPAND_FILL,
			"control expansion changed")
	_check(slider.min_value == -0.5 and slider.max_value == 0.75 and slider.step == 0.01,
		"slider range changed")
	host.free()
	creator.free()
	if not _failed:
		print("TEST PASS — outfit, skin and slider rows retain labels, child order and dimensions")
		get_tree().quit(0)

func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error("TEST FAIL — " + message)
		get_tree().quit(1)
