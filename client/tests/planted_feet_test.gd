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
##     back under the hip exactly as far as the body travels, and on flat ground
##     each gait keeps a foot down for its whole geometric share of the cycle;
##  5. no phase of either gait moves a foot sideways;
##  6. the running knee never straightens;
##  7. the gaits lower the pelvis, and standing and jumping restore it;
##  8. a rig without the bones the solve needs loses the gaits but keeps the jump;
##  9. on a slope, a planted ankle stands its standing height above the ground
##     under it, still moves back exactly as far as the body travels, and each
##     gait keeps its whole flat-ground share of contact without bobbing the
##     pelvis, along or across the slope and with the body turned and scaled
##     (#909); ground that cannot be sampled, or that the body is not standing
##     on, leaves the flat-plane gait exactly as it was; ground that comes and
##     goes mid-stride eases the body instead of jumping it; and a body whose
##     root a leg-length push raised keeps its flat-ground gait.
## 10. standing still on a slope rests each ankle its standing height above the
##     ground under it, with the pelvis lowered by the deeper foot (#1638); on
##     flat ground, and where no ground is sampled, the standing pose is exactly
##     the rest pose; and walking off from it or stopping on it moves the feet
##     and pelvis no faster than the terrain plant eases.
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
## The contact-share check samples finer, and counts a foot as down within the
## same 1 cm the drive's contact line uses.
const CONTACT_SAMPLES := 400
const CONTACT_LIFT_M := 0.01
## The pelvis roll of the breathing idle still moves the hip joint itself by a few
## millimetres; a leg that followed the roll moved the ankle by centimetres.
const IDLE_TOLERANCE_M := 0.005
## The gait-change check walks at a fixed speed in fine ticks and watches the
## blend and a little past it.
const BLEND_SPEED := 8.0
const BLEND_DT := 1.0 / 120.0
const BLEND_WINDOW_S := 0.36
## The same 15% of body speed the gait is held to on the drive.
const MAX_BLEND_SLIP := 0.15
## The test slope rises this much per metre walked forward: about 15 degrees,
## steeper than most of the Reach, so a foot at the end of its stance stands
## more than ten centimetres off the body's own ground plane.
const SLOPE_RISE := 0.27
## Standing on a slope, an ankle rests within this of its standing height above
## the ground under it (#1638).
const STANDING_TOLERANCE_M := 0.01

var _flag_state: Dictionary = {}
var _recipe: Dictionary = {}


func _ready() -> void:
	_flag_state = TestEnvironment.snapshot([FLAG, RUN_FLAG])
	var fixture := LocomotionTestSupport.recipe_fixture(RECIPE_PATH)
	if not fixture["problem"].is_empty():
		_fail(fixture["problem"])
		return
	_recipe = fixture["recipe"]

	if not _check_foot_path():
		return
	if not _check_lift_off_phase():
		return
	if not _check_solver():
		return
	var subject := _bound_subject()
	if subject.is_empty():
		return
	var checks_passed: bool = (_check_planted_ankle(subject, false, "l")
		and _check_planted_ankle(subject, false, "r")
		and _check_planted_ankle(subject, true, "l")
		and _check_planted_ankle(subject, true, "r")
		and _check_contact_share(subject, false)
		and _check_contact_share(subject, true)
		and _check_toe_holds(subject, false, "l")
		and _check_toe_holds(subject, false, "r")
		and _check_toe_holds(subject, true, "l")
		and _check_toe_holds(subject, true, "r")
		and _check_idle_roll(subject)
		and _check_blend_holds(subject)
		and _check_no_sideways_step(subject)
		and _check_running_knee_bends(subject)
		and _check_pelvis_drop(subject)
		and _check_slope_plant(subject, false)
		and _check_slope_plant(subject, true)
		and _check_slope_plant(subject, false, true)
		and _check_slope_plant(subject, true, true)
		and _check_slope_plant(subject, true, false, true)
		and _check_unsampled_ground_keeps_plane(subject)
		and _check_ground_fades(subject)
		and _check_standing_plant(subject, true)
		and _check_standing_plant(subject, false, true)
		and _check_standing_plant(subject, true, true)
		and _check_standing_keeps_rest(subject)
		and _check_standing_hands_over(subject)
		and _check_long_legs_keep_plane())
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
func _check_planted_ankle(subject: Dictionary, running: bool, side: String = "l") -> bool:
	var animator: WalkLocomotion = subject["animator"]
	var skeleton: Skeleton3D = subject["skeleton"]
	var foot := skeleton.find_bone("foot_" + side)
	var rest_height := skeleton.get_bone_global_rest(foot).origin.y
	var forward: Vector3 = animator.get("_forward")
	var stride := WalkLocomotion.RUN_STRIDE_LENGTH_M if running else WalkLocomotion.STRIDE_LENGTH_M
	var stance := WalkLocomotion.stance_fraction(
		float(animator.get("_run_reach" if running else "_walk_reach")), stride)
	var gait := "run" if running else "walk"
	var ground_position := NAN
	# The left foot is down from (0.25 - stance) to 0.25 of the cycle; right foot is offset by half a cycle.
	for i in 9:
		var cycle := 0.25 + (0.5 if side == "r" else 0.0) - stance + stance * (0.05 + 0.9 * float(i) / 8.0)
		animator.apply_phase(TAU * cycle, running)
		var ankle := skeleton.get_bone_global_pose(foot).origin
		if absf(ankle.y - rest_height) > POSITION_EPSILON_M:
			return _fail("the %s's planted ankle (%s) sits %.4f m off its standing height at %.3f of the cycle" %
				[gait, side, ankle.y - rest_height, cycle])
		var over_ground := ankle.dot(forward) + cycle * stride
		if is_nan(ground_position):
			ground_position = over_ground
		elif absf(over_ground - ground_position) > POSITION_EPSILON_M:
			return _fail("the %s's planted foot (%s) slides %.4f m over the ground at %.3f of the cycle" %
				[gait, side, over_ground - ground_position, cycle])
	return true


