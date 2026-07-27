extends Node
## Regression test for the first locomotion slice (#402, part of #224).
##
## The player already moves through the world, but the recipe-built skeleton
## stays in its standing pose. This test exercises the real Player ->
## CharacterFactory wiring and holds the deliberately narrow first gait:
##
##  1. DEFAULT-OFF — ordinary movement does not touch the shipped pose.
##  2. OPT-IN — grounded non-sprint travel drives opposing legs, counter-swung
##     arms, and a flexed knee.
##  3. DISTANCE-DRIVEN — equal travelled distances land on the same pose even
##     when speed and delta differ.
##  4. HONEST STATES — stop, airborne and sprint restore the standing pose;
##     the walk does not impersonate the run or jump work still missing.
##  5. SEAMLESS + DETERMINISTIC — phase 0 and TAU agree, and identical travel
##     produces byte-equivalent bone rotations on separate player bodies.
##
## Each assertion names a real break: deleting the Player hook, inverting a
## limb, driving from render time, leaving a walk pose stuck at rest, or
## silently enrolling players with the flag unset.
##
## Run: godot --headless --path client res://tests/walk_locomotion_test.tscn

const FLAG := "WAR_WALK_CYCLE"
const RECIPE_PATH := "res://recipes/wanderer.json"
const DRIVEN_BONES := [
	"thigh_l", "thigh_r",
	"calf_l", "calf_r",
	"upperarm_l", "upperarm_r",
]
const POSE_EPSILON := 0.00001
## Separate imported skeleton instances can reconstruct an equivalent local
## pose with sub-degree quaternion dust. A quarter degree is invisible beside
## the 18-24 degree gait channels and still catches a meaningful phase drift.
const CROSS_BODY_EPSILON := 0.004363323
const MIN_SWING_DEG := 4.0
const MIN_KNEE_FLEX_DEG := 3.0

var _had_flag := false
var _original_flag := ""
var _recipe: Dictionary = {}


func _ready() -> void:
	_had_flag = OS.has_environment(FLAG)
	_original_flag = OS.get_environment(FLAG)
	var loaded = CharacterFactory.load_recipe(RECIPE_PATH)
	if not (loaded is Dictionary):
		_fail("could not load %s" % RECIPE_PATH)
		return
	_recipe = loaded

	if not _check_default_off():
		return
	if not await _check_real_player_hook():
		return
	if not _check_opt_in_gait():
		return
	if not _check_distance_drives_phase():
		return
	if not _check_non_walk_states_restore_rest():
		return
	if not _check_seamless_and_deterministic():
		return

	_restore_flag()
	print("TEST PASS — walk locomotion is default-off, distance-driven and deterministic; grounded walk moves opposed limbs while stop/sprint/air restore rest")
	get_tree().quit(0)


## 1. Removing the flag gate makes this fail: a plain shipped boot would move
## limb poses after one walk update.
func _check_default_off() -> bool:
	var subject := _player_with_flag("")
	if subject.is_empty():
		return false
	var player: Player = subject["player"]
	var skeleton: Skeleton3D = subject["skeleton"]
	var animator: Node = subject["animator"]
	var before := _snapshot(skeleton)
	animator.call("advance_motion", Player.WALK_SPEED, true, false, 0.25)
	var after := _snapshot(skeleton)
	player.free()
	return _same_pose(before, after,
		"flag unset: ordinary movement changed the shipped skeleton pose")


## 2. Deleting the call from Player._physics_process makes this fail: the
## capsule travels under real input while the recipe skeleton stays at rest.
func _check_real_player_hook() -> bool:
	var floor := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20.0, 0.2, 20.0)
	floor_shape.shape = box
	floor_shape.position.y = -0.1
	floor.add_child(floor_shape)
	add_child(floor)

	var subject := _player_with_flag("1")
	if subject.is_empty():
		floor.free()
		return false
	var player: Player = subject["player"]
	var skeleton: Skeleton3D = subject["skeleton"]
	player.set_physics_process(true)
	player.global_position = Vector3(0.0, 0.02, 0.0)
	for _i in 4:
		await get_tree().physics_frame
	var before_position := player.global_position
	var before_pose := _snapshot(skeleton)

	Input.action_press("move_forward")
	for _i in 8:
		await get_tree().physics_frame
	Input.action_release("move_forward")
	var travelled := Vector2(
		player.global_position.x - before_position.x,
		player.global_position.z - before_position.z).length()
	var after_pose := _snapshot(skeleton)
	_free_subject(subject)
	floor.free()
	if travelled < 0.05:
		return _fail("real Player input moved only %.4f m — the runtime gait path was not exercised" % travelled)
	if _same_pose(before_pose, after_pose, ""):
		return _fail("real Player movement translated %.3f m but never drove the walk pose" % travelled)
	return true


