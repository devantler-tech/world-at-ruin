class_name GroundStep
extends RefCounted
## Exact isolated flat-zone arithmetic. No collision or player runtime caller.

const TICK_HZ := 30
const MAX_EXTENT := 1000000
const MAX_COMPONENT := 1000000000
const MAX_SQUARE := 2000000000000000000
const SPEC_KEYS := ["max_speed_mm_s", "min_x", "min_y", "min_z", "max_x", "max_y", "max_z", "hold_ticks", "collision_mode"]


static func validate_spec(spec: Dictionary) -> Dictionary:
	if spec.size() != SPEC_KEYS.size() or not spec.has_all(SPEC_KEYS):
		return _refuse("prediction_spec")
	if spec["collision_mode"] != "isolated_flat":
		return _refuse("prediction_collision")
	for key: String in SPEC_KEYS:
		if key != "collision_mode" and typeof(spec[key]) != TYPE_INT:
			return _refuse("prediction_spec")
	if spec["max_speed_mm_s"] < 0 or spec["max_speed_mm_s"] > MAX_COMPONENT:
		return _refuse("prediction_spec")
	if spec["hold_ticks"] < 1 or spec["hold_ticks"] > 300:
		return _refuse("prediction_spec")
	for axis: String in ["x", "y", "z"]:
		var lo: int = spec["min_" + axis]
		var hi: int = spec["max_" + axis]
		if lo < -MAX_EXTENT or hi > MAX_EXTENT or lo > hi:
			return _refuse("prediction_spec")
	return {"ok": true, "spec": spec.duplicate(true)}


## -1 is the refusal sentinel; valid roots are nonnegative.
static func integer_sqrt(value: int) -> int:
	if value < 0 or value > MAX_SQUARE:
		return -1
	if value < 2:
		return value
	var x := value
	@warning_ignore("integer_division")
	var y := (x + 1) / 2
	while y < x:
		x = y
		@warning_ignore("integer_division")
		y = (x + value / x) / 2
	return x


static func truncate_divide(numerator: int, denominator: int) -> Dictionary:
	if denominator <= 0:
		return _refuse("prediction_division")
	@warning_ignore("integer_division")
	var value := numerator / denominator
	return {"ok": true, "value": value}


static func step(position: Dictionary, velocity: Dictionary, spec: Dictionary) -> Dictionary:
	if not validate_spec(spec)["ok"] or not valid_position(position, spec) or not _integer_vector(velocity):
		return _refuse("prediction_step")
	var x := clampi(velocity["x"], -MAX_COMPONENT, MAX_COMPONENT)
	var z := clampi(velocity["z"], -MAX_COMPONENT, MAX_COMPONENT)
	var cap: int = spec["max_speed_mm_s"]
	if cap == 0:
		x = 0
		z = 0
	else:
		var speed := integer_sqrt(x * x + z * z)
		if speed > cap:
			@warning_ignore("integer_division")
			x = x * cap / speed
			@warning_ignore("integer_division")
			z = z * cap / speed
	@warning_ignore("integer_division")
	var dx := x / TICK_HZ
	@warning_ignore("integer_division")
	var dz := z / TICK_HZ
	return {"ok": true, "position": {
		"x": clampi(position["x"] + dx, spec["min_x"], spec["max_x"]),
		"y": position["y"],
		"z": clampi(position["z"] + dz, spec["min_z"], spec["max_z"])}}


static func direction_velocity(sample: Dictionary, spec: Dictionary) -> Dictionary:
	if not validate_spec(spec)["ok"] or sample.size() != 3 or not sample.has_all(["x", "z", "sprint"]):
		return _refuse("prediction_sample")
	if typeof(sample["x"]) != TYPE_INT or typeof(sample["z"]) != TYPE_INT or typeof(sample["sprint"]) != TYPE_BOOL:
		return _refuse("prediction_sample")
	var x: int = sample["x"]
	var z: int = sample["z"]
	if x < -1000 or x > 1000 or z < -1000 or z > 1000 or x * x + z * z > 1000000:
		return _refuse("prediction_sample")
	var cap: int = spec["max_speed_mm_s"]
	if not sample["sprint"]:
		@warning_ignore("integer_division")
		cap /= 2
	@warning_ignore("integer_division")
	var vx := x * cap / 1000
	@warning_ignore("integer_division")
	var vz := z * cap / 1000
	return {"ok": true, "velocity": {"x": vx, "y": 0, "z": vz}}


static func valid_position(position: Dictionary, spec: Dictionary) -> bool:
	if not _integer_vector(position):
		return false
	for axis: String in ["x", "y", "z"]:
		if position[axis] < spec["min_" + axis] or position[axis] > spec["max_" + axis]:
			return false
	return true


static func _integer_vector(value: Dictionary) -> bool:
	return value.size() == 3 and value.has_all(["x", "y", "z"]) and typeof(value["x"]) == TYPE_INT and typeof(value["y"]) == TYPE_INT and typeof(value["z"]) == TYPE_INT


static func _refuse(error_class: String) -> Dictionary:
	return {"ok": false, "error": error_class}
