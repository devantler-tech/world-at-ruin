extends Node
## Regression test for the grounded locomotion slices (#402 walk, #481 run;
## both part of #224).
##
## The player already moves through the world, but the recipe-built skeleton
## stays in its standing pose. This test exercises the real Player ->
## CharacterFactory wiring and holds both authored gaits:
##
##  1. DEFAULT-OFF — ordinary movement does not touch the shipped pose; each gait
##     answers to its OWN opt-in, so a walk tester is never enrolled in the run.
##  2. OPT-IN — grounded non-sprint travel drives opposing legs, counter-swung
##     arms, and a flexed knee.
##  3. DISTANCE-DRIVEN — equal travelled distances land on the same pose even
##     when speed and delta differ.
##  4. HONEST STATES — stop and airborne restore the standing pose; the gaits do
##     not impersonate the jump work still missing.
##  5. SPRINT RUNS — sprinting poses the run rather than restoring rest, and the
##     run is AUTHORED rather than the walk scaled up.
##  6. SEAMLESS + DETERMINISTIC — phase 0 and TAU agree, and identical travel
##     produces byte-equivalent bone rotations on separate player bodies.
##
## Each assertion names a real break: deleting the Player hook, inverting a
## limb, driving from render time, leaving a gait pose stuck at rest, reaching
## for the walk when the run is wanted, quietly redefining the run as the walk
## times a constant, or silently enrolling players with the flag unset.
##
## Run: godot --headless --path client res://tests/walk_locomotion_test.tscn

const FLAG := "WAR_WALK_CYCLE"
const RUN_FLAG := "WAR_RUN_CYCLE"
const RECIPE_PATH := "res://recipes/wanderer.json"
const DRIVEN_BONES := [
	"thigh_l", "thigh_r",
	"calf_l", "calf_r",
	"upperarm_l", "upperarm_r",
	"lowerarm_l", "lowerarm_r",
]
const POSE_EPSILON := 0.00001
## Separate imported skeleton instances can reconstruct an equivalent local
## pose with sub-degree quaternion dust. A quarter degree is invisible beside
## the 18-24 degree gait channels and still catches a meaningful phase drift.
const CROSS_BODY_EPSILON := 0.004363323
const MIN_SWING_DEG := 4.0
const MIN_KNEE_FLEX_DEG := 3.0
## Phases sampled when comparing the two gaits as pure functions. Coprime with
## the quarter-cycle landmarks so the sweep cannot sit only on zero-crossings,
## where a scaled walk and the run would agree by construction.
const GAIT_SAMPLES := 37
## The run's elbow carriage must read from a distance, not merely differ from
## zero by float dust.
const MIN_ELBOW_CARRIAGE_DEG := 20.0
## How far apart two channels' run/walk ratios must sit before the run is
## provably not the walk times a constant.
const MIN_RATIO_SPREAD := 0.25
## Most of the walk's phase the run may turn through over the same ground. The
## stride ratio 2.4/3.6 puts the real gaits at 0.71 (sin 30 over sin 45), and
## equal strides put them at 1.0, so the floor sits between the two rather than
## at the tie where float dust decides.
const MAX_RUN_PHASE_SHARE := 0.85

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
	if not _check_sprint_runs():
		return
	if not _check_gaits_are_independently_opt_in():
		return
	if not _check_run_is_authored_not_scaled():
		return
	if not _check_run_stride_is_longer():
		return
	if not _check_seamless_and_deterministic():
		return

	_restore_flag()
	print("TEST PASS — grounded locomotion is default-off, distance-driven and deterministic; walk and run each pose opposed limbs, sprint runs on an authored gait that is not the walk scaled, and stop/air restore rest")
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


## 5. Reusing a gait as fake jump motion, or failing to clear one when movement
## stops, leaves at least one driven pose away from rest.
##
## Sprint is deliberately NOT in this list any more (#481): it now selects the
## run. Airborne stays, because the jump pose is still unwritten — that is the
## honest-state law this assertion exists to keep, and #224's remaining jump
## criterion depends on it not quietly lapsing.
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

	_free_subject(subject)
	return true


