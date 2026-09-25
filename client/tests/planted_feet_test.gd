extends Node
## Regression test for planted feet (#904, part of #890).
##
## The walk and run solve each leg so a foot that is down holds the ground while
## the body passes over it. This test pins that on the pure path and solver and
## on the shipped wanderer rig:
##  1. a foot's path is continuous, and it leaves and meets the ground standing
##     still over it, so it never skids at lift-off or touchdown;
##  2. the left foot lifts at a quarter phase and the right half a cycle later;
##  3. the solver puts an ankle where it was asked, with the knee bending forward;
##  4. on the real rig, a planted ankle stays at its standing height and moves
##     back under the hip exactly as far as the body travels;
##  5. no phase of either gait moves a foot sideways;
##  6. the running knee never straightens;
##  7. the gaits lower the pelvis, and standing and jumping restore it;
##  8. a rig without the bones the solve needs loses the gaits but keeps the jump.
##
## Run: godot --headless --path client res://tests/planted_feet_test.tscn

const FLAG := "WAR_WALK_CYCLE"
const RUN_FLAG := "WAR_RUN_CYCLE"
const RECIPE_PATH := "res://recipes/wanderer.json"
## A millimetre: the solver is exact, so anything above this is a real error.
const POSITION_EPSILON_M := 0.001
## A planted running knee is solved to at least 28 degrees at the ends of
## contact; below this it has straightened.
const MIN_RUN_KNEE_FLEX_DEG := 20.0
const PHASE_SAMPLES := 48

var _had_flag := false
var _original_flag := ""
var _had_run_flag := false
var _original_run_flag := ""
var _recipe: Dictionary = {}


func _ready() -> void:
	_had_flag = OS.has_environment(FLAG)
	_original_flag = OS.get_environment(FLAG)
	_had_run_flag = OS.has_environment(RUN_FLAG)
	_original_run_flag = OS.get_environment(RUN_FLAG)
	var loaded = CharacterFactory.load_recipe(RECIPE_PATH)
	if not (loaded is Dictionary):
		_fail("could not load %s" % RECIPE_PATH)
		return
	_recipe = loaded

	if not _check_foot_path():
		return
	if not _check_lift_off_phase():
		return
	if not _check_solver():
		return
	var subject := _bound_subject()
	if subject.is_empty():
		return
	var checks_passed: bool = (_check_planted_ankle(subject, false)
		and _check_planted_ankle(subject, true)
		and _check_no_sideways_step(subject)
		and _check_running_knee_bends(subject)
		and _check_pelvis_drop(subject))
	(subject["body"] as Node).free()
	(subject["animator"] as Node).free()
	if not checks_passed:
		return
	if not _check_incomplete_rig_keeps_jump():
		return

	_restore_flags()
	print("TEST PASS — planted feet hold the ground: a down foot stays at its standing height and moves back exactly as far as the body travels, never sideways, lifting and landing without a skid; the run's knee stays bent, and a rig that cannot plant keeps its jump")
	get_tree().quit(0)


## 1. A straight-line swing that ignores the stance's speed skids the foot as it
## lifts and lands; a path with a jump in it teleports the foot.
func _check_foot_path() -> bool:
	for gait: Array in [[0.25, 0.3, 0.09], [0.19, 0.34, 0.2]]:
		var stance: float = gait[0]
		var reach: float = gait[1]
		var clearance: float = gait[2]
		var stance_speed := -2.0 * reach / stance
		var start := WalkLocomotion.foot_path(0.0, stance, reach, clearance)
		var lift := WalkLocomotion.foot_path(stance, stance, reach, clearance)
		var land := WalkLocomotion.foot_path(1.0, stance, reach, clearance)
		if not start.is_equal_approx(Vector2(reach, 0.0)) \
				or not lift.is_equal_approx(Vector2(-reach, 0.0)) \
				or not land.is_equal_approx(Vector2(reach, 0.0)):
			return _fail("the foot path is not closed: lands at %s, lifts at %s, returns to %s" %
				[start, lift, land])
		var step := 0.0001
		var leaving := (WalkLocomotion.foot_path(stance + step, stance, reach, clearance).x - lift.x) / step
		var arriving := (land.x - WalkLocomotion.foot_path(1.0 - step, stance, reach, clearance).x) / step
		# The stance carries the foot back under the hip at the body's speed, so a
		# foot standing still over the ground moves at exactly that rate here.
		if absf(leaving - stance_speed) > 0.02 * absf(stance_speed) \
				or absf(arriving - stance_speed) > 0.02 * absf(stance_speed):
			return _fail(("a foot skids at the ends of its swing: it moves at %.3f leaving and %.3f " +
				"arriving, not the stance's %.3f") % [leaving, arriving, stance_speed])
		var top := WalkLocomotion.foot_path(stance + 0.5 * (1.0 - stance), stance, reach, clearance)
		if not is_equal_approx(top.y, clearance):
			return _fail("the swing tops out at %.3f m, not its %.3f m clearance" % [top.y, clearance])
		for i in 200:
			var u := float(i) / 200.0
			var here := WalkLocomotion.foot_path(u, stance, reach, clearance)
			var next := WalkLocomotion.foot_path(u + 0.005, stance, reach, clearance)
			if here.y < 0.0 or here.distance_to(next) > 0.05:
				return _fail("the foot path dips below the ground or jumps near u=%.3f (%s -> %s)" %
					[u, here, next])
	return true


