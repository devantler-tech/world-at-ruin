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
## Sprint is the default travel verb, so it is on screen for most of a session —
## and it used to be the one state that posed nothing, sliding a bolt-upright
## body at [constant Player.SPRINT_SPEED] (issue #481). Scaling the walk's
## amplitudes would have been the cheap fix and the wrong one: a run differs
## from a walk in SHAPE, not size, and two channels carry that difference.
##
## 1. THE ELBOWS BEND. The walk holds the arms straight and swings them from the
##    shoulder; a run carries them folded and drives them. `lowerarm_l/r` is a
##    channel the walk does not touch at all, which is why the run cannot be
##    mistaken for a louder walk.
## 2. THE KNEES NEVER STRAIGHTEN. The walk's knee flexes only on the advancing
##    leg and returns to exactly zero on the planted one, which is what reads as
##    a planted step. A run has no planted phase — the trailing heel is still
##    folded up when the leading foot lands — so its knee angle is a standing
##    bias PLUS a swing, and never reaches rest.
##
## Both are why [method run_angles] is not [method angles] times a constant, and
## `walk_locomotion_test` asserts exactly that rather than trusting the wording.
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
## skeleton the controller moves.
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
	# Phase is continuous across a gait change — the stride LENGTH switches, so
	# cadence changes without the legs jumping to a different point in the
	# cycle. Every pose channel crossfades from that shared phase.
	var stride_length := RUN_STRIDE_LENGTH_M if sprinting else STRIDE_LENGTH_M
	_phase = fposmod(_phase + TAU * distance / stride_length, TAU)
	apply_blended_phase(_phase, smoothstep(0.0, 1.0, _run_blend))


## Pose one exact point on the airborne arc. Runtime and evidence capture share
## this method so a deterministic frame sequence cannot drift into preview-only
## animation. Positive speed blends from the compact apex to push-off; negative
## speed opens into a landing-ready descent.
func apply_jump(vertical_speed: float) -> void:
	if _skeleton == null:
		push_error("WalkLocomotion: cannot pose an unbound skeleton")
		return
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
	if _skeleton == null:
		push_error("WalkLocomotion: cannot pose an unbound skeleton")
		return
	var now := gait_angles(fposmod(phase, TAU), running)
	for bone_name: String in DRIVEN_BONES:
		var bone := _skeleton.find_bone(bone_name)
		var rest_rotation := _skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
		_skeleton.set_bone_pose_rotation(
			bone,
			rest_rotation * Quaternion(Vector3.RIGHT, deg_to_rad(now[bone_name])))


## Pose an interpolation between the authored walk and run at one shared phase.
## The runtime supplies an eased weight; keeping the interpolation itself pure
## makes every driven channel explicit, including the walk's zeroed elbows.
func apply_blended_phase(phase: float, run_weight: float) -> void:
	if _skeleton == null:
		push_error("WalkLocomotion: cannot pose an unbound skeleton")
		return
	var walk := angles(fposmod(phase, TAU))
	var run := run_angles(fposmod(phase, TAU))
	var weight := clampf(run_weight, 0.0, 1.0)
	for bone_name: String in DRIVEN_BONES:
		var bone := _skeleton.find_bone(bone_name)
		var rest_rotation := _skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
		var angle := lerpf(walk[bone_name], run[bone_name], weight)
		_skeleton.set_bone_pose_rotation(
			bone,
			rest_rotation * Quaternion(Vector3.RIGHT, deg_to_rad(angle)))


## The selected gait's angles for a phase in radians. Both gaits answer for
## every driven bone, so a channel one of them leaves alone is an explicit zero
## rather than a missing key that would pose whatever the other gait left behind.
static func gait_angles(phase: float, running: bool) -> Dictionary:
	return run_angles(phase) if running else angles(phase)


## Pure WALK angles for a phase in radians.
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
	for bone_name: String in DRIVEN_BONES:
		var bone := _skeleton.find_bone(bone_name)
		var rest_rotation := _skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
		_skeleton.set_bone_pose_rotation(bone, rest_rotation)
