class_name WalkLocomotion
extends Node
## The wanderer's recipe-skeleton motion: walk, run, and an airborne arc.
##
## The controller owns translation and this node owns only the recipe-built
## skeleton pose. Phase advances from horizontal DISTANCE, not elapsed render
## time, so a stride follows travel at every input strength and two machines
## moving the same distance pose the same body.
##
## ## The run is authored, not the walk played faster
##
## Sprint is the default travel verb, so it is on screen for most of a session.
## Scaling the walk's amplitudes would be the wrong run: a run differs from a
## walk in SHAPE, not size, and two things carry that difference.
##
## 1. THE ELBOWS BEND. The walk holds the arms straight and swings them from the
##    shoulder; a run carries them folded and drives them. `lowerarm_l/r` is a
##    channel the walk does not touch at all, which is why the run cannot be
##    mistaken for a louder walk.
## 2. THE KNEES NEVER STRAIGHTEN. The walk's planted leg stretches to
##    [constant WALK_LEG_REACH] of its length at the ends of contact; the run's
##    stops at [constant RUN_LEG_REACH], so its stance knee stays bent even as a
##    foot lands and leaves — the running leg's spring — and its pelvis rides
##    lower.
##
## The arm half is why [method run_angles] is not [method angles] times a
## constant, and `walk_locomotion_test` asserts exactly that rather than trusting
## the wording.
##
## ## Planted feet
##
## A leg is solved, not swung (#890). Each foot follows [method foot_path]:
## while it is down it stays where it landed as the body passes over it, and in
## swing it is carried forward on an arc, leaving and meeting the ground without
## skidding. The thigh and knee angles are whatever put the ankle there
## ([method solve_leg]), turned about the body's lateral axis so a stride never
## walks a foot sideways, over a pelvis lowered by [constant WALK_PELVIS_DROP_M] or
## [constant RUN_PELVIS_DROP_M].
##
## How long a foot stays down is geometry, not a choice. A planted foot sweeps
## back under the hip by exactly the distance the body covers while it is down,
## and a leg only reaches so far, so [method stance_fraction] is derived at bind
## from the rig's leg length and that pelvis height: about a quarter of each cycle
## per foot at the walk and a fifth at the run. At 6 and 10.5 m/s with these
## strides, that leaves both gaits a flight phase, which is how a body actually
## moves at those speeds.
##
## ## Speed comes from stride length, not cadence
##
## [constant RUN_STRIDE_LENGTH_M] is longer than [constant STRIDE_LENGTH_M], so
## going 75% faster raises the step rate only ~17% (2.5 to 2.9 cycles/s at the
## two top speeds). Matching the walk's stride instead would have kept cadence
## proportional to speed and turned the run into a blur of 525 steps/min. People
## get faster mainly by covering more ground per step, and the eye knows it.
##
## ## What this still does not author
##
## The airborne slice is the ordinary jump: takeoff, apex, and descent follow
## the controller's actual vertical velocity. Landing still resets directly to
## the grounded state, with no anticipation, impact, directional lean or turn
## cue. Walk and run crossfade while both gait previews are opted in; stop,
## ground/air and jump transitions remain unauthored. There is also no vertical
## bob on the run's flight phase: bob is TRANSLATION, and this node poses a
## skeleton the controller moves. The feet plant on the body's own flat ground
## plane rather than the terrain under them, so on a slope a planted foot sits a
## little above or below the ground it is standing on.
##
## The class name is deliberately unchanged: the remaining opt-in flag and its
## retirement issue (#405) both name the walk, and renaming a class is a
## refactor that has no business riding along with a behaviour change.
##
## The grounded gaits remain experimental and default-off per product law:
## `WAR_WALK_CYCLE=1` opts into the walk and `WAR_RUN_CYCLE=1` opts into the
## run. One shared flag would silently enrol an existing gait tester into
## motion they did not choose. The accepted airborne arc is permanent and
## independent of both grounded previews.

const FLAG_ENV := "WAR_WALK_CYCLE"
const RUN_FLAG_ENV := "WAR_RUN_CYCLE"