## 4c. The foot keeps its standing orientation, so the toe holds the ground
## with the ankle. A foot left on the shin's rotation pitches about the ankle as
## the knee flexes, sweeping its heel or toe through the ground.
func _check_toe_holds(subject: Dictionary, running: bool, side: String = "l") -> bool:
	var animator: WalkLocomotion = subject["animator"]
	var skeleton: Skeleton3D = subject["skeleton"]
	var foot := skeleton.find_bone("foot_" + side)
	var toe := skeleton.find_bone("ball_" + side)
	var foot_rest := skeleton.get_bone_global_rest(foot).basis.get_rotation_quaternion()
	var toe_rest_height := skeleton.get_bone_global_rest(toe).origin.y
	var forward: Vector3 = animator.get("_forward")
	var stride := WalkLocomotion.RUN_STRIDE_LENGTH_M if running else WalkLocomotion.STRIDE_LENGTH_M
	var stance := WalkLocomotion.stance_fraction(
		float(animator.get("_run_reach" if running else "_walk_reach")), stride)
	var gait := "run" if running else "walk"
	var ground_position := NAN
	for i in 9:
		var cycle := 0.25 + (0.5 if side == "r" else 0.0) - stance + stance * (0.05 + 0.9 * float(i) / 8.0)
		animator.apply_phase(TAU * cycle, running)
		var turned := _angle_between(skeleton.get_bone_global_pose(foot).basis.get_rotation_quaternion(), foot_rest)
		if turned > 0.001:
			return _fail("the %s's planted foot (%s) pitches %.2f° off its standing orientation at %.3f of the cycle" %
				[gait, side, rad_to_deg(turned), cycle])
		var tip := skeleton.get_bone_global_pose(toe).origin
		if absf(tip.y - toe_rest_height) > POSITION_EPSILON_M:
			return _fail("the %s's planted toe (%s) sits %.4f m off its standing height at %.3f of the cycle" %
				[gait, side, tip.y - toe_rest_height, cycle])
		var over_ground := tip.dot(forward) + cycle * stride
		if is_nan(ground_position):
			ground_position = over_ground
		elif absf(over_ground - ground_position) > POSITION_EPSILON_M:
			return _fail("the %s's planted toe (%s) slides %.4f m over the ground at %.3f of the cycle" %
				[gait, side, over_ground - ground_position, cycle])
	return true


