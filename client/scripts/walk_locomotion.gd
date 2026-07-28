class_name WalkLocomotion
extends Node
## The wanderer's grounded locomotion: an authored walk and an authored run.
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
## Airborne, landing and turning cues stay in the standing pose until they have
## their own slices — [method advance_motion] resets rather than reusing a gait
## for them, so #224's remaining jump criterion cannot read as finished.
## There is also no vertical bob on the run's flight phase: bob is TRANSLATION,
## and this node poses a skeleton the controller moves. It belongs with the
## controller work, not here.
##
## The class name is deliberately unchanged: the opt-in flag and its retirement
## issue (#405) both name the walk, and renaming a class is a refactor that has
## no business riding along with a behaviour change.
##
## Experimental and default-off per product law. `WAR_WALK_CYCLE=1` opts in.

const FLAG_ENV := "WAR_WALK_CYCLE"

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

const DRIVEN_BONES := [
	"thigh_l", "thigh_r",
	"calf_l", "calf_r",
	"upperarm_l", "upperarm_r",
	"lowerarm_l", "lowerarm_r",
]

var _enabled := false
var _phase := 0.0
var _skeleton: Skeleton3D = null


## Bind the driver to the newest recipe-built body. Character editing rebuilds
## that body in place, so the player keeps one driver and rebinds it.
func bind(body: Node3D) -> void:
	_skeleton = CharacterFactory.find_skeleton(body)
	_phase = 0.0
	_enabled = OS.get_environment(FLAG_ENV) == "1"
	if _skeleton == null:
		push_error("WalkLocomotion: character body has no skeleton")
		_enabled = false
		return
	for bone_name: String in DRIVEN_BONES:
		if _skeleton.find_bone(bone_name) < 0:
			push_error("WalkLocomotion: rig has no bone %s" % bone_name)
			_enabled = false


## Advance from the controller's actual horizontal motion.
##
## `grounded` and `sprinting` are explicit inputs so neither gait can quietly
## become a placeholder for a state it does not author. `sprinting` now SELECTS
## the run rather than suppressing the walk; `grounded` still suppresses both,
## because the airborne pose is genuinely unwritten.
func advance_motion(
		horizontal_speed: float,
		grounded: bool,
		sprinting: bool,
		delta: float) -> void:
	if not _enabled or _skeleton == null:
		return
	if not grounded or horizontal_speed < MIN_WALK_SPEED:
		_phase = 0.0
		_reset_pose()
		return
	var distance := maxf(horizontal_speed, 0.0) * maxf(delta, 0.0)
	# The phase carries across a gait change instead of restarting: the stride
	# LENGTH switches, so cadence changes without the legs snapping to a new
	# point in the cycle mid-step.
	var stride_length := RUN_STRIDE_LENGTH_M if sprinting else STRIDE_LENGTH_M
	_phase = fposmod(_phase + TAU * distance / stride_length, TAU)
	apply_phase(_phase, sprinting)


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