## Walk↔run pose crossfade. Short enough to keep sprint input responsive, but
## long enough to show a dozen-plus intermediate frames at 60 Hz. Smoothstep is
## applied to this linear progress before the authored channels are mixed.
const GAIT_BLEND_SECONDS := 0.24

## Metres travelled per complete left/right cycle. The amplitude stays fixed
## while the cadence follows speed, avoiding short-input foot sliding without
## making slow analog input shrink into a shuffle.
const STRIDE_LENGTH_M := 2.4
const MIN_WALK_SPEED := 0.2

## Local-X swing on the shipped game-engine rig, in degrees.
const THIGH_SWING_DEG := 24.0
const ARM_SWING_DEG := 18.0
const KNEE_FLEX_DEG := 20.0

## Metres per cycle at a run. Longer than the walk's stride on purpose — see the
## cadence note in the class docs; shortening this to the walk's 2.4 m is what
## turns the run into a sprint-speed shuffle.
const RUN_STRIDE_LENGTH_M := 3.6

## Run swing amplitudes, in degrees. Larger than the walk's, but the amplitude
## is NOT what distinguishes the gaits — the elbow and knee channels below are.
const RUN_THIGH_SWING_DEG := 30.0
const RUN_ARM_SWING_DEG := 26.0

## Knee flex held even by the leg carrying weight. A run has no straight-legged
## planted phase, so this is a floor the swing rides on rather than a peak; at
## 0.0 the run's legs would pass through the walk's exact planted pose and the
## gaits would differ only in size.
const RUN_KNEE_BASE_DEG := 14.0
const RUN_KNEE_SWING_DEG := 34.0

## Elbow carriage. 🔑 MEASURED on the shipped kit rather than reasoned (the
## #237/#243 lesson): a POSITIVE rotation of `lowerarm_l` about local RIGHT
## moves the hand +80 mm FORWARD and +82 mm UP per 30 degrees — elbow FLEXION.
## Unlike the clavicles, the sign is NOT mirrored between the sides: `lowerarm_r`
## at +30 moves its hand forward and up by the same amounts. So both elbows flex
## on the same sign, and a mirrored one would hyperextend an arm backwards.
##
## ⚠️ The value is bounded by where the HAND ends up, not by how a running elbow
## looks in isolation, because the shoulder swing and the elbow stack. This
## started at 70 degrees, which every test passed and the render refuted: the
## hand peaked 86 mm under the neck — at the chin, reading as a body touching
## its own face rather than running. Sweeping the constant against measured hand
## height put the peak at 221 mm under the neck here, which is mid-chest and
## where a runner actually carries. Retune it against a rendered frame, never
## against the number alone; the walk's hands peak 440 mm under the neck.
const RUN_ELBOW_FLEX_DEG := 42.0

## How much further the elbow closes as its arm drives forward. Small beside the
## carriage: the fold is what reads as a run, and this only stops it reading as
## a mannequin holding a fixed angle.
const RUN_ELBOW_PUMP_DEG := 7.0

## How far the pelvis sits below its standing height while each gait moves. It
## is what lets a planted leg reach far enough fore and aft to hold the ground
## (see "Planted feet" in the class docs).
const WALK_PELVIS_DROP_M := 0.06
const RUN_PELVIS_DROP_M := 0.10

## How far a swinging foot clears the ground at the top of its arc.
const WALK_FOOT_CLEARANCE_M := 0.09
const RUN_FOOT_CLEARANCE_M := 0.2

## The longest a leg is stretched, as a share of its full length. The walk
## nearly straightens its planted leg; the run never does — its stance knee
## stays bent even at the ends of contact, which is the running leg's spring.
const WALK_LEG_REACH := 0.995
const RUN_LEG_REACH := 0.97

## Bones the planted legs are solved against, beyond the eight that are posed:
## the pelvis carries the height channel and the feet set the ground and the
## body's forward direction.
const PLANT_BONES := ["pelvis", "foot_l", "foot_r", "ball_l"]
const ARM_BONES := ["upperarm_l", "upperarm_r", "lowerarm_l", "lowerarm_r"]