## 6. Restoring the old `or sprinting` suppression, or dropping the run gait,
## puts the fastest state the wanderer has back on the standing pose.
func _check_sprint_runs() -> bool:
	var subject := _player_with_flag("1")
	if subject.is_empty():
		return false
	var skeleton: Skeleton3D = subject["skeleton"]
	var animator: Node = subject["animator"]
	var rest := _snapshot(skeleton)

	animator.call("advance_motion", Player.SPRINT_SPEED, true, true, 0.1)
	if _same_pose(rest, _snapshot(skeleton), ""):
		_free_subject(subject)
		return _fail("sprinting left the standing pose on the body — the run gait is not driven")
	var offsets := _offset_angles(skeleton)
	_free_subject(subject)

	# The run's own shape, read off the real posed skeleton rather than the pure
	# function, so a driver that poses the wrong bones cannot pass on arithmetic.
	if signf(offsets["thigh_l"]) == signf(offsets["thigh_r"]):
		return _fail("running thighs swing together (%.2f, %.2f deg), not in opposition" %
			[offsets["thigh_l"], offsets["thigh_r"]])
	if signf(offsets["upperarm_l"]) == signf(offsets["thigh_l"]):
		return _fail("running arms follow their same-side legs instead of counter-swinging")
	var elbow := minf(offsets["lowerarm_l"], offsets["lowerarm_r"])
	if elbow < MIN_ELBOW_CARRIAGE_DEG:
		return _fail(("the run does not carry its elbows: the less-folded one sits at %.2f deg, " +
			"under the %.1f deg floor — a straight-armed run reads as a fast walk") %
			[elbow, MIN_ELBOW_CARRIAGE_DEG])
	if minf(offsets["calf_l"], offsets["calf_r"]) < MIN_KNEE_FLEX_DEG:
		return _fail("a running knee straightened to %.2f deg — the run has no planted phase" %
			minf(offsets["calf_l"], offsets["calf_r"]))
	return true


## 6b. Collapsing the two opt-ins back into one flag makes this fail.
##
## Product law 2: a player who set `WAR_WALK_CYCLE` consented to the WALK
## experiment. If the run rode that same flag, updating would silently enrol
## every existing walk tester into an unfinished run. So each gait is checked
## against its own flag, in both directions — walk-only must still reset on
## sprint exactly as it did before the run existed, and run-only must pose the
## run while leaving ordinary walking at rest.
func _check_gaits_are_independently_opt_in() -> bool:
	var walk_only := _player_with_flags("1", "")
	if walk_only.is_empty():
		return false
	var wsk: Skeleton3D = walk_only["skeleton"]
	var wan: Node = walk_only["animator"]
	var wrest := _snapshot(wsk)
	wan.call("advance_motion", Player.SPRINT_SPEED, true, true, 0.1)
	var sprint_posed_without_optin := not _same_pose(wrest, _snapshot(wsk), "")
	wan.call("advance_motion", Player.WALK_SPEED, true, false, 0.1)
	var walk_posed := not _same_pose(wrest, _snapshot(wsk), "")
	_free_subject(walk_only)
	if sprint_posed_without_optin:
		return _fail("WAR_WALK_CYCLE alone drove the run — a walk tester was enrolled into it silently")
	if not walk_posed:
		return _fail("WAR_WALK_CYCLE alone no longer drives the walk — the existing opt-in regressed")

	var run_only := _player_with_flags("", "1")
	if run_only.is_empty():
		return false
	var rsk: Skeleton3D = run_only["skeleton"]
	var ran: Node = run_only["animator"]
	var rrest := _snapshot(rsk)
	ran.call("advance_motion", Player.SPRINT_SPEED, true, true, 0.1)
	var run_posed := not _same_pose(rrest, _snapshot(rsk), "")
	ran.call("advance_motion", 0.0, true, false, 0.1)
	ran.call("advance_motion", Player.WALK_SPEED, true, false, 0.1)
	var walk_posed_without_optin := not _same_pose(rrest, _snapshot(rsk), "")
	_free_subject(run_only)
	if not run_posed:
		return _fail("WAR_RUN_CYCLE alone did not drive the run — the run has no opt-in of its own")
	if walk_posed_without_optin:
		return _fail("WAR_RUN_CYCLE alone drove the walk — the flags are not independent")
	return true