## 3. Deleting any gait channel, making both sides swing together, or letting
## the arms follow rather than counter the legs makes this fail.
func _check_opt_in_gait() -> bool:
	var subject := _player_with_flag("1")
	if subject.is_empty():
		return false
	var player: Player = subject["player"]
	var skeleton: Skeleton3D = subject["skeleton"]
	var animator: Node = subject["animator"]
	animator.call("apply_phase", PI * 0.5)
	var offsets := _offset_angles(skeleton)
	player.free()

	var thigh_l: float = offsets["thigh_l"]
	var thigh_r: float = offsets["thigh_r"]
	var arm_l: float = offsets["upperarm_l"]
	var arm_r: float = offsets["upperarm_r"]
	if absf(thigh_l) < MIN_SWING_DEG or absf(thigh_r) < MIN_SWING_DEG:
		return _fail("opt-in quarter-cycle barely moves the thighs (%.2f, %.2f deg)" %
			[thigh_l, thigh_r])
	if signf(thigh_l) == signf(thigh_r):
		return _fail("left and right thighs swing together (%.2f, %.2f deg), not in opposition" %
			[thigh_l, thigh_r])
	if absf(arm_l) < MIN_SWING_DEG or absf(arm_r) < MIN_SWING_DEG:
		return _fail("opt-in quarter-cycle barely moves the arms (%.2f, %.2f deg)" %
			[arm_l, arm_r])
	if signf(arm_l) == signf(arm_r):
		return _fail("left and right arms swing together (%.2f, %.2f deg), not in opposition" %
			[arm_l, arm_r])
	if signf(arm_l) == signf(thigh_l) or signf(arm_r) == signf(thigh_r):
		return _fail("arms follow their same-side legs instead of counter-swinging")
	if maxf(absf(offsets["calf_l"]), absf(offsets["calf_r"])) < MIN_KNEE_FLEX_DEG:
		return _fail("neither knee flexes at the quarter-cycle")
	return true


## 4. Changing the driver from speed * delta to elapsed/render time makes these
## equal-distance paths disagree.
func _check_distance_drives_phase() -> bool:
	var slow := _player_with_flag("1")
	var fast := _player_with_flag("1")
	if slow.is_empty() or fast.is_empty():
		_free_subject(slow)
		_free_subject(fast)
		return false
	(slow["animator"] as Node).call("advance_motion", 3.0, true, false, 0.2)
	(fast["animator"] as Node).call("advance_motion", 6.0, true, false, 0.1)
	var a := _snapshot(slow["skeleton"])
	var b := _snapshot(fast["skeleton"])
	_free_subject(slow)
	_free_subject(fast)
	return _same_pose(a, b,
		"equal 0.6 m travel produced different poses — phase follows time or speed, not distance",
		CROSS_BODY_EPSILON)


