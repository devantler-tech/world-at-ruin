class_name BreathingIdle
extends Node
## The wanderer's idle: the second-order life that turns the rest stance from a
## corrected still into a body that reads alive (issue #243, part of #224/#123).
##
## `docs/art-direction/README.md` names three things for the character surface —
## "weight on one leg, asymmetric arms, a breathing idle". #237 delivered the
## pose; this delivers the motion, which is what let the stance stop being an
## opt-in experiment and become how every body stands.
##
## ## Pose, never rest
##
## The contrapposto stance is applied as REST edits (see
## `CharacterFactory._apply_contrapposto`). This is deliberately the opposite:
## it writes BONE POSES, composed on top of whatever rest the stance left.
##
## That split is what keeps the idle free: `CharacterFactory.fingerprint`
## hashes `get_bone_global_rest` and the mesh's blend-shape-mixed vertices, so
## a pose-driven idle CANNOT move a character fingerprint no matter what it
## does or when it is sampled. A rest-driven idle would have moved every
## character identity once per frame. Pinned by `breathing_idle_test`.
##
## ## Deterministic, and a pure function of time
##
## [method angles] is static and depends on nothing but `t`, so the whole
## motion is testable with no tree, no clock and no character. The node below
## is a thin driver: it advances a clock and calls [method apply_at]. Every law
## worth holding is held against the pure function or against a skeleton the
## test posed itself.
##
## ## Amplitudes are bounded BY THE STANCE
##
## The weight shift rocks the pelvis, and the stance's whole point is that the
## engaged hip rides higher. So the shift amplitude is not a taste knob: it
## must stay strictly under [constant CharacterFactory.HIP_HIKE_DEG], or at
## some phase of the loop the idle would invert the stance it is decorating.
## The test asserts the four stance direction laws at every sampled phase
## rather than trusting the constants to stay sane.

## One full inhale-and-exhale, in seconds. A resting adult breathes roughly
## 12-16 times a minute; this sits in that band rather than the faster rate
## that reads as exertion.
const BREATH_PERIOD := 4.3

## One full weight transfer, in seconds. Deliberately much slower than the
## breath and not a multiple of it: two periods that divide evenly re-align
## every few seconds and the body visibly pulses. Being incommensurate is what
## makes the combined motion read as unrepeating over any period a player
## watches.
const SHIFT_PERIOD := 11.0

## Chest pitch at the peak of an inhale, in degrees. Small on purpose — the
## breath should be noticed as life, not as a bow.
##
## 🔑 MEASURED, not reasoned (the #237 lesson, re-learned the hard way in this
## slice): a spine bone can only pitch, roll or twist — no rotation of it
## RAISES the chest, because rotating a bone about its own origin cannot
## lengthen the body. Rotating `spine_02` about RIGHT moves the head +25.8 mm
## FORWARD per 3 degrees (and 3.5 mm down). So this channel is really the chest
## OPENING and settling, and its SIGN is what decides which. Positive about
## RIGHT tips the chest forward — a collapse — so an inhale must be NEGATIVE.
## The first draft had it the other way round and folded the wanderer forward
## as it breathed in; `breathing_idle_test` law 5b now fails on that.
const CHEST_RISE_DEG := 0.75

## How much of the chest rise the upper chest adds on top of the lower. The
## ribcage opens progressively up its length; moving both bones by the same
## amount reads as a hinge.
const UPPER_CHEST_SHARE := 0.6

## Shoulder lift at the peak of an inhale, in degrees.
##
## 🔑 ALSO MEASURED: rotating a clavicle about FORWARD moves its shoulder joint
## 7.8 mm per 3 degrees, and the sign is MIRRORED between the sides (positive
## lowers the LEFT and raises the RIGHT — the same convention the stance
## measured). Lifting BOTH shoulders therefore needs opposite signs, not one
## shared one.
##
## Set from that measurement rather than by feel: 2.0 degrees is ~5 mm of
## travel per shoulder, which reads on a character a few metres away. The 0.55
## this started at was ~1.4 mm — real, provable by a test, and invisible to a
## player. #237 hit the same thing and retuned 4 deg to 6 deg after an A/B.
const SHOULDER_RISE_DEG := 2.0