## 7. Redefining the run as the walk times a constant — the cheap fix this slice
## exists to refuse — makes these disagree.
##
## Held against the pure functions, so it is a statement about the AUTHORED
## gaits rather than about one sampled skeleton.
func _check_run_is_authored_not_scaled() -> bool:
	var walk_knee_floor := INF
	var run_knee_floor := INF
	var thigh_ratio := 0.0
	var calf_ratio := 0.0
	for i in GAIT_SAMPLES:
		var phase := TAU * float(i) / float(GAIT_SAMPLES)
		var walk: Dictionary = WalkLocomotion.angles(phase)
		var run: Dictionary = WalkLocomotion.run_angles(phase)

		# Law A — the elbow is a channel the walk does not have at all. A ratio
		# is undefined against zero, which is the strongest possible refutation
		# of "the run is the walk scaled".
		if absf(walk["lowerarm_l"]) > POSE_EPSILON or absf(walk["lowerarm_r"]) > POSE_EPSILON:
			return _fail("the walk drove an elbow (%.3f, %.3f deg) — the gaits no longer differ in channel"
				% [walk["lowerarm_l"], walk["lowerarm_r"]])
		if minf(absf(run["lowerarm_l"]), absf(run["lowerarm_r"])) < MIN_ELBOW_CARRIAGE_DEG:
			return _fail("the run's elbow carriage fell to %.2f deg at phase %.2f" %
				[minf(absf(run["lowerarm_l"]), absf(run["lowerarm_r"])), phase])

		walk_knee_floor = minf(walk_knee_floor, minf(walk["calf_l"], walk["calf_r"]))
		run_knee_floor = minf(run_knee_floor, minf(run["calf_l"], run["calf_r"]))

	# Law C — both channels at peak swing, where the walk's values are largest
	# and the division is least sensitive to float dust. A fixed phase rather
	# than whichever sample the sweep happened to end on.
	var peak_walk: Dictionary = WalkLocomotion.angles(PI * 0.5)
	var peak_run: Dictionary = WalkLocomotion.run_angles(PI * 0.5)
	if peak_walk["thigh_l"] > 1.0:
		thigh_ratio = peak_run["thigh_l"] / peak_walk["thigh_l"]
	if peak_walk["calf_l"] > 1.0:
		calf_ratio = peak_run["calf_l"] / peak_walk["calf_l"]

	# Law B — the walk straightens a knee somewhere in its cycle and the run
	# never does. A scaled walk would straighten at exactly the same phase.
	if walk_knee_floor > MIN_KNEE_FLEX_DEG:
		return _fail("the walk's knee never straightened (floor %.2f deg) — the control for law B is vacuous"
			% walk_knee_floor)
	if run_knee_floor < MIN_KNEE_FLEX_DEG:
		return _fail(("a running knee straightened to %.2f deg — the run reached the walk's planted " +
			"pose, so the gaits differ only in size") % run_knee_floor)

	if thigh_ratio <= 0.0 or calf_ratio <= 0.0:
		return _fail("the run/walk ratios were never sampled (thigh %.3f, calf %.3f)" %
			[thigh_ratio, calf_ratio])
	if absf(thigh_ratio - calf_ratio) < MIN_RATIO_SPREAD:
		return _fail(("the run is the walk times a constant: thigh scales %.2fx and knee %.2fx, " +
			"within the %.2f spread that would make one factor fit both") %
			[thigh_ratio, calf_ratio, MIN_RATIO_SPREAD])
	return true


## 8. Shortening the run's stride to the walk's turns sprint speed into a
## blur of steps rather than longer ground-covering strides.
func _check_run_stride_is_longer() -> bool:
	var walking := _player_with_flag("1")
	var running := _player_with_flag("1")
	if walking.is_empty() or running.is_empty():
		_free_subject(walking)
		_free_subject(running)
		return false
	# Same distance travelled, different gait: the run must have turned through
	# LESS of its cycle, because each of its cycles covers more ground.
	#
	# 0.3 m is a quarter of the walk's cycle only by accident of arithmetic —
	# what matters is that it lands the walk at 45 deg of phase, on the STEEP
	# part of the sine. Sampling at the 90 deg peak instead makes this assertion
	# vacuous: both gaits saturate at a normalised swing of 1.0, so equalising
	# the strides changes nothing and the ablation passes. (It did.)
	(walking["animator"] as Node).call("advance_motion", 6.0, true, false, 0.05)
	(running["animator"] as Node).call("advance_motion", 6.0, true, true, 0.05)
	var walk_swing := absf((_offset_angles(walking["skeleton"]))["thigh_l"] /
		WalkLocomotion.THIGH_SWING_DEG)
	var run_swing := absf((_offset_angles(running["skeleton"]))["thigh_l"] /
		WalkLocomotion.RUN_THIGH_SWING_DEG)
	_free_subject(walking)
	_free_subject(running)
	# A margin, not `>=`: equal strides land both on the same normalised swing,
	# and float dust alone would otherwise let that tie slip through as a pass.
	if run_swing > walk_swing * MAX_RUN_PHASE_SHARE:
		return _fail(("the run advanced its phase nearly as fast as the walk over the same 0.3 m " +
			"(normalised swing %.4f vs %.4f, over the %.2f share) — its stride is not longer") %
			[run_swing, walk_swing, MAX_RUN_PHASE_SHARE])
	return true


## 9. A phase seam or non-deterministic clock/counter makes these literal
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


## Both gaits opted in (or both out) — what most laws below want, since they
## exercise one gait at a time and care only that it is enabled.
func _player_with_flag(value: String) -> Dictionary:
	return _player_with_flags(value, value)


## Independent opt-in, for the laws that are ABOUT the flags.
func _player_with_flags(walk_value: String, run_value: String) -> Dictionary:
	for pair: Array in [[FLAG, walk_value], [RUN_FLAG, run_value]]:
		if (pair[1] as String).is_empty():
			OS.unset_environment(pair[0] as String)
		else:
			OS.set_environment(pair[0] as String, pair[1] as String)
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
	if _had_run_flag:
		OS.set_environment(RUN_FLAG, _original_run_flag)
	else:
		OS.unset_environment(RUN_FLAG)


func _fail(message: String) -> bool:
	Input.action_release("move_forward")
	Input.action_release("sprint")
	_restore_flag()
	push_error("walk_locomotion_test: " + message)
	get_tree().quit(1)
	return false
