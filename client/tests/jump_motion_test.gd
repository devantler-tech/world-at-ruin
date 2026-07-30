extends Node
## Regression test for #553, the remaining jump slice of #224.
##
## The controller moves the capsule through a real jump, while this opt-in
## treatment gives the recipe skeleton an airborne pose. These laws exercise
## the production Player input path so a preview-only pose or a pure helper
## cannot satisfy them:
##
##  1. DEFAULT-OFF — a normal jump leaves the shipped pose untouched.
##  2. OPT-IN — WAR_JUMP_MOTION makes that same real jump move the body.
##
## Run: godot --headless --path client res://tests/jump_motion_test.tscn

const FLAG := "WAR_JUMP_MOTION"
const WALK_FLAG := "WAR_WALK_CYCLE"
const RUN_FLAG := "WAR_RUN_CYCLE"
const RECIPE_PATH := "res://recipes/wanderer.json"
const DRIVEN_BONES := [
	"thigh_l", "thigh_r",
	"calf_l", "calf_r",
	"upperarm_l", "upperarm_r",
	"lowerarm_l", "lowerarm_r",
]
const POSE_EPSILON := 0.00001
const CROSS_BODY_EPSILON := 0.004363323
const MIN_PHASE_DISTANCE_RAD := 0.052359878
const MIN_TRAVEL_Y := 0.05

var _environment := {}
var _recipe := {}
var _floor: StaticBody3D


func _ready() -> void:
	for key in [FLAG, WALK_FLAG, RUN_FLAG]:
		_environment[key] = {
			"had": OS.has_environment(key),
			"value": OS.get_environment(key),
		}
	var loaded = CharacterFactory.load_recipe(RECIPE_PATH)
	if not (loaded is Dictionary):
		_fail("could not load %s" % RECIPE_PATH)
		return
	_recipe = loaded
	_floor = _build_floor()

	if not await _check_default_off():
		return
	if not await _check_real_player_jump_moves_the_opted_in_pose():
		return
	if not await _check_landing_restores_standing_pose():
		return
	if not _check_phases_are_distinct_and_deterministic():
		return
	if not _check_airborne_silhouettes_stay_bilateral():
		return

	_finish()
	print("TEST PASS — jump motion is default-off; the real Player path moves and lands cleanly; takeoff, apex, and descent are bilateral, distinct, and deterministic")
	get_tree().quit(0)


## Removing the flag gate makes this fail: ordinary players would be enrolled
## in an unfinished motion treatment without opting in.
func _check_default_off() -> bool:
	var subject := await _jump_subject("")
	if subject.is_empty():
		return false
	var same := _same_pose(
		subject["standing"],
		_snapshot(subject["skeleton"]),
		"flag unset: a normal jump changed the shipped skeleton pose")
	_free_subject(subject)
	return same


## Production break this catches: Player can still translate upward while the
## locomotion driver receives no airborne state, or receives it but never poses
## the bound recipe skeleton.
func _check_real_player_jump_moves_the_opted_in_pose() -> bool:
	var subject := await _jump_subject("1")
	if subject.is_empty():
		return false
	var player: Player = subject["player"]
	var rise := player.global_position.y - float(subject["standing_y"])
	if rise < MIN_TRAVEL_Y:
		_free_subject(subject)
		return _fail("real jump input raised Player only %.4f m" % rise)
	if _same_pose(subject["standing"], _snapshot(subject["skeleton"]), ""):
		_free_subject(subject)
		return _fail(
			"real Player jump translated %.3f m but left every jump bone at standing pose" % rise)
	_free_subject(subject)
	return true


