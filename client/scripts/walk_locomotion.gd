class_name WalkLocomotion
extends Node
## The first authored locomotion cue: a grounded walk cycle for the wanderer.
##
## The controller owns translation and this node owns only the recipe-built
## skeleton pose. Phase advances from horizontal DISTANCE, not elapsed render
## time, so a stride follows travel at every input strength and two machines
## moving the same distance pose the same body.
##
## This is deliberately narrower than a general animation graph. Sprint,
## airborne, landing and turning cues stay in the standing pose until they have
## their own authored slices; accelerating this walk would falsely present
## those missing states as finished.
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

const DRIVEN_BONES := [
	"thigh_l", "thigh_r",
	"calf_l", "calf_r",
	"upperarm_l", "upperarm_r",
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
## `grounded` and `sprinting` are explicit inputs so the walk cannot quietly
## become a placeholder for states it does not author.
func advance_motion(
		horizontal_speed: float,
		grounded: bool,
		sprinting: bool,
		delta: float) -> void:
	if not _enabled or _skeleton == null:
		return
	if not grounded or sprinting or horizontal_speed < MIN_WALK_SPEED:
		_phase = 0.0
		_reset_pose()
		return
	var distance := maxf(horizontal_speed, 0.0) * maxf(delta, 0.0)
	_phase = fposmod(_phase + TAU * distance / STRIDE_LENGTH_M, TAU)
	apply_phase(_phase)


## Pose one exact phase. The fixed-phase evidence capture uses the same method
## as the runtime driver, so its frame sequence cannot drift into a preview-only
## implementation.
func apply_phase(phase: float) -> void:
	if _skeleton == null:
		push_error("WalkLocomotion: cannot pose an unbound skeleton")
		return
	var now := angles(fposmod(phase, TAU))
	for bone_name: String in DRIVEN_BONES:
		var bone := _skeleton.find_bone(bone_name)
		var rest_rotation := _skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
		_skeleton.set_bone_pose_rotation(
			bone,
			rest_rotation * Quaternion(Vector3.RIGHT, deg_to_rad(now[bone_name])))


## Pure gait angles for a phase in radians.
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
	}


func _reset_pose() -> void:
	for bone_name: String in DRIVEN_BONES:
		var bone := _skeleton.find_bone(bone_name)
		var rest_rotation := _skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
		_skeleton.set_bone_pose_rotation(bone, rest_rotation)