## 2. The swung gait had the left leg furthest back at a quarter phase, and a
## fixed-phase capture names moments by phase; the solved gait keeps that meaning.
func _check_lift_off_phase() -> bool:
	for stance: float in [0.25, 0.19]:
		var left := WalkLocomotion.cycle_position(TAU * 0.25, stance, false)
		var right := WalkLocomotion.cycle_position(TAU * 0.75, stance, true)
		if not is_equal_approx(left, stance) or not is_equal_approx(right, stance):
			return _fail("feet do not lift at a quarter and three quarters of the cycle: left at u=%.3f, right at u=%.3f of stance %.2f" %
				[left, right, stance])
	return true


## 3. The law of cosines, read back through forward kinematics.
func _check_solver() -> bool:
	var upper := 0.39
	var lower := 0.40
	for target: Vector2 in [Vector2(0.0, -0.74), Vector2(0.3, -0.7), Vector2(-0.3, -0.7), Vector2(0.1, -0.5)]:
		var solved := WalkLocomotion.solve_leg(upper, lower, target)
		var knee := Vector2(upper * sin(solved.x), -upper * cos(solved.x))
		var ankle := knee + Vector2(lower * sin(solved.y), -lower * cos(solved.y))
		if ankle.distance_to(target) > POSITION_EPSILON_M:
			return _fail("the leg solve misses %s by %.4f m" % [target, ankle.distance_to(target)])
		if solved.x <= solved.y:
			return _fail("the knee bends backwards reaching %s (thigh %.1f deg, shin %.1f deg)" %
				[target, rad_to_deg(solved.x), rad_to_deg(solved.y)])
	return true


## 4. A planted ankle in skeleton space moves back by the distance the body
## travels and stays at its standing height; the world sees it stand still.
func _check_planted_ankle(subject: Dictionary, running: bool) -> bool:
	var animator: WalkLocomotion = subject["animator"]
	var skeleton: Skeleton3D = subject["skeleton"]
	var foot := skeleton.find_bone("foot_l")
	var rest_height := skeleton.get_bone_global_rest(foot).origin.y
	var forward: Vector3 = animator.get("_forward")
	var stride := WalkLocomotion.RUN_STRIDE_LENGTH_M if running else WalkLocomotion.STRIDE_LENGTH_M
	var stance := WalkLocomotion.stance_fraction(
		float(animator.get("_run_reach" if running else "_walk_reach")), stride)
	var gait := "run" if running else "walk"
	var ground_position := NAN
	# The left foot is down from (0.25 - stance) to 0.25 of the cycle.
	for i in 9:
		var cycle := 0.25 - stance + stance * (0.05 + 0.9 * float(i) / 8.0)
		animator.apply_phase(TAU * cycle, running)
		var ankle := skeleton.get_bone_global_pose(foot).origin
		if absf(ankle.y - rest_height) > POSITION_EPSILON_M:
			return _fail("the %s's planted ankle sits %.4f m off its standing height at %.3f of the cycle" %
				[gait, ankle.y - rest_height, cycle])
		var over_ground := ankle.dot(forward) + cycle * stride
		if is_nan(ground_position):
			ground_position = over_ground
		elif absf(over_ground - ground_position) > POSITION_EPSILON_M:
			return _fail("the %s's planted foot slides %.4f m over the ground at %.3f of the cycle" %
				[gait, over_ground - ground_position, cycle])
	return true


## 5. Turning a leg about a bone's own axis rather than the body's lateral one
## walked each foot sideways by centimetres per step.
func _check_no_sideways_step(subject: Dictionary) -> bool:
	var animator: WalkLocomotion = subject["animator"]
	var skeleton: Skeleton3D = subject["skeleton"]
	var lateral: Vector3 = animator.get("_lateral")
	for side: String in ["l", "r"]:
		var foot := skeleton.find_bone("foot_" + side)
		var rest := skeleton.get_bone_global_rest(foot).origin.dot(lateral)
		for running: bool in [false, true]:
			for i in PHASE_SAMPLES:
				animator.apply_phase(TAU * float(i) / PHASE_SAMPLES, running)
				var drift := skeleton.get_bone_global_pose(foot).origin.dot(lateral) - rest
				if absf(drift) > POSITION_EPSILON_M:
					return _fail("the %s moves foot_%s %.4f m sideways at sample %d" %
						["run" if running else "walk", side, drift, i])
	return true