## 4d. The breathing idle rolls the pelvis to shift the body's weight. A planted
## leg must not follow the roll: it would swing the foot sideways across the
## ground. What remains is the hip joint moving a few millimetres with the pelvis.
func _check_idle_roll(subject: Dictionary) -> bool:
	var animator: WalkLocomotion = subject["animator"]
	var skeleton: Skeleton3D = subject["skeleton"]
	var pelvis := skeleton.find_bone("pelvis")
	var pelvis_rest := skeleton.get_bone_rest(pelvis).basis.get_rotation_quaternion()
	var foot := skeleton.find_bone("foot_l")
	var lateral: Vector3 = animator.get("_lateral")
	var stance := WalkLocomotion.stance_fraction(float(animator.get("_walk_reach")), WalkLocomotion.STRIDE_LENGTH_M)
	var worst := 0.0
	# The weight shift peaks a quarter and three quarters of the way round its loop.
	for t: float in [BreathingIdle.SHIFT_PERIOD * 0.25, BreathingIdle.SHIFT_PERIOD * 0.75]:
		for i in 5:
			var phase := TAU * (0.25 - stance + stance * (0.1 + 0.8 * float(i) / 4.0))
			skeleton.set_bone_pose_rotation(pelvis, pelvis_rest)
			animator.apply_phase(phase)
			var still := skeleton.get_bone_global_pose(foot).origin
			BreathingIdle.apply_at(skeleton, t)
			animator.apply_phase(phase)
			var rolled := skeleton.get_bone_global_pose(foot).origin
			worst = maxf(worst, (rolled - still).length())
	skeleton.set_bone_pose_rotation(pelvis, pelvis_rest)
	if worst > IDLE_TOLERANCE_M:
		return _fail("the breathing idle's pelvis roll moves a planted ankle %.4f m, more than the %.3f m the hip itself moves" %
			[worst, IDLE_TOLERANCE_M])
	print("idle: the weight shift moves a planted ankle at most %.4f m" % worst)
	return true


## 4e. Pressing or releasing sprint mid-stride must not skid a planted foot. Each
## gait's foot path holds the ground only while the phase advances at its own
## stride's rate, so through the blend it must advance at the blended stride.
## Measured the way the drive measures contact slip: over ticks where the same
## foot is down at both ends, how far it moves over the ground against how far
## the body moves.
func _check_blend_holds(subject: Dictionary) -> bool:
	var animator: WalkLocomotion = subject["animator"]
	var skeleton: Skeleton3D = subject["skeleton"]
	var forward: Vector3 = animator.get("_forward")
	var feet: Array[int] = [skeleton.find_bone("foot_l"), skeleton.find_bone("foot_r")]
	var rests: Array[float] = []
	for foot in feet:
		rests.append(skeleton.get_bone_global_rest(foot).origin.y)
	var travelled := 0.0
	var worst := 0.0
	var was_down := [false, false]
	var was_at := [0.0, 0.0]
	# A settled walk, then the sprint press and the release, each measured
	# across the blend and a little past it.
	for segment: Array in [[false, 1.0, false], [true, BLEND_WINDOW_S, true], [false, BLEND_WINDOW_S, true]]:
		var sprinting: bool = segment[0]
		var slip := 0.0
		var path := 0.0
		for _tick in int(float(segment[1]) / BLEND_DT):
			animator.advance_motion(BLEND_SPEED, true, sprinting, BLEND_DT)
			travelled += BLEND_SPEED * BLEND_DT
			for k in feet.size():
				var ankle := skeleton.get_bone_global_pose(feet[k]).origin
				var down: bool = ankle.y - rests[k] <= CONTACT_LIFT_M
				var at := ankle.dot(forward) + travelled
				if segment[2] and down and was_down[k]:
					slip += absf(at - float(was_at[k]))
					path += BLEND_SPEED * BLEND_DT
				was_down[k] = down
				was_at[k] = at
		if segment[2]:
			if path <= 0.0:
				return _fail("no foot stayed down through a gait change, so its slip was never measured")
			worst = maxf(worst, slip / path)
	animator.advance_motion(0.0, true, false, BLEND_DT)
	if worst > MAX_BLEND_SLIP:
		return _fail("a planted foot moves at %.0f%% of body speed through a gait change, above %.0f%%" %
			[worst * 100.0, MAX_BLEND_SLIP * 100.0])
	print("blend: a planted foot moves at most %.1f%% of body speed through a gait change" % (worst * 100.0))
	return true


## The angle between two rotations, exact near zero where `angle_to` is not.
func _angle_between(a: Quaternion, b: Quaternion) -> float:
	return LocomotionTestSupport.rotation_distance(a, b)


