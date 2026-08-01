extends Node
## Regression test for first-run wardrobe frame coverage (#653, under #222).
##
## The capture used to drive only the head clothing/armour pair. That left the
## production-activated hand armour visible as a picker name but never rendered
## through the real creator mutation path. The literal plan below is derived
## from the shipped writer vocabulary and registry: removing any active
## region/layer from the capture plan must fail loudly.
##
## Run: godot --headless --path client res://tests/frame_capture_outfit_test.tscn

const EXPECTED_STATES := [
	{"slot": "torso", "layer": "clothing", "piece": "shirt_ragged", "shot": "first_run_torso_clothing"},
	{"slot": "legs", "layer": "clothing", "piece": "pants_wool", "shot": "first_run_legs_clothing"},
	{"slot": "feet", "layer": "clothing", "piece": "shoes_cloth", "shot": "first_run_feet_clothing"},
	{"slot": "feet", "layer": "armor", "piece": "boots_worn", "shot": "first_run_feet_armor"},
	{"slot": "head", "layer": "clothing", "piece": "relic_goggles", "shot": "first_run_head_clothing"},
	{"slot": "head", "layer": "armor", "piece": "ruin_drake_helm", "shot": "first_run_head_armor"},
	{"slot": "hands", "layer": "armor", "piece": "ashen_bindings", "shot": "first_run_hands_armor"},
]

var _failed := false


func _ready() -> void:
	var capture_script := load("res://tools/frame_capture.gd") as GDScript
	_check(capture_script != null, true, "the real frame-capture tool loads")
	if _failed:
		return
	var capture := capture_script.new() as Node
	_check(capture.has_method("outfit_capture_states"), true,
		"the frame-capture tool exposes its real wardrobe plan")
	if _failed:
		capture.free()
		return
	var actual: Array = capture.call(
		"outfit_capture_states", CharacterFactory.equipment_registry())
	_check(actual == EXPECTED_STATES, true,
		"every production-activated wardrobe region/layer has a stable capture state\nexpected: %s\nactual:   %s"
		% [str(EXPECTED_STATES), str(actual)])
	capture.free()
	if _failed:
		return
	print("TEST PASS — first-run capture plans all 7 production-active wardrobe states, including hands armour")
	get_tree().quit(0)


func _check(actual: bool, expected: bool, label: String) -> void:
	if _failed:
		return
	if actual != expected:
		_failed = true
		var message := "%s — expected %s, got %s" % [label, expected, actual]
		push_error(message)
		print("TEST FAIL — %s" % message)
		get_tree().quit(1)
