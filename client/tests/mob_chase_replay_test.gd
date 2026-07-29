extends Node
## Cross-tier mob-chase replay (issue #357).
##
## The Go half generates the committed frames from the authoritative World and
## wire encoder. This side requires the evidence helper to carry every frame
## through the real ZoneConnection pump, then inspects the store a ReplicaView
## consumes. A direct WireCodec/ReplicaStore fold would miss the connection
## path this issue exists to exercise.

const REPLAY_PATH := "res://tools/mob_chase_replay.gd"

var _failed := false


func _ready() -> void:
	var replay_script := load(REPLAY_PATH) as Script
	if replay_script == null:
		_fail("could not load %s — the authoritative chase stream has no client-connection replay path" % REPLAY_PATH)
		return
	var replay: RefCounted = replay_script.new()
	if not replay.call("is_valid"):
		_fail("mob-chase fixture was refused: %s" % replay.call("error_detail"))
		return
	if not replay.call("start"):
		_fail("mob-chase connection did not start: %s" % replay.call("error_detail"))
		return

	var connection: ZoneConnection = replay.call("connection")
	if connection == null or not connection.is_live():
		_fail("replay did not reach the real ZoneConnection LIVE state")
		return

	var previous_distance2 := -1
	var cast_position := Vector2i()
	var have_cast_position := false
	var approach_frames := 0
	var hold_frames := 0
	while replay.call("has_next"):
		var result: Dictionary = replay.call("advance")
		if result.get("ok") != true:
			_fail("frame replay failed: %s" % str(result))
			return
		var mob: Dictionary = connection.store().entity(int(replay.call("mob_id")))
		var target: Dictionary = connection.store().entity(int(replay.call("target_id")))
		if mob.is_empty() or target.is_empty():
			_fail("folded frame %d omitted the mob or target" % int(result.get("tick", -1)))
			return
		var dx: int = int(mob["x"]) - int(target["x"])
		var dz: int = int(mob["z"]) - int(target["z"])
		var distance2 := dx * dx + dz * dz
		var phase := String(result["phase"])
		if phase == "approach":
			approach_frames += 1
			if previous_distance2 >= 0 and distance2 >= previous_distance2:
				_fail("connection replay did not close during approach: %d after %d" % [distance2, previous_distance2])
				return
		elif phase == "cast_start" or phase == "cast_hold":
			var position := Vector2i(int(mob["x"]), int(mob["z"]))
			var maximum_center_distance := (
				int(replay.call("cast_range_mm")) + int(mob["radius"]) + int(target["radius"])
			)
			if distance2 > maximum_center_distance * maximum_center_distance:
				_fail("connection replay began %s outside capsule-surface cast range" % phase)
				return
			if not have_cast_position:
				cast_position = position
				have_cast_position = true
			elif position != cast_position:
				_fail("render-store mob drifted during the held cast: %s -> %s" % [cast_position, position])
				return
			if phase == "cast_hold":
				hold_frames += 1
		else:
			_fail("connection replay exposed unknown phase %s" % phase)
			return
		previous_distance2 = distance2

	if approach_frames < 3 or hold_frames < 2:
		_fail("connection replay under-evidences motion: approach=%d hold=%d" % [approach_frames, hold_frames])
		return
	if connection.frames_applied() != int(replay.call("frame_count")):
		_fail("ZoneConnection folded %d/%d authoritative frames" % [connection.frames_applied(), replay.call("frame_count")])
		return

	var control: Dictionary = replay.call("stationary_control")
	var decoded := WireCodec.decode((control["hex"] as String).hex_decode())
	if decoded.get("ok") != true:
		_fail("stationary control did not decode: %s" % str(decoded))
		return
	var control_mob := _entity(decoded["snapshot"]["entities"], int(replay.call("mob_id")))
	var first_mob := replay.call("first_mob_state") as Dictionary
	if control_mob != first_mob:
		_fail("zero-speed stationary control moved: %s -> %s" % [first_mob, control_mob])
		return

	print("TEST PASS — %d authoritative chase frames folded through ZoneConnection (%d approach, %d held-cast)" %
		[connection.frames_applied(), approach_frames, hold_frames])
	get_tree().quit(0)


func _entity(entities: Array, id: int) -> Dictionary:
	for candidate: Variant in entities:
		var entity: Dictionary = candidate
		if int(entity["id"]) == id:
			return entity
	return {}


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