## Production break this catches: the airborne pose is applied, but the
## grounded no-gait path returns without clearing it, leaving the wanderer
## crouched forever after the first jump.
func _check_landing_restores_standing_pose() -> bool:
	var subject := await _jump_subject("1")
	if subject.is_empty():
		return false
	var player: Player = subject["player"]
	for _i in 180:
		await get_tree().physics_frame
		if player.is_on_floor():
			var restored := _same_pose(
				subject["standing"],
				_snapshot(subject["skeleton"]),
				"landing left the airborne pose stuck on the recipe skeleton")
			_free_subject(subject)
			return restored
	_free_subject(subject)
	return _fail("Player did not land within 180 physics frames")


## Production breaks this catches: returning one crouch for every airborne
## velocity, keying the pose to wall-clock time, or applying the same input
## differently to two recipe bodies.
func _check_phases_are_distinct_and_deterministic() -> bool:
	if not is_equal_approx(WalkLocomotion.JUMP_REFERENCE_SPEED, Player.JUMP_VELOCITY):
		return _fail(
			"jump pose envelope %.2f m/s drifted from Player launch speed %.2f m/s" %
				[WalkLocomotion.JUMP_REFERENCE_SPEED, Player.JUMP_VELOCITY])
	var first := _bound_subject("1")
	var second := _bound_subject("1")
	if first.is_empty() or second.is_empty():
		_free_subject(first)
		_free_subject(second)
		return false
	var animator: Node = first["animator"]
	if not animator.has_method("apply_jump"):
		_free_subject(first)
		_free_subject(second)
		return _fail(
			"the shipping locomotion driver exposes no exact jump phase for deterministic evidence")

	var speeds := [Player.JUMP_VELOCITY, 0.0, -Player.JUMP_VELOCITY]
	var poses: Array[Dictionary] = []
	for speed: float in speeds:
		animator.call("apply_jump", speed)
		poses.append(_snapshot(first["skeleton"]))
	for pair in [[0, 1], [1, 2], [0, 2]]:
		var distance := _pose_distance(poses[pair[0]], poses[pair[1]])
		if distance < MIN_PHASE_DISTANCE_RAD:
			_free_subject(first)
			_free_subject(second)
			return _fail(
				"jump phases %d and %d differ by only %.3f deg across the full body" %
				[pair[0], pair[1], rad_to_deg(distance)])

	var other_animator: Node = second["animator"]
	for i in speeds.size():
		other_animator.call("apply_jump", speeds[i])
		if not _same_pose(
				poses[i],
				_snapshot(second["skeleton"]),
				"identical vertical speed produced a different jump pose on a second body",
				CROSS_BODY_EPSILON):
			_free_subject(first)
			_free_subject(second)
			return false
	_free_subject(first)
	_free_subject(second)
	return true


## The first render exposed a split-legged, cross-body apex even though every
## correctness assertion was green. This rig mirrors thigh and upper-arm local
## X, so bilateral motion needs opposite signed rotations on those channels;
## calf and elbow flexion are unmirrored and need equal signed rotations.
func _check_airborne_silhouettes_stay_bilateral() -> bool:
	for speed in [Player.JUMP_VELOCITY, 0.0, -Player.JUMP_VELOCITY]:
		var angles := WalkLocomotion.jump_angles(speed)
		for mirrored_pair in [["thigh_l", "thigh_r"], ["upperarm_l", "upperarm_r"]]:
			var signed_sum: float = angles[mirrored_pair[0]] + angles[mirrored_pair[1]]
			if not is_zero_approx(signed_sum):
				return _fail(
					"%s and %s split the %.1f m/s silhouette by %.2f deg" %
						[mirrored_pair[0], mirrored_pair[1], speed, signed_sum])
		for flex_pair in [["calf_l", "calf_r"], ["lowerarm_l", "lowerarm_r"]]:
			var flex_delta: float = absf(angles[flex_pair[0]] - angles[flex_pair[1]])
			if not is_zero_approx(flex_delta):
				return _fail(
					"%s and %s bend the %.1f m/s silhouette %.2f deg apart" %
						[flex_pair[0], flex_pair[1], speed, flex_delta])
	return true