## The controller launches at 7.2 m/s. Clamping to that shipped envelope keeps
## a bad external velocity from folding the skeleton further while preserving a
## continuous, deterministic pose through the whole arc.
const JUMP_REFERENCE_SPEED := 7.2
const JUMP_TAKEOFF_ANGLES := {
	"thigh_l": -12.0,
	"thigh_r": 12.0,
	"calf_l": 18.0,
	"calf_r": 18.0,
	"upperarm_l": 8.0,
	"upperarm_r": -8.0,
	"lowerarm_l": 20.0,
	"lowerarm_r": 20.0,
}
const JUMP_APEX_ANGLES := {
	"thigh_l": 28.0,
	"thigh_r": -28.0,
	"calf_l": 52.0,
	"calf_r": 52.0,
	"upperarm_l": 0.0,
	"upperarm_r": 0.0,
	"lowerarm_l": 24.0,
	"lowerarm_r": 24.0,
}
const JUMP_DESCENT_ANGLES := {
	"thigh_l": 8.0,
	"thigh_r": -8.0,
	"calf_l": 16.0,
	"calf_r": 16.0,
	"upperarm_l": -8.0,
	"upperarm_r": 8.0,
	"lowerarm_l": 18.0,
	"lowerarm_r": 18.0,
}

const DRIVEN_BONES := [
	"thigh_l", "thigh_r",
	"calf_l", "calf_r",
	"upperarm_l", "upperarm_r",
	"lowerarm_l", "lowerarm_r",
]

var _walk_enabled := false
var _run_enabled := false
var _phase := 0.0
var _run_blend := 0.0
var _has_active_gait := false
var _skeleton: Skeleton3D = null

# The rig facts the planted legs are solved from, captured at bind.
var _legs_ready := false
var _lateral := Vector3.LEFT
var _forward := Vector3.BACK
var _pelvis := -1
var _pelvis_rest_origin := Vector3.ZERO
var _pelvis_parent_rest := Quaternion.IDENTITY
var _legs: Array[Dictionary] = []
var _walk_reach := 0.0
var _run_reach := 0.0


## Bind the driver to the newest recipe-built body. Character editing rebuilds
## that body in place, so the player keeps one driver and rebinds it.
func bind(body: Node3D) -> void:
	_skeleton = CharacterFactory.find_skeleton(body)
	_phase = 0.0
	_run_blend = 0.0
	_has_active_gait = false
	_walk_enabled = OS.get_environment(FLAG_ENV) == "1"
	_run_enabled = OS.get_environment(RUN_FLAG_ENV) == "1"
	if _skeleton == null:
		push_error("WalkLocomotion: character body has no skeleton")
		_walk_enabled = false
		_run_enabled = false
		return
	for bone_name: String in DRIVEN_BONES:
		if _skeleton.find_bone(bone_name) < 0:
			push_error("WalkLocomotion: rig has no bone %s" % bone_name)
			_walk_enabled = false
			_run_enabled = false
			_skeleton = null
			return
	# The grounded gaits need the planted-leg facts; the airborne arc does not,
	# so a rig lacking them loses only the gaits.
	_legs_ready = _capture_legs()
	if not _legs_ready:
		_walk_enabled = false
		_run_enabled = false