## 4b. On the body's own ground plane each gait keeps a foot down for its whole
## geometric share of the cycle: twice the stance, one foot at a time. Here, with
## no terrain, anything short of the share is the gait's own; check 9 holds the
## same share on a slope.
func _check_contact_share(subject: Dictionary, running: bool) -> bool:
	var animator: WalkLocomotion = subject["animator"]
	var skeleton: Skeleton3D = subject["skeleton"]
	var stride := WalkLocomotion.RUN_STRIDE_LENGTH_M if running else WalkLocomotion.STRIDE_LENGTH_M
	var stance := WalkLocomotion.stance_fraction(
		float(animator.get("_run_reach" if running else "_walk_reach")), stride)
	var feet := [skeleton.find_bone("foot_l"), skeleton.find_bone("foot_r")]
	var rests := feet.map(func(foot: int) -> float: return skeleton.get_bone_global_rest(foot).origin.y)
	var down := 0
	for i in CONTACT_SAMPLES:
		animator.apply_phase(TAU * float(i) / CONTACT_SAMPLES, running)
		for k in feet.size():
			if skeleton.get_bone_global_pose(feet[k]).origin.y - float(rests[k]) <= CONTACT_LIFT_M:
				down += 1
				break
	var share := float(down) / CONTACT_SAMPLES
	var bound := minf(2.0 * stance, 1.0)
	if share < bound - 2.0 / CONTACT_SAMPLES:
		return _fail("the %s keeps a foot down for %.1f%% of the cycle, short of its %.1f%% geometric share" %
			["run" if running else "walk", share * 100.0, bound * 100.0])
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


## 9a. On a slope the ground under a planted foot is not the body's own ground
## plane: ahead it is higher and behind it is lower. A foot planted on that plane
## sank into the uphill and hung over the downhill (#909). `across` tilts the
## slope sideways instead, so the two feet stand at different heights; `moved`
## turns, scales and lifts the body first, so a mix-up between skeleton and
## world space cannot pass.
func _check_slope_plant(subject: Dictionary, running: bool, across: bool = false, moved: bool = false) -> bool:
	var animator: WalkLocomotion = subject["animator"]
	var skeleton: Skeleton3D = subject["skeleton"]
	var body: Node3D = subject["body"]
	var kept := _place_body(body, moved)
	var to_world := skeleton.global_transform
	var forward: Vector3 = animator.get("_forward")
	var uphill: Vector3 = animator.get("_lateral") if across else forward
	var slope := _slope(skeleton, uphill)
	var stride := WalkLocomotion.RUN_STRIDE_LENGTH_M if running else WalkLocomotion.STRIDE_LENGTH_M
	var stance := WalkLocomotion.stance_fraction(
		float(animator.get("_run_reach" if running else "_walk_reach")), stride)
	var gait := "%s%s%s" % ["run" if running else "walk", " across the slope" if across else "",
		" (turned, scaled and lifted)" if moved else ""]
	var feet := [skeleton.find_bone("foot_l"), skeleton.find_bone("foot_r")]
	var pelvis := skeleton.find_bone("pelvis")
	var standing: Array[float] = []
	for foot: int in feet:
		standing.append((to_world * skeleton.get_bone_global_rest(foot).origin).y - to_world.origin.y)
	animator.ground_height = slope
	var problem := ""
	var deepest := 0.0
	for k in feet.size():
		var ground_position := NAN
		for i in 9:
			var cycle := 0.25 + (0.5 if k == 1 else 0.0) - stance + stance * (0.05 + 0.9 * float(i) / 8.0)
			animator.apply_phase(TAU * cycle, running)
			var local := skeleton.get_bone_global_pose(feet[k]).origin
			var ankle := to_world * local
			var off_plane := ankle.y - to_world.origin.y - standing[k]
			deepest = maxf(deepest, absf(off_plane))
			var clearance := ankle.y - float(slope.call(ankle.x, ankle.z))
			if absf(clearance - standing[k]) > POSITION_EPSILON_M:
				problem = "on a slope the %s's planted ankle sits %.4f m off its standing height above the ground at %.3f of the cycle" % [
					gait, clearance - standing[k], cycle]
				break
			var over_ground := local.dot(forward) + cycle * stride
			if is_nan(ground_position):
				ground_position = over_ground
			elif absf(over_ground - ground_position) > POSITION_EPSILON_M:
				problem = "on a slope the %s's planted foot slides %.4f m over the ground at %.3f of the cycle" % [
					gait, over_ground - ground_position, cycle]
				break
		if not problem.is_empty():
			break
	if problem.is_empty() and deepest < (0.02 if across else 0.05):
		problem = "the slope moved the %s's planted feet only %.4f m off the body's plane, so it tested nothing" % [gait, deepest]
	if problem.is_empty():
		var down := 0
		var pelvis_low := INF
		var pelvis_high := -INF
		for i in CONTACT_SAMPLES:
			animator.apply_phase(TAU * float(i) / CONTACT_SAMPLES, running)
			var hips := (to_world * skeleton.get_bone_global_pose(pelvis).origin).y
			pelvis_low = minf(pelvis_low, hips)
			pelvis_high = maxf(pelvis_high, hips)
			for k in feet.size():
				var ankle := to_world * skeleton.get_bone_global_pose(feet[k]).origin
				if ankle.y - float(slope.call(ankle.x, ankle.z)) - standing[k] <= CONTACT_LIFT_M:
					down += 1
					break
		var share := float(down) / CONTACT_SAMPLES
		var bound := minf(2.0 * stance, 1.0)
		# On an even slope the ground at the ends of each stance does not change
		# with the phase, so neither may the pelvis: following the swinging foot
		# bobbed it by over ten centimetres a step.
		if pelvis_high - pelvis_low > POSITION_EPSILON_M:
			problem = "on a slope the %s bobs the pelvis %.4f m over a cycle" % [gait, pelvis_high - pelvis_low]
		elif share < bound - 2.0 / CONTACT_SAMPLES:
			problem = "on a slope the %s keeps a foot down for %.1f%% of the cycle, short of its %.1f%% geometric share" % [
				gait, share * 100.0, bound * 100.0]
		else:
			print("slope: the %s keeps a foot down for %.1f%% of the cycle (share %.1f%%), its planted feet up to %.3f m off the body's plane" % [
				gait, share * 100.0, bound * 100.0, deepest])
	animator.ground_height = Callable()
	body.transform = kept
	return problem.is_empty() or _fail(problem)


