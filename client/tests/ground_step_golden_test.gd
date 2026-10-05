extends Node
## Client observations are compared with real Go World.Step output.

const Ground = preload("res://scripts/ground_step.gd")
var _failed := false


func _ready() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://tests/data/ground_step_goldens.json"))
	if not _check(parsed is Dictionary and parsed.get("version") == 1 and parsed.get("cases", []).size() == 10 and parsed.get("directions", []).size() == 6, "shared ground corpus is incomplete"):
		get_tree().quit(1)
		return
	var ticks := 0
	for row: Dictionary in parsed["cases"]:
		var spec := _integers(row["spec"])
		var position := _integers(row["initial"])
		if not _check(row["inputs"].size() > 0 and row["inputs"].size() == row["positions"].size(), "missing ground observations"):
			break
		for i: int in row["inputs"].size():
			var stepped := Ground.step(position, _integers(row["inputs"][i]), spec)
			if not _check(stepped["ok"] and stepped["position"] == _integers(row["positions"][i]), "Go/Godot position differs: " + row["name"] + " tick " + str(i + 1)):
				break
			position = stepped["position"]
			ticks += 1
	for row: Dictionary in parsed["directions"]:
		var converted := Ground.direction_velocity(_integers(row["sample"]), _integers(row["spec"]))
		_check(converted["ok"] and converted["velocity"] == _integers(row["velocity"]), "Go/Godot direction differs")
	_check(ticks == 23, "ground observation count changed")
	if not _failed:
		print("TEST PASS: 23 actual Go ground-step positions and six direction vectors")
	get_tree().quit(1 if _failed else 0)


func _integers(value: Dictionary) -> Dictionary:
	var result := {}
	for key: String in value:
		result[key] = value[key] if key in ["collision_mode", "sprint"] else int(value[key])
	return result


func _check(condition: bool, detail: String) -> bool:
	if not condition:
		_failed = true
		print("TEST FAIL: " + detail)
	return condition