## Read the leg geometry the planted gait is solved from, all from the REST
## skeleton, so every body built from the same recipe solves identically.
## Everything happens in the body's sagittal plane: the forward direction is
## where the toes point, and each leg turns about the lateral axis through its
## hip, so solving can never move a foot sideways.
func _capture_legs() -> bool:
	for bone_name: String in PLANT_BONES:
		if _skeleton.find_bone(bone_name) < 0:
			push_error("WalkLocomotion: rig has no bone %s, so the gaits cannot plant a foot" % bone_name)
			return false
	var toes := (_skeleton.get_bone_global_rest(_skeleton.find_bone("ball_l")).origin
		- _skeleton.get_bone_global_rest(_skeleton.find_bone("foot_l")).origin)
	toes.y = 0.0
	if toes.length() < 0.001:
		push_error("WalkLocomotion: the rig's toes do not point anywhere, so it has no forward")
		return false
	_forward = toes.normalized()
	# A positive turn about this axis swings a leg forward.
	_lateral = _forward.cross(Vector3.UP).normalized()
	_pelvis = _skeleton.find_bone("pelvis")
	_pelvis_rest_origin = _skeleton.get_bone_rest(_pelvis).origin
	var pelvis_parent := _skeleton.get_bone_parent(_pelvis)
	_pelvis_parent_rest = (_skeleton.get_bone_global_rest(pelvis_parent).basis.get_rotation_quaternion()
		if pelvis_parent >= 0 else Quaternion.IDENTITY)
	_legs.clear()
	for side: String in ["l", "r"]:
		var thigh := _skeleton.find_bone("thigh_" + side)
		var calf := _skeleton.find_bone("calf_" + side)
		var foot := _skeleton.find_bone("foot_" + side)
		var hip := _skeleton.get_bone_global_rest(thigh).origin
		var knee := _skeleton.get_bone_global_rest(calf).origin
		var ankle := _skeleton.get_bone_global_rest(foot).origin
		var upper := _sagittal(knee - hip)
		var lower := _sagittal(ankle - knee)
		_legs.append({
			"thigh": thigh,
			"calf": calf,
			"foot": foot,
			"upper_m": upper.length(),
			"lower_m": lower.length(),
			"thigh_rest_angle": atan2(upper.x, -upper.y),
			"calf_rest_angle": atan2(lower.x, -lower.y),
			"hip_over_ankle_m": -_sagittal(ankle - hip).y,
			"thigh_rest": _skeleton.get_bone_rest(thigh).basis.get_rotation_quaternion(),
			"calf_rest": _skeleton.get_bone_rest(calf).basis.get_rotation_quaternion(),
			"foot_rest": _skeleton.get_bone_rest(foot).basis.get_rotation_quaternion(),
			# The frame the whole leg is solved in: the pelvis as it stands at rest.
			"hip_frame": _skeleton.get_bone_global_rest(_skeleton.get_bone_parent(thigh)).basis.get_rotation_quaternion(),
		})
	_walk_reach = _reach(WALK_PELVIS_DROP_M, WALK_LEG_REACH)
	_run_reach = _reach(RUN_PELVIS_DROP_M, RUN_LEG_REACH)
	if _walk_reach <= 0.0 or _run_reach <= 0.0:
		push_error("WalkLocomotion: the legs cannot reach the ground at the gait's pelvis height")
		return false
	return true


## A skeleton-space offset as (forward, up) in the body's sagittal plane.
func _sagittal(offset: Vector3) -> Vector2:
	return Vector2(offset.dot(_forward), offset.dot(Vector3.UP))


## How far fore and aft of the hip a planted foot can sit with the pelvis
## dropped by `drop`, on the shorter-reaching leg.
func _reach(drop: float, limit: float) -> float:
	var reach := INF
	for leg: Dictionary in _legs:
		var length := limit * (float(leg["upper_m"]) + float(leg["lower_m"]))
		var height := float(leg["hip_over_ankle_m"]) - drop
		reach = minf(reach, sqrt(maxf(length * length - height * height, 0.0)))
	return reach


## Whether any gait is opted in — the node has nothing to do when neither is.
func _any_gait_enabled() -> bool:
	return _walk_enabled or _run_enabled