## 9b. A sample with no ground — a cave, the terrain's edge — and ground the body
## is not standing on — a rock, a ruin — must leave the flat-plane gait exactly
## as it was, never half-planted against a height that is not the floor.
func _check_unsampled_ground_keeps_plane(subject: Dictionary) -> bool:
	var animator: WalkLocomotion = subject["animator"]
	var skeleton: Skeleton3D = subject["skeleton"]
	var origin := skeleton.global_transform.origin
	var bones := [skeleton.find_bone("pelvis"), skeleton.find_bone("foot_l"), skeleton.find_bone("foot_r")]
	var phases := [0.0, 0.7, 1.9, 3.3, 4.6, 5.8]
	var flat: Array[Vector3] = []
	animator.ground_height = Callable()
	for running: bool in [false, true]:
		for phase: float in phases:
			animator.apply_phase(phase, running)
			for bone: int in bones:
				flat.append(skeleton.get_bone_global_pose(bone).origin)
	var providers := _off_ground_providers(origin.y)
	var problem := ""
	for label: String in providers:
		animator.ground_height = providers[label]
		var n := 0
		for running: bool in [false, true]:
			for phase: float in phases:
				animator.apply_phase(phase, running)
				for bone: int in bones:
					if not skeleton.get_bone_global_pose(bone).origin.is_equal_approx(flat[n]) and problem.is_empty():
						problem = "with %s, the %s at phase %.1f moved off the flat-plane pose" % [
							label, "run" if running else "walk", phase]
					n += 1
	animator.ground_height = Callable()
	return problem.is_empty() or _fail(problem)


## Ground the feet must not plant on: none anywhere, ground well below the body
## (a ledge), and a sample that is not a height. Keyed by what each one is.
func _off_ground_providers(body_y: float) -> Dictionary:
	return {
		"no ground anywhere": func(_x: float, _z: float) -> float: return NAN,
		"ground well below the body": func(_x: float, _z: float) -> float: return body_y - 0.5,
		"not a number": func(_x: float, _z: float) -> Variant: return "high",
	}


