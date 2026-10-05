extends Node
## The isolated integer step is a latent library, never the player's physics.

var _failed := false
var _core: Object


func _ready() -> void:
	if not _check(FileAccess.file_exists("res://scripts/ground_step.gd"), "integer ground-step core is missing"):
		get_tree().quit(1)
		return
	_core = load("res://scripts/ground_step.gd").new()
	_test_spec()
	_test_arithmetic()
	_test_step()
	_test_direction()
	if not _failed:
		print("TEST PASS: explicit spec, exact arithmetic, ground step and server direction")
	get_tree().quit(1 if _failed else 0)


func _spec() -> Dictionary:
	return {"max_speed_mm_s": 4000, "min_x": -20000, "min_y": 0, "min_z": -20000,
		"max_x": 20000, "max_y": 4000, "max_z": 20000, "hold_ticks": 2,
		"collision_mode": "isolated_flat"}


func _test_spec() -> void:
	var spec := _spec()
	var accepted: Dictionary = _core.validate_spec(spec)
	_check(accepted["ok"], "valid flat specification refused")
	spec["max_speed_mm_s"] = 1
	_check(accepted["spec"]["max_speed_mm_s"] == 4000, "spec result aliases input")
	for key: String in _spec():
		var missing := _spec()
		missing.erase(key)
		_check(not _core.validate_spec(missing)["ok"], "missing spec field admitted: " + key)
	for row: Array in [["max_speed_mm_s", -1], ["max_speed_mm_s", 1000000001],
		["max_speed_mm_s", true], ["max_speed_mm_s", 4000.0], ["min_x", -1000001],
		["max_z", 1000001], ["min_y", 4001], ["hold_ticks", 0], ["hold_ticks", 301],
		["hold_ticks", "2"], ["collision_mode", "swept"]]:
		var invalid := _spec()
		invalid[row[0]] = row[1]
		_check(not _core.validate_spec(invalid)["ok"], "invalid spec field admitted: " + str(row))
	var extra := _spec()
	extra["terrain"] = true
	_check(not _core.validate_spec(extra)["ok"], "unknown configuration silently accepted")


func _test_arithmetic() -> void:
	for row: Array in [[0, 0], [1, 1], [2, 1], [3, 1], [4, 2], [15, 3], [16, 4],
		[17, 4], [1000000014000000048, 1000000006],
		[1000000014000000049, 1000000007], [2000000000000000000, 1414213562]]:
		_check(_core.integer_sqrt(row[0]) == row[1], "integer square root lost precision: " + str(row[0]))
	_check(_core.integer_sqrt(-1) == -1 and _core.integer_sqrt(2000000000000000001) == -1, "invalid square domain admitted")
	for row: Array in [[31, 30, 1], [-31, 30, -1], [29, 30, 0], [-29, 30, 0],
		[2000000000000000000, 3, 666666666666666666],
		[-2000000000000000000, 3, -666666666666666666]]:
		var quotient: Dictionary = _core.truncate_divide(row[0], row[1])
		_check(quotient["ok"] and quotient["value"] == row[2], "division is not exact truncation")
	_check(not _core.truncate_divide(1, 0)["ok"] and not _core.truncate_divide(1, -1)["ok"], "invalid denominator admitted")


func _test_step() -> void:
	var position := {"x": 0, "y": 147, "z": 0}
	var right: Dictionary = _core.step(position, {"x": 4000, "y": 999, "z": 0}, _spec())
	_check(right["ok"] and right["position"] == {"x": 133, "y": 147, "z": 0}, "cardinal step or height mismatch")
	var diagonal: Dictionary = _core.step(position, {"x": -4000, "y": -999, "z": -4000}, _spec())
	_check(diagonal["position"] == {"x": -94, "y": 147, "z": -94}, "negative diagonal step mismatch")
	var hostile: Dictionary = _core.step(position, {"x": 9223372036854775807, "y": 999, "z": -9223372036854775807}, _spec())
	_check(hostile["position"] == {"x": 94, "y": 147, "z": -94}, "intent sanitization overflowed or drifted")
	var edge: Dictionary = _core.step({"x": 19999, "y": 4000, "z": -19999}, {"x": 4000, "y": 9, "z": -4000}, _spec())
	_check(edge["position"] == {"x": 20000, "y": 4000, "z": -20000}, "world clamp escaped bounds")
	var zero := _spec()
	zero["max_speed_mm_s"] = 0
	_check(_core.step(position, {"x": 99, "y": 99, "z": 99}, zero)["position"] == position, "zero cap moved actor")
	var slow := _spec()
	slow["max_speed_mm_s"] = 29
	_check(_core.step(position, {"x": -29, "y": 0, "z": 0}, slow)["position"] == position, "sub-tick negative displacement rounded")
	_check(not _core.step({"x": 0.0, "y": 0, "z": 0}, {"x": 0, "y": 0, "z": 0}, _spec())["ok"], "float authority admitted")
	_check(not _core.step(position, {"x": true, "y": 0, "z": 0}, _spec())["ok"], "boolean velocity admitted")
	_check(position == {"x": 0, "y": 147, "z": 0}, "step mutated caller's position")


func _test_direction() -> void:
	var odd := _spec()
	odd["max_speed_mm_s"] = 4001
	_check(_core.direction_velocity({"x": 1000, "z": 0, "sprint": false}, odd)["velocity"] == {"x": 2000, "y": 0, "z": 0}, "walk cap rounded upwards")
	_check(_core.direction_velocity({"x": -707, "z": 707, "sprint": true}, odd)["velocity"] == {"x": -2828, "y": 0, "z": 2828}, "sprint conversion drifted")
	for sample: Dictionary in [{"x": 1001, "z": 0, "sprint": false},
		{"x": 1000, "z": 1, "sprint": true}, {"x": 0.0, "z": 0, "sprint": false},
		{"x": true, "z": 0, "sprint": false}, {"x": 0, "z": 0, "sprint": 1},
		{"x": 0, "z": 0}, {"x": 0, "z": 0, "sprint": false, "speed": 999}]:
		_check(not _core.direction_velocity(sample, _spec())["ok"], "noncanonical movement sample admitted")


func _check(condition: bool, detail: String) -> bool:
	if not condition:
		_failed = true
		print("TEST FAIL: " + detail)
	return condition