## 6. The run's spring: its stance leg stops short of straight.
func _check_running_knee_bends(subject: Dictionary) -> bool:
	var animator: WalkLocomotion = subject["animator"]
	var skeleton: Skeleton3D = subject["skeleton"]
	for side: String in ["l", "r"]:
		var hip := skeleton.find_bone("thigh_" + side)
		var knee := skeleton.find_bone("calf_" + side)
		var ankle := skeleton.find_bone("foot_" + side)
		for i in PHASE_SAMPLES:
			animator.apply_phase(TAU * float(i) / PHASE_SAMPLES, true)
			var upper := skeleton.get_bone_global_pose(knee).origin - skeleton.get_bone_global_pose(hip).origin
			var lower := skeleton.get_bone_global_pose(ankle).origin - skeleton.get_bone_global_pose(knee).origin
			var flexion := rad_to_deg(upper.angle_to(lower))
			if flexion < MIN_RUN_KNEE_FLEX_DEG:
				return _fail("the run straightens its %s knee to %.1f deg of flexion at sample %d" %
					[side, flexion, i])
	return true


## 7. The pelvis channel: lowered while a gait moves, restored by standing still
## and by the jump, which is posed from standing height.
func _check_pelvis_drop(subject: Dictionary) -> bool:
	var animator: WalkLocomotion = subject["animator"]
	var skeleton: Skeleton3D = subject["skeleton"]
	var pelvis := skeleton.find_bone("pelvis")
	var rest_height := skeleton.get_bone_global_rest(pelvis).origin.y
	for gait: Array in [[false, WalkLocomotion.WALK_PELVIS_DROP_M], [true, WalkLocomotion.RUN_PELVIS_DROP_M]]:
		animator.apply_phase(0.3, gait[0])
		var drop := rest_height - skeleton.get_bone_global_pose(pelvis).origin.y
		if absf(drop - float(gait[1])) > POSITION_EPSILON_M:
			return _fail("the %s lowers the pelvis %.4f m, not %.4f m" %
				["run" if gait[0] else "walk", drop, gait[1]])
	animator.advance_motion(0.0, true, false, 0.016)
	if absf(skeleton.get_bone_global_pose(pelvis).origin.y - rest_height) > POSITION_EPSILON_M:
		return _fail("standing still leaves the pelvis lowered")
	animator.apply_phase(0.3, true)
	animator.apply_jump(Player.JUMP_VELOCITY)
	if absf(skeleton.get_bone_global_pose(pelvis).origin.y - rest_height) > POSITION_EPSILON_M:
		return _fail("the jump is posed from a lowered pelvis")
	return true


## 8. Without the pelvis and feet there is nothing to plant against; the gaits
## switch off, but the permanent airborne arc must still pose the body.
func _check_incomplete_rig_keeps_jump() -> bool:
	_set_flags()
	var body := Node3D.new()
	var skeleton := Skeleton3D.new()
	body.add_child(skeleton)
	add_child(body)
	for bone_name: String in WalkLocomotion.DRIVEN_BONES:
		skeleton.add_bone(bone_name)
	var animator := WalkLocomotion.new()
	add_child(animator)
	animator.bind(body)
	var bound: bool = animator.get("_skeleton") != null
	var gaits_on: bool = animator.get("_walk_enabled") or animator.get("_run_enabled")
	var thigh := skeleton.find_bone("thigh_l")
	animator.advance_motion(0.0, false, false, 0.016, Player.JUMP_VELOCITY)
	var jumped := not skeleton.get_bone_pose_rotation(thigh).is_equal_approx(Quaternion.IDENTITY)
	animator.free()
	body.free()
	if not bound or not jumped:
		return _fail("a rig that cannot plant a foot lost its jump")
	if gaits_on:
		return _fail("a rig that cannot plant a foot kept a grounded gait enabled")
	return true


func _bound_subject() -> Dictionary:
	_set_flags()
	var body := CharacterFactory.build(_recipe)
	if body == null:
		_fail("could not build %s" % RECIPE_PATH)
		return {}
	add_child(body)
	var animator := WalkLocomotion.new()
	add_child(animator)
	animator.bind(body)
	if not animator.get("_legs_ready") or not animator.get("_walk_enabled") or not animator.get("_run_enabled"):
		animator.free()
		body.free()
		_fail("the shipped rig did not bind with planted legs and both gaits")
		return {}
	return {"body": body, "animator": animator, "skeleton": CharacterFactory.find_skeleton(body)}


func _set_flags() -> void:
	OS.set_environment(FLAG, "1")
	OS.set_environment(RUN_FLAG, "1")


func _restore_flags() -> void:
	for pair: Array in [[FLAG, _had_flag, _original_flag], [RUN_FLAG, _had_run_flag, _original_run_flag]]:
		if pair[1]:
			OS.set_environment(pair[0], pair[2])
		else:
			OS.unset_environment(pair[0])


func _fail(message: String) -> bool:
	_restore_flags()
	print("TEST FAIL — " + message)
	push_error("planted_feet_test: " + message)
	get_tree().quit(1)
	return false