## For a `moved` check, turn, scale and lift the body so a mix-up between
## skeleton and world space cannot pass. Returns the transform to put back.
func _place_body(body: Node3D, moved: bool) -> Transform3D:
	var kept := body.transform
	if moved:
		body.transform = Transform3D(Basis(Vector3.UP, 2.3).scaled(Vector3.ONE * 1.1), Vector3(3.0, 0.5, -2.0))
	return kept


## A plane through the body's own ground point that rises `SLOPE_RISE` per metre
## along the body's forward direction.
func _slope(skeleton: Skeleton3D, forward: Vector3) -> Callable:
	var to_world := skeleton.global_transform
	var uphill := to_world.basis * forward
	uphill.y = 0.0
	uphill = uphill.normalized()
	var origin := to_world.origin
	return func(x: float, z: float) -> float:
		return origin.y + SLOPE_RISE * ((x - origin.x) * uphill.x + (z - origin.z) * uphill.z)


## 9c. Ground that appears or disappears mid-stride — a cave mouth, the terrain's
## edge — eases the feet and pelvis between the terrain and the flat plane. A
## hard switch moved the pelvis by the whole downhill drop in one tick.
func _check_ground_fades(subject: Dictionary) -> bool:
	var animator: WalkLocomotion = subject["animator"]
	var skeleton: Skeleton3D = subject["skeleton"]
	var to_world := skeleton.global_transform
	var pelvis := skeleton.find_bone("pelvis")
	var slope := _slope(skeleton, animator.get("_forward") as Vector3)
	var none := func(_x: float, _z: float) -> float: return NAN
	# The most the eased drop may move in one tick, with a little room for the
	# gait's own channels.
	var limit := WalkLocomotion.MAX_GROUND_OFFSET_M * BLEND_DT / WalkLocomotion.GROUND_BLEND_SECONDS + POSITION_EPSILON_M
	animator.ground_height = slope
	animator.advance_motion(0.0, true, false, BLEND_DT)
	var worst := 0.0
	var sloped_drop := 0.0
	var problem := ""
	# Carried across the switches, which are the ticks this check is for.
	var previous := NAN
	for provider: Callable in [slope, none, slope]:
		animator.ground_height = provider
		for tick in int(0.4 / BLEND_DT):
			animator.advance_motion(BLEND_SPEED, true, false, BLEND_DT)
			var hips := (to_world * skeleton.get_bone_global_pose(pelvis).origin).y
			if not is_nan(previous):
				worst = maxf(worst, absf(hips - previous))
			previous = hips
		if provider == slope:
			sloped_drop = float(animator.get("_ground_lower"))
		elif not is_zero_approx(float(animator.get("_ground_lower"))):
			problem = "after the ground disappeared the pelvis kept %.4f m of terrain drop" % float(animator.get("_ground_lower"))
	animator.advance_motion(0.0, true, false, BLEND_DT)
	animator.ground_height = Callable()
	if problem.is_empty() and sloped_drop < 0.02:
		problem = "the slope lowered the walking pelvis only %.4f m, so the fade tested nothing" % sloped_drop
	if problem.is_empty() and worst > limit:
		problem = "the pelvis moved %.4f m in one tick as the ground came and went, above %.4f m" % [worst, limit]
	return problem.is_empty() or _fail(problem)