## Peak pelvis roll of the slow weight transfer, in degrees, in the same signed
## space as the stance (positive raises the ENGAGED side).
##
## ⚠️ Must stay well under `CharacterFactory.HIP_HIKE_DEG` (6.0). At -1.4 the
## engaged hip is still 4.6 deg high at the worst phase; at -6.0 or beyond the
## idle would periodically flatten or invert the stance. `breathing_idle_test`
## fails on that rather than leaving it to a reviewer to notice.
const WEIGHT_SHIFT_DEG := 1.4

## The bone each idle channel rotates, and the LOCAL axis it turns about.
##
## Split from the time function on purpose: which axis a bone turns about is
## structure and belongs in a table, while how far it has turned right now is
## motion. It also means a missing bone is caught as a table/rig mismatch
## instead of becoming a silent no-op inside the driver.
const IDLE_AXES := {
	"spine_02": Vector3.RIGHT,     # lower chest: the breath
	"spine_03": Vector3.RIGHT,     # upper chest, adding to it
	"clavicle_l": Vector3.FORWARD, # shoulders ride the breath
	"clavicle_r": Vector3.FORWARD,
	"pelvis": Vector3.FORWARD,     # the slow weight transfer
}

## Phase offset in seconds, so a crowd does not breathe in unison. Set by
## `CharacterFactory.build` from the recipe, so it is stable for a given
## character across runs rather than random per boot.
var phase_offset := 0.0

var _skeleton: Skeleton3D = null
var _t := 0.0


## Every angle of the idle at time `t`, as bone name -> degrees about that
## bone's axis in [constant IDLE_AXES].
##
## Pure and total: no engine state, no node, no clock. Both channels are
## sinusoids, which makes the loop seamless by construction — there is no
## wrap point to blend across, because sin has none.
static func angles(t: float) -> Dictionary:
	var breath := sin(TAU * t / BREATH_PERIOD)
	var shift := sin(TAU * t / SHIFT_PERIOD)
	return {
		# NEGATIVE on the inhale: positive about RIGHT tips the chest forward,
		# which is a body folding over its breath rather than opening to it.
		"spine_02": -CHEST_RISE_DEG * breath,
		"spine_03": -CHEST_RISE_DEG * UPPER_CHEST_SHARE * breath,
		# OPPOSITE signs, because the clavicle roll convention is mirrored
		# between the sides: negative raises the left, positive raises the
		# right. One shared sign would shrug one shoulder and drop the other.
		"clavicle_l": -SHOULDER_RISE_DEG * breath,
		"clavicle_r": SHOULDER_RISE_DEG * breath,
		"pelvis": CharacterFactory.STANCE_ROLL_SIGN * WEIGHT_SHIFT_DEG * shift,
	}


## Pose `skeleton` for time `t`, composing the idle on top of each driven
## bone's REST — so the stance underneath is preserved and only decorated.
##
## Stateless: it re-reads rest every call rather than caching it, which costs
## five transform reads and removes any chance of a cached rest going stale
## after an equipment change or a recipe rebuild.
static func apply_at(skeleton: Skeleton3D, t: float) -> void:
	var now := angles(t)
	for bone_name: String in IDLE_AXES:
		var bone := skeleton.find_bone(bone_name)
		if bone < 0:
			# A rig without this bone is a real mismatch, not something to
			# quietly skip — a silently half-applied idle is the failure mode
			# that is hardest to see in a frame.
			push_error("BreathingIdle: rig has no bone %s" % bone_name)
			continue
		var axis: Vector3 = IDLE_AXES[bone_name]
		var degrees: float = now[bone_name]
		var rest_rotation := skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
		skeleton.set_bone_pose_rotation(
			bone, rest_rotation * Quaternion(axis, deg_to_rad(degrees))
		)


## Bones this idle drives that the given skeleton does not have. Empty on a
## healthy rig; the test asserts that rather than discovering it in a frame.
static func missing_bones(skeleton: Skeleton3D) -> Array[String]:
	var missing: Array[String] = []
	for bone_name: String in IDLE_AXES:
		if skeleton.find_bone(bone_name) < 0:
			missing.append(bone_name)
	return missing


func _ready() -> void:
	_skeleton = CharacterFactory.find_skeleton(get_parent())
	if _skeleton == null:
		push_error("BreathingIdle: no skeleton under %s — the body will not breathe" % get_parent())
		set_process(false)
		return
	_t = phase_offset


func _process(delta: float) -> void:
	_t += delta
	apply_at(_skeleton, _t)