## Advance from the controller's actual horizontal motion.
##
## `grounded` and `sprinting` are explicit inputs so neither gait can quietly
## become a placeholder for a state it does not author. `sprinting` SELECTS the
## run; leaving the ground suppresses both gaits and selects the permanent jump
## treatment.
##
## Each gait answers to its OWN flag. A player who opted into the walk gets
## exactly the pre-run behaviour — sprint returns to the standing pose — because
## `WAR_WALK_CYCLE` was consent to the walk experiment and not to this one
## (product law 2: nobody is silently enrolled into an unfinished experience).
func advance_motion(
		horizontal_speed: float,
		grounded: bool,
		sprinting: bool,
		delta: float,
		vertical_speed: float = 0.0) -> void:
	if _skeleton == null:
		return
	if not grounded:
		_phase = 0.0
		_has_active_gait = false
		apply_jump(vertical_speed)
		return
	if not _any_gait_enabled():
		_has_active_gait = false
		_reset_pose()
		return
	if horizontal_speed < MIN_WALK_SPEED:
		_phase = 0.0
		_has_active_gait = false
		_reset_pose()
		return
	# The gait this state needs, and whether its own flag is on. An un-opted-in
	# gait resets rather than borrowing the other one — the same honesty the
	# airborne state gets.
	if not (_run_enabled if sprinting else _walk_enabled):
		_phase = 0.0
		_has_active_gait = false
		_reset_pose()
		return
	var target_blend := 1.0 if sprinting else 0.0
	if not _has_active_gait:
		# There is no prior moving gait to blend from after a bind, stop, jump or
		# un-opted state. Snap the first active gait so steady walk/run behavior
		# stays exactly as authored; only a live gait CHANGE crossfades.
		_run_blend = target_blend
		_has_active_gait = true
	else:
		_run_blend = move_toward(
			_run_blend,
			target_blend,
			maxf(delta, 0.0) / GAIT_BLEND_SECONDS)
	var distance := maxf(horizontal_speed, 0.0) * maxf(delta, 0.0)
	# Phase is continuous across a gait change — the stride LENGTH changes, so
	# cadence changes without the legs jumping to a different point in the
	# cycle. Every pose channel crossfades from that shared phase, and the stride
	# crossfades with them: a planted foot holds the ground only while the phase
	# advances at the rate of the stride its path was drawn for, so during a
	# blend it must advance at the blend of the two.
	var weight := smoothstep(0.0, 1.0, _run_blend)
	var stride_length := lerpf(STRIDE_LENGTH_M, RUN_STRIDE_LENGTH_M, weight)
	_phase = fposmod(_phase + TAU * distance / stride_length, TAU)
	apply_blended_phase(_phase, weight)


## Pose one exact point on the airborne arc. Runtime and evidence capture share
## this method so a deterministic frame sequence cannot drift into preview-only
## animation. Positive speed blends from the compact apex to push-off; negative
## speed opens into a landing-ready descent.
func apply_jump(vertical_speed: float) -> void:
	if _skeleton == null:
		push_error("WalkLocomotion: cannot pose an unbound skeleton")
		return
	# The gaits lower the pelvis and turn the feet; the arc is posed from standing.
	_reset_plant()
	var angles := jump_angles(vertical_speed)
	for bone_name: String in DRIVEN_BONES:
		var bone := _skeleton.find_bone(bone_name)
		var rest_rotation := _skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
		_skeleton.set_bone_pose_rotation(
			bone,
			rest_rotation * Quaternion(Vector3.RIGHT, deg_to_rad(angles[bone_name])))


## Pure airborne angles for a vertical speed in metres per second.
static func jump_angles(vertical_speed: float) -> Dictionary:
	var travel := clampf(vertical_speed / JUMP_REFERENCE_SPEED, -1.0, 1.0)
	var target: Dictionary = JUMP_TAKEOFF_ANGLES if travel >= 0.0 else JUMP_DESCENT_ANGLES
	var weight := absf(travel)
	var result := {}
	for bone_name: String in DRIVEN_BONES:
		result[bone_name] = lerpf(
			JUMP_APEX_ANGLES[bone_name],
			target[bone_name],
			weight)
	return result


## Pose one exact phase. The fixed-phase evidence capture uses the same method
## as the runtime driver, so its frame sequence cannot drift into a preview-only
## implementation.
##
## `running` defaults to the walk so existing single-argument callers keep
## posing the gait they asked for.
func apply_phase(phase: float, running: bool = false) -> void:
	apply_blended_phase(phase, 1.0 if running else 0.0)


