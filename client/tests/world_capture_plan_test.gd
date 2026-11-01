extends "res://tests/boolean_verdict.gd"
## Every isolated capture must cover exactly one member of the complete plan.

const EXPECTED := [
	"sunward", "crossfield", "shrine", "bonepale", "cinderreach",
	"cave-chamber", "cave-walkout", "cave-mouth",
]


func _ready() -> void:
	var script := load("res://tools/frame_capture.gd") as GDScript
	_check(script != null, true, "the shipped capture implementation loads")
	if _failed:
		return
	var capture := script.new() as Node
	_check(capture.has_method("world_capture_plan"), true,
		"the real renderer exposes its complete and partitioned world plan")
	if _failed:
		capture.free()
		return
	_check(capture.call("world_capture_plan", "") == EXPECTED, true,
		"an ordinary capture retains every existing exterior and cave view")
	var union: Array = []
	for vantage: String in EXPECTED:
		var selected: Array = capture.call("world_capture_plan", vantage)
		_check(selected == [vantage], true, "a partition renders only its exact view")
		union.append_array(selected)
	_check(union == EXPECTED, true, "the partition union has no omission or replay")
	for invalid: String in ["unknown", "all", "sunward,crossfield", " sunward", "sunward\n"]:
		_check(capture.call("world_capture_plan", invalid).is_empty(), true,
			"an unknown or ambiguous partition cannot silently select a default")
	capture.free()
	if _failed:
		return
	print("TEST PASS — complete world capture and eight disjoint partitions agree")
	get_tree().quit(0)