## 10a. Standing still on a slope, each foot rests its standing height above the
## ground under it (#1638), across the slope (the two feet at different heights)
## and along it, with the body turned, scaled and lifted as in 9a.
func _check_standing_plant(subject: Dictionary, across: bool, moved: bool = false) -> bool:
	var kept := _place_body(subject["body"], moved)
	var animator: WalkLocomotion = subject["animator"]
	var skeleton: Skeleton3D = subject["skeleton"]
	var slope := _slope(skeleton, animator.get("_lateral" if across else "_forward") as Vector3)
	var to_world := skeleton.global_transform
	var label := "standing %s the slope%s" % ["across" if across else "along", " (turned, scaled and lifted)" if moved else ""]
	var feet := [skeleton.find_bone("foot_l"), skeleton.find_bone("foot_r")]
	var standing: Array[float] = []
	for foot: int in feet:
		standing.append((to_world * skeleton.get_bone_global_rest(foot).origin).y - to_world.origin.y)
	animator.ground_height = slope
	for _tick in int(0.4 / BLEND_DT):
		animator.advance_motion(0.0, true, false, BLEND_DT)
	var problem := ""
	var apart := 0.0
	var error := 0.0
	var grounds: Array[float] = []
	for k in feet.size():
		var ankle := to_world * skeleton.get_bone_global_pose(feet[k]).origin
		var under := float(slope.call(ankle.x, ankle.z))
		grounds.append(under)
		var clearance := ankle.y - under
		error = maxf(error, absf(clearance - standing[k]))
		apart = maxf(apart, absf(ankle.y - to_world.origin.y - standing[k]))
		if absf(clearance - standing[k]) > STANDING_TOLERANCE_M and problem.is_empty():
			problem = "%s, the %s ankle sits %.4f m off its standing height above the ground under it" % [
				label, "right" if k == 1 else "left", clearance - standing[k]]
	if problem.is_empty() and across and absf(grounds[0] - grounds[1]) < 0.02:
		problem = "%s, the ground under the two feet differs only %.4f m, so it tested nothing" % [label, absf(grounds[0] - grounds[1])]
	if problem.is_empty() and across and apart < 0.01:
		problem = "%s, the feet moved only %.4f m off the body's plane, so it tested nothing" % [label, apart]
	if problem.is_empty():
		print("standing: %s, each ankle rests within %.2f mm of its standing height above the ground (feet up to %.3f m off the body's plane)" % [
			label, error * 1000.0, apart])
	animator.ground_height = Callable()
	animator.advance_motion(0.0, true, false, BLEND_DT)
	(subject["body"] as Node3D).transform = kept
	return problem.is_empty() or _fail(problem)


## 10b. On flat ground at the body's plane, with no ground, with ground the body
## is not standing on, and with no gait opted in, the standing pose is the rest
## pose bit for bit: the standing pose ships today.
func _check_standing_keeps_rest(subject: Dictionary) -> bool:
	var animator: WalkLocomotion = subject["animator"]
	var skeleton: Skeleton3D = subject["skeleton"]
	var origin := skeleton.global_transform.origin
	animator.ground_height = Callable()
	# Let any terrain plant left by an earlier check ease out first.
	for _tick in int(0.4 / BLEND_DT):
		animator.advance_motion(0.0, true, false, BLEND_DT)
	var rest: Array[Transform3D] = []
	for bone in skeleton.get_bone_count():
		rest.append(skeleton.get_bone_pose(bone))
	var providers := _off_ground_providers(origin.y)
	providers["flat ground"] = func(_x: float, _z: float) -> float: return origin.y
	var problem := ""
	for label: String in providers:
		animator.ground_height = providers[label]
		for _tick in 3:
			animator.advance_motion(0.0, true, false, BLEND_DT)
		for bone in skeleton.get_bone_count():
			if skeleton.get_bone_pose(bone) != rest[bone] and problem.is_empty():
				problem = "standing on %s moved the %s off the rest pose" % [label, skeleton.get_bone_name(bone)]
	# With neither gait opted in a slope changes nothing either.
	var slope := _slope(skeleton, animator.get("_lateral") as Vector3)
	animator.set("_walk_enabled", false)
	animator.set("_run_enabled", false)
	animator.ground_height = slope
	animator.advance_motion(0.0, true, false, BLEND_DT)
	for bone in skeleton.get_bone_count():
		if skeleton.get_bone_pose(bone) != rest[bone] and problem.is_empty():
			problem = "with no gait opted in, standing on a slope moved the %s" % skeleton.get_bone_name(bone)
	animator.set("_walk_enabled", true)
	animator.set("_run_enabled", true)
	animator.ground_height = Callable()
	animator.advance_motion(0.0, true, false, BLEND_DT)
	return problem.is_empty() or _fail(problem)