## Pose an interpolation between the authored walk and run at one shared phase.
## The runtime supplies an eased weight; keeping the interpolation itself pure
## makes every driven channel explicit, including the walk's zeroed elbows.
##
## The arms follow [method angles] and [method run_angles]. The legs are solved
## (see [method _pose_legs]); only a rig without the bones that solve needs
## falls back to the swung leg channels in those same tables.
func apply_blended_phase(phase: float, run_weight: float) -> void:
	if _skeleton == null:
		push_error("WalkLocomotion: cannot pose an unbound skeleton")
		return
	var at := fposmod(phase, TAU)
	var walk := angles(at)
	var run := run_angles(at)
	var weight := clampf(run_weight, 0.0, 1.0)
	for bone_name: String in (ARM_BONES if _legs_ready else DRIVEN_BONES):
		var bone := _skeleton.find_bone(bone_name)
		var rest_rotation := _skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
		var angle := lerpf(walk[bone_name], run[bone_name], weight)
		_skeleton.set_bone_pose_rotation(
			bone,
			rest_rotation * Quaternion(Vector3.RIGHT, deg_to_rad(angle)))
	if _legs_ready:
		_pose_legs(at, weight)


## Plant the feet: lower the pelvis, then turn each thigh and knee about the
## body's lateral axis so its ankle lands where [method foot_path] puts it. The
## walk and run are each solved and their angles crossfaded, so a gait change
## blends exactly as the arms do.
##
## Each leg is solved in the pelvis's REST frame and then carried into the frame
## the pelvis stands in now. The breathing idle rolls the pelvis to shift the
## body's weight; a leg that followed that roll would swing its planted foot
## sideways, so the leg counter-rotates it instead. The foot counter-rotates the
## leg's whole turn in the same way, keeping the orientation it stands in, so its
## toe and heel cannot sweep the ground as the knee flexes.
func _pose_legs(phase: float, run_weight: float) -> void:
	var walk_stance := stance_fraction(_walk_reach, STRIDE_LENGTH_M)
	var run_stance := stance_fraction(_run_reach, RUN_STRIDE_LENGTH_M)
	_set_pelvis_drop(lerpf(WALK_PELVIS_DROP_M, RUN_PELVIS_DROP_M, run_weight))
	for i in _legs.size():
		var leg := _legs[i]
		var right := i == 1
		var walk := _leg_turns(leg, cycle_position(phase, walk_stance, right), walk_stance,
			_walk_reach, WALK_FOOT_CLEARANCE_M, WALK_PELVIS_DROP_M, WALK_LEG_REACH)
		var run := _leg_turns(leg, cycle_position(phase, run_stance, right), run_stance,
			_run_reach, RUN_FOOT_CLEARANCE_M, RUN_PELVIS_DROP_M, RUN_LEG_REACH)
		var turns := walk.lerp(run, run_weight)
		var thigh: int = leg["thigh"]
		var parent_now := _skeleton.get_bone_global_pose(_skeleton.get_bone_parent(thigh)).basis.get_rotation_quaternion()
		var hip_frame: Quaternion = leg["hip_frame"]
		var thigh_rest: Quaternion = leg["thigh_rest"]
		# The thigh's pose is whatever carries the live pelvis to the turned rest
		# chain. Axes and results are renormalised: a unit vector carried through a
		# frame change drifts off unit length, and a rotation built on it would stop
		# being exactly one.
		_skeleton.set_bone_pose_rotation(thigh,
			(parent_now.inverse() * Quaternion(_lateral, turns.x) * hip_frame * thigh_rest).normalized())
		# The knee turns about the same lateral axis, expressed in the thigh's rest
		# frame before its own turn, so the shin stays in the thigh's plane.
		var thigh_frame := hip_frame * thigh_rest
		var calf_rest: Quaternion = leg["calf_rest"]
		_skeleton.set_bone_pose_rotation(int(leg["calf"]),
			(Quaternion((thigh_frame.inverse() * _lateral).normalized(), turns.y) * calf_rest).normalized())
		# The foot undoes the leg's whole turn, so it keeps its standing orientation.
		var calf_frame := thigh_frame * calf_rest
		var foot_rest: Quaternion = leg["foot_rest"]
		_skeleton.set_bone_pose_rotation(int(leg["foot"]),
			(Quaternion((calf_frame.inverse() * _lateral).normalized(), -(turns.x + turns.y)) * foot_rest).normalized())