## 5. Reusing the walk as fake sprint/jump motion, or failing to clear a gait
## when movement stops, leaves at least one driven pose away from rest.
func _check_non_walk_states_restore_rest() -> bool:
	var subject := _player_with_flag("1")
	if subject.is_empty():
		return false
	var skeleton: Skeleton3D = subject["skeleton"]
	var animator: Node = subject["animator"]
	var rest := _snapshot(skeleton)

	# 0.6 m is one quarter of the declared 2.4 m cycle: peak swing, not
	# either zero-crossing where a healthy gait deliberately equals rest.
	animator.call("advance_motion", Player.WALK_SPEED, true, false, 0.1)
	if _same_pose(rest, _snapshot(skeleton), ""):
		_free_subject(subject)
		return _fail("enabled grounded walk produced no pose change")
	animator.call("advance_motion", 0.0, true, false, 0.1)
	if not _same_pose(rest, _snapshot(skeleton), "stopping left a walk pose stuck on the body"):
		_free_subject(subject)
		return false

	animator.call("advance_motion", Player.WALK_SPEED, false, false, 0.2)
	if not _same_pose(rest, _snapshot(skeleton), "airborne movement reused the walk as a fake jump"):
		_free_subject(subject)
		return false

	animator.call("advance_motion", Player.SPRINT_SPEED, true, true, 0.2)
	if not _same_pose(rest, _snapshot(skeleton), "sprinting reused the walk as a fake run"):
		_free_subject(subject)
		return false
	_free_subject(subject)
	return true


## 6. A phase seam or non-deterministic clock/counter makes these literal
## comparisons disagree.
func _check_seamless_and_deterministic() -> bool:
	var a := _player_with_flag("1")
	var b := _player_with_flag("1")
	if a.is_empty() or b.is_empty():
		_free_subject(a)
		_free_subject(b)
		return false

	(a["animator"] as Node).call("apply_phase", 0.0)
	var at_zero := _snapshot(a["skeleton"])
	(a["animator"] as Node).call("apply_phase", TAU)
	if not _same_pose(at_zero, _snapshot(a["skeleton"]),
			"phase TAU differs from phase 0 — the gait has a visible loop seam"):
		_free_subject(a)
		_free_subject(b)
		return false

	for step in [[2.0, 0.15], [Player.WALK_SPEED, 0.08], [4.5, 0.12]]:
		(a["animator"] as Node).call("advance_motion", step[0], true, false, step[1])
		(b["animator"] as Node).call("advance_motion", step[0], true, false, step[1])
	var deterministic := _same_pose(_snapshot(a["skeleton"]), _snapshot(b["skeleton"]),
		"identical travel produced different gait poses on separate bodies",
		CROSS_BODY_EPSILON)
	_free_subject(a)
	_free_subject(b)
	return deterministic


func _player_with_flag(value: String) -> Dictionary:
	if value.is_empty():
		OS.unset_environment(FLAG)
	else:
		OS.set_environment(FLAG, value)
	var player := Player.new()
	add_child(player)
	# Direct gait laws drive the animator explicitly. The one runtime-hook test
	# opts physics back in; leaving every helper body live would let background
	# gravity/reset calls race the literal phase comparisons below.
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
			_fail("the shipped rig has no required walk bone %s" % bone_name)
			return {}
	var animator := player.get_node_or_null("WalkLocomotion")
	if animator == null:
		player.free()
		_fail("real Player path has no WalkLocomotion driver")
		return {}
	return { "player": player, "skeleton": skeleton, "animator": animator }


func _snapshot(skeleton: Skeleton3D) -> Dictionary:
	var result := {}
	for bone_name: String in DRIVEN_BONES:
		var bone := skeleton.find_bone(bone_name)
		var rest := skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
		var pose := skeleton.get_bone_pose_rotation(bone)
		# Compare the animation contribution, not two separately-instantiated
		# imported rests whose equivalent quaternions may differ by float dust.
		result[bone_name] = rest.inverse() * pose
	return result


## Signed local-X offsets from the authored rest, in degrees.
func _offset_angles(skeleton: Skeleton3D) -> Dictionary:
	var result := {}
	for bone_name: String in DRIVEN_BONES:
		var offset: Quaternion = _snapshot(skeleton)[bone_name]
		result[bone_name] = rad_to_deg(offset.get_euler().x)
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


func _free_subject(subject: Dictionary) -> void:
	if not subject.is_empty() and is_instance_valid(subject.get("player")):
		(subject["player"] as Player).free()


func _restore_flag() -> void:
	if _had_flag:
		OS.set_environment(FLAG, _original_flag)
	else:
		OS.unset_environment(FLAG)


func _fail(message: String) -> bool:
	Input.action_release("move_forward")
	Input.action_release("sprint")
	_restore_flag()
	push_error("walk_locomotion_test: " + message)
	get_tree().quit(1)
	return false