## 10c. Walking off from a planted stand and stopping on the slope again must not
## pop the feet or the pelvis. The gait's own first pose still snaps from the
## rest pose exactly as on flat ground (an unauthored transition), so what is
## bounded is the slope's share of each tick's move: the same sequence with no
## ground sampled is subtracted, leaving only the terrain plant, which may move
## no faster than its ease plus the ground passing under a moving foot.
func _check_standing_hands_over(subject: Dictionary) -> bool:
	var animator: WalkLocomotion = subject["animator"]
	var skeleton: Skeleton3D = subject["skeleton"]
	var to_world := skeleton.global_transform
	var slope := _slope(skeleton, animator.get("_lateral") as Vector3)
	var none := func(_x: float, _z: float) -> float: return NAN
	var bones := [skeleton.find_bone("pelvis"), skeleton.find_bone("foot_l"), skeleton.find_bone("foot_r")]
	var traces := {}
	for label: String in ["slope", "none"]:
		# Both runs start from the same settled rest pose.
		animator.ground_height = Callable()
		for _tick in int(0.4 / BLEND_DT):
			animator.advance_motion(0.0, true, false, BLEND_DT)
		animator.ground_height = slope if label == "slope" else none
		var trace: Array[Array] = []
		for speed: float in [0.0, BLEND_SPEED, 0.0]:
			for _tick in int(0.3 / BLEND_DT):
				animator.advance_motion(speed, true, false, BLEND_DT)
				var heights: Array[float] = []
				for bone: int in bones:
					heights.append((to_world * skeleton.get_bone_global_pose(bone).origin).y)
				trace.append(heights)
		traces[label] = trace
		animator.ground_height = Callable()
		animator.advance_motion(0.0, true, false, BLEND_DT)
	var ease := WalkLocomotion.MAX_GROUND_OFFSET_M * BLEND_DT / WalkLocomotion.GROUND_BLEND_SECONDS
	# The slope here runs across the body, so a foot moving forward stays at one
	# ground height; the bound is the ease alone, plus a millimetre.
	var limit := ease + POSITION_EPSILON_M
	var worst := 0.0
	var worst_at := ""
	var sloped: Array = traces["slope"]
	var plain: Array = traces["none"]
	for tick in range(1, sloped.size()):
		for n in bones.size():
			var share := absf((sloped[tick][n] - sloped[tick - 1][n]) - (plain[tick][n] - plain[tick - 1][n]))
			if share > worst:
				worst = share
				worst_at = "%s at tick %d" % [skeleton.get_bone_name(bones[n]), tick]
	if worst > limit:
		return _fail("starting or stopping on a slope moved the %s %.4f m in one tick beyond the flat-ground move, above %.4f m" % [
			worst_at, worst, limit])
	print("standing: walking off and stopping on a slope moves the feet and pelvis at most %.4f m a tick beyond flat ground (bound %.4f m)" % [worst, limit])
	return true


## 9d. A leg-length push raises the body root to keep the historical floor
## contact, so the root stands above the floor the soles touch. Flat ground at
## that floor must leave such a body's gait exactly as it is with no ground.
func _check_long_legs_keep_plane() -> bool:
	var recipe := _recipe.duplicate(true)
	# Versions before 5 refuse leg-length pushes.
	recipe["version"] = 5
	recipe["joint_push"] = {"thigh": 1.05, "calf": 1.05}
	var body := CharacterFactory.build(recipe)
	if body == null:
		return _fail("could not build a leg-length-pushed %s" % RECIPE_PATH)
	add_child(body)
	var animator := WalkLocomotion.new()
	add_child(animator)
	animator.bind(body)
	var skeleton := CharacterFactory.find_skeleton(body)
	var lift := body.position.y
	var problem := "" if lift > 0.01 else "the pushed legs lifted the body root only %.4f m, so this tested nothing" % lift
	var bones := [skeleton.find_bone("pelvis"), skeleton.find_bone("foot_l"), skeleton.find_bone("foot_r")]
	var floor_y := body.global_transform.origin.y - lift
	var flat := func(_x: float, _z: float) -> float: return floor_y
	for running: bool in [false, true]:
		for phase: float in [0.0, 1.2, 2.6, 4.1, 5.5]:
			animator.ground_height = Callable()
			animator.apply_phase(phase, running)
			var expected: Array[Vector3] = []
			for bone: int in bones:
				expected.append(skeleton.get_bone_global_pose(bone).origin)
			animator.ground_height = flat
			animator.apply_phase(phase, running)
			for n in bones.size():
				var moved := skeleton.get_bone_global_pose(bones[n]).origin.distance_to(expected[n])
				if moved > POSITION_EPSILON_M and problem.is_empty():
					problem = "flat ground at the floor moved a long-legged body's %s %.4f m in the %s" % [
						skeleton.get_bone_name(bones[n]), moved, "run" if running else "walk"]
	animator.free()
	body.free()
	return problem.is_empty() or _fail(problem)


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
	TestEnvironment.restore(_flag_state)


func _fail(message: String) -> bool:
	_restore_flags()
	print("TEST FAIL — " + message)
	push_error("planted_feet_test: " + message)
	get_tree().quit(1)
	return false