## The thigh turn and the knee turn relative to it, in radians about the lateral
## axis, that put this leg's ankle where the gait wants it at cycle position `u`.
##
## A foot leaving the ground keeps travelling back under the body for a moment,
## further than the leg reaches at the gait's `limit`. There it rises instead of
## the knee straightening: the heel lifts behind, as it does at lift-off.
func _leg_turns(leg: Dictionary, u: float, stance: float, reach: float, clearance: float, drop: float, limit: float) -> Vector2:
	var path := foot_path(u, stance, reach, clearance)
	var target := Vector2(path.x, -(float(leg["hip_over_ankle_m"]) - drop) + path.y)
	var longest := limit * (float(leg["upper_m"]) + float(leg["lower_m"]))
	if target.length() > longest:
		var forward := clampf(target.x, -longest, longest)
		target = Vector2(forward, -sqrt(longest * longest - forward * forward))
	var solved := solve_leg(float(leg["upper_m"]), float(leg["lower_m"]), target)
	var thigh_turn := solved.x - float(leg["thigh_rest_angle"])
	return Vector2(thigh_turn, solved.y - float(leg["calf_rest_angle"]) - thigh_turn)


func _set_pelvis_drop(drop: float) -> void:
	_skeleton.set_bone_pose_position(_pelvis,
		_pelvis_rest_origin + _pelvis_parent_rest.inverse() * (Vector3.DOWN * drop))


## Stand the plant back up: the pelvis at its rest height and the feet, which
## only the gaits pose, at their rest orientation.
func _reset_plant() -> void:
	if not _legs_ready:
		return
	_skeleton.set_bone_pose_position(_pelvis, _pelvis_rest_origin)
	for leg: Dictionary in _legs:
		_skeleton.set_bone_pose_rotation(int(leg["foot"]), leg["foot_rest"])


## How much of each cycle one foot can stay down: while it does, it sweeps from
## `reach` ahead of the hip to `reach` behind it, and the body covers exactly that
## much ground meanwhile, so a longer stance would drag the foot.
static func stance_fraction(reach: float, stride_length: float) -> float:
	return clampf(2.0 * reach / stride_length, 0.05, 0.95)


## Where in its own cycle (0 to 1, stance first) one foot is at a gait phase. The
## left foot leaves the ground at a quarter phase, the moment the swung gait had
## that leg furthest back, so a phase names the same moment in both and a
## fixed-phase capture frames what it always did; the right foot is half a cycle
## behind.
static func cycle_position(phase: float, stance: float, right: bool) -> float:
	var u := fposmod(phase / TAU - 0.25 + stance, 1.0)
	return fposmod(u + 0.5, 1.0) if right else u


## One foot's place relative to its hip at cycle position `u`: how far forward,
## and how far above its standing height. Down for the first `stance` of the
## cycle, flat on the ground and moving from `reach` ahead to `reach` behind at
## exactly the body's speed; then carried forward again on an arc `clearance`
## high.
##
## The swing leaves and meets the ground still moving back under the body at the
## stance's speed — standing still over the ground — so a foot neither skids as it
## lifts nor as it lands: the forward travel is a cubic whose end slopes match the
## stance. Its height is a half sine, which rises at a finite rate: a lift that
## left the ground infinitely fast would snap a nearly straight knee through
## several degrees in a single millisecond.
static func foot_path(u: float, stance: float, reach: float, clearance: float) -> Vector2:
	if u < stance:
		return Vector2(reach * (1.0 - 2.0 * u / stance), 0.0)
	var w := (u - stance) / (1.0 - stance)
	var slope := -2.0 * reach * (1.0 - stance) / stance
	var w2 := w * w
	var w3 := w2 * w
	var forward := ((2.0 * w3 - 3.0 * w2 + 1.0) * -reach + (w3 - 2.0 * w2 + w) * slope
		+ (-2.0 * w3 + 3.0 * w2) * reach + (w3 - w2) * slope)
	return Vector2(forward, clearance * sin(PI * w))