func _jump_subject(flag_value: String) -> Dictionary:
	var subject := _bound_subject(flag_value)
	if subject.is_empty():
		return {}
	var player: Player = subject["player"]
	var skeleton: Skeleton3D = subject["skeleton"]
	player.set_physics_process(true)
	player.global_position = Vector3(0.0, 0.02, 0.0)
	for _i in 4:
		await get_tree().physics_frame
	if not player.is_on_floor():
		player.free()
		_fail("Player did not settle on the real collision floor before jumping")
		return {}
	var standing := _snapshot(skeleton)
	var standing_y := player.global_position.y

	Input.action_press("jump")
	await get_tree().physics_frame
	Input.action_release("jump")
	await get_tree().physics_frame
	if player.is_on_floor():
		player.free()
		_fail("real jump input never left the floor")
		return {}
	subject["standing"] = standing
	subject["standing_y"] = standing_y
	return subject


func _bound_subject(flag_value: String) -> Dictionary:
	_set_flag(FLAG, flag_value)
	OS.unset_environment(WALK_FLAG)
	OS.unset_environment(RUN_FLAG)
	var player := Player.new()
	add_child(player)
	player.set_physics_process(false)
	player.set_character(_recipe)
	var skeleton := CharacterFactory.find_skeleton(player.get_node("Visual"))
	if skeleton == null:
		player.free()
		_fail("real Player path built no recipe skeleton")
		return {}
	for bone_name: String in DRIVEN_BONES:
		if skeleton.find_bone(bone_name) < 0:
			player.free()
			_fail("the shipped rig has no required jump bone %s" % bone_name)
			return {}
	var animator := player.get_node_or_null("WalkLocomotion")
	if animator == null:
		player.free()
		_fail("real Player path has no shipping locomotion driver")
		return {}
	return {
		"player": player,
		"skeleton": skeleton,
		"animator": animator,
	}


func _build_floor() -> StaticBody3D:
	var floor := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20.0, 0.2, 20.0)
	shape.shape = box
	shape.position.y = -0.1
	floor.add_child(shape)
	add_child(floor)
	return floor


func _snapshot(skeleton: Skeleton3D) -> Dictionary:
	var result := {}
	for bone_name: String in DRIVEN_BONES:
		var bone := skeleton.find_bone(bone_name)
		var rest := skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
		var pose := skeleton.get_bone_pose_rotation(bone)
		result[bone_name] = rest.inverse() * pose
	return result


func _same_pose(
		a: Dictionary,
		b: Dictionary,
		message: String,
		epsilon: float = POSE_EPSILON) -> bool:
	for bone_name: String in DRIVEN_BONES:
		var qa: Quaternion = a[bone_name]
		var qb: Quaternion = b[bone_name]
		if qa.angle_to(qb) > epsilon:
			return _fail("%s (%s differs by %.6f rad)" %
				[message, bone_name, qa.angle_to(qb)]) if not message.is_empty() else false
	return true


func _pose_distance(a: Dictionary, b: Dictionary) -> float:
	var distance := 0.0
	for bone_name: String in DRIVEN_BONES:
		distance = maxf(
			distance,
			(a[bone_name] as Quaternion).angle_to(b[bone_name] as Quaternion))
	return distance


func _set_flag(key: String, value: String) -> void:
	if value.is_empty():
		OS.unset_environment(key)
	else:
		OS.set_environment(key, value)


func _free_subject(subject: Dictionary) -> void:
	if not subject.is_empty() and is_instance_valid(subject.get("player")):
		(subject["player"] as Player).free()


func _finish() -> void:
	Input.action_release("jump")
	for key: String in _environment:
		var saved: Dictionary = _environment[key]
		if saved["had"] as bool:
			OS.set_environment(key, saved["value"] as String)
		else:
			OS.unset_environment(key)
	if is_instance_valid(_floor):
		_floor.free()


func _fail(message: String) -> bool:
	_finish()
	push_error("jump_motion_test: " + message)
	get_tree().quit(1)
	return false