## Absolute thigh and shin angles — from straight down, positive forward — that
## put an ankle at `target` from the hip, with the knee bending forward. A target
## out of reach is met at full stretch along the same line.
static func solve_leg(upper: float, lower: float, target: Vector2) -> Vector2:
	var distance := clampf(target.length(), absf(upper - lower) + 0.0001, upper + lower - 0.0001)
	var toward := atan2(target.x, -target.y)
	var opening := acos(clampf((upper * upper + distance * distance - lower * lower) / (2.0 * upper * distance), -1.0, 1.0))
	var thigh := toward + opening
	var knee := Vector2(upper * sin(thigh), -upper * cos(thigh))
	return Vector2(thigh, atan2(target.x - knee.x, -(target.y - knee.y)))


## The selected gait's angles for a phase in radians. Both gaits answer for
## every driven bone, so a channel one of them leaves alone is an explicit zero
## rather than a missing key that would pose whatever the other gait left behind.
static func gait_angles(phase: float, running: bool) -> Dictionary:
	return run_angles(phase) if running else angles(phase)


## Pure WALK angles for a phase in radians.
##
## The arm keys pose every rig. The leg keys pose only a rig lacking the bones
## the planted solve needs ([constant PLANT_BONES]); a full rig takes its legs
## from [method foot_path] instead. The same holds for [method run_angles].
static func angles(phase: float) -> Dictionary:
	var stride := sin(phase)
	return {
		"thigh_l": THIGH_SWING_DEG * stride,
		"thigh_r": -THIGH_SWING_DEG * stride,
		# The advancing leg bends while its opposite stays long enough to read
		# as the planted side. Half a cycle later the roles exchange.
		"calf_l": KNEE_FLEX_DEG * maxf(stride, 0.0),
		"calf_r": KNEE_FLEX_DEG * maxf(-stride, 0.0),
		# Arms counter-swing against their same-side legs.
		"upperarm_l": -ARM_SWING_DEG * stride,
		"upperarm_r": ARM_SWING_DEG * stride,
		# Straight arms, stated rather than implied: a walk that swings from the
		# shoulder with a loose elbow is the posture, and it is what the run's
		# folded carriage reads against.
		"lowerarm_l": 0.0,
		"lowerarm_r": 0.0,
	}


## Pure RUN angles for a phase in radians.
##
## Deliberately not a scaled [method angles]: the knee keeps a standing bias so
## it never straightens, and the elbows drive a channel the walk holds at zero.
static func run_angles(phase: float) -> Dictionary:
	var stride := sin(phase)
	return {
		"thigh_l": RUN_THIGH_SWING_DEG * stride,
		"thigh_r": -RUN_THIGH_SWING_DEG * stride,
		# Bias PLUS swing. The walk's `KNEE_FLEX * max(stride, 0)` returns to
		# exactly rest on the planted leg; at a run the trailing heel is still
		# folded when the leading foot lands, so neither knee ever reaches 0.
		"calf_l": RUN_KNEE_BASE_DEG + RUN_KNEE_SWING_DEG * maxf(stride, 0.0),
		"calf_r": RUN_KNEE_BASE_DEG + RUN_KNEE_SWING_DEG * maxf(-stride, 0.0),
		# Same counter-swing law as the walk, driven harder.
		"upperarm_l": -RUN_ARM_SWING_DEG * stride,
		"upperarm_r": RUN_ARM_SWING_DEG * stride,
		# Folded, and closing further on the arm that is driving forward. The
		# left arm leads when `stride` is negative (it counter-swings its own
		# leg), hence the opposed pump signs — the CARRIAGE sign is shared,
		# because flexion is unmirrored on this rig.
		"lowerarm_l": RUN_ELBOW_FLEX_DEG - RUN_ELBOW_PUMP_DEG * stride,
		"lowerarm_r": RUN_ELBOW_FLEX_DEG + RUN_ELBOW_PUMP_DEG * stride,
	}


func _reset_pose() -> void:
	_reset_plant()
	for bone_name: String in DRIVEN_BONES:
		var bone := _skeleton.find_bone(bone_name)
		var rest_rotation := _skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
		_skeleton.set_bone_pose_rotation(bone, rest_rotation)
