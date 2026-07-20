extends Node
## Pins how `Skeleton3D` treats a bone POSE against its REST (#243, part of #224).
##
## Every additive animation in this repo — the breathing idle, and whatever
## comes after it — has to answer one question before it can be written
## correctly: when you write a bone pose, does the engine COMPOSE it on top of
## that bone's rest transform, or does it REPLACE the rest outright?
##
## The two models demand opposite code. If the pose composed on top of the
## rest, then writing `rest * offset` would apply the rest TWICE and deform
## every rigged character. If the pose replaces the rest, then writing bare
## `offset` silently DISCARDS the rest rotation and does the deforming instead.
## Exactly one of those is a bug, and which one depends on engine behaviour
## that reads plausibly either way from the API names alone.
##
## Godot 4.7 REPLACES: a bone's pose is an absolute local transform, so an
## additive idle must be written as `rest_rotation * offset`. This has been
## measured three times on this repo and re-raised by review each time as a
## P1 defect, because the composing model is the one that sounds right. Prose
## cannot settle it — so the measurement lives here as a test, and CI asserts
## the engine's actual semantics on every run.
##
##  1. AN IDENTITY POSE YIELDS IDENTITY, NOT THE REST. This is the decisive
##     row. Under the composing model an identity pose would leave the bone
##     sitting at its rest; under the replacing model it lands at identity.
##     Nothing else here distinguishes the two models as cleanly.
##  2. A BARE OFFSET DISCARDS THE REST — the failure mode of writing an
##     additive idle the "obvious" way.
##  3. `rest * offset` YIELDS THE INTENDED POSE — the form the idle must use.
##  4. `reset_bone_pose()` SETS POSE = REST, which only makes sense if a pose
##     is an absolute local transform. Corroborates 1–3 from the API side.
##
## The rest rotation used here is deliberately 90° about Y: large, unambiguous,
## and impossible to confuse with the small idle offset laid on top of it.
##
## Run: godot --headless --path client res://tests/skeleton_pose_semantics_test.tscn

## Degrees of tolerance when comparing measured Euler angles.
const ANGLE_EPSILON_DEG := 0.01

var _skeleton: Skeleton3D
var _bone: int


func _ready() -> void:
	_skeleton = Skeleton3D.new()
	add_child(_skeleton)
	_bone = _skeleton.add_bone("probe")

	var rest_rotation := Quaternion(Vector3.UP, deg_to_rad(90.0))
	_skeleton.set_bone_rest(_bone, Transform3D(Basis(rest_rotation), Vector3.ZERO))
	_skeleton.reset_bone_pose(_bone)

	# The offset an additive idle would want to lay on top of the rest.
	var offset := Quaternion(Vector3.RIGHT, deg_to_rad(5.0))

	# 1. An identity pose must land at identity — NOT at the rest. If this row
	#    ever flips, the engine has switched to the composing model and every
	#    `rest * offset` in the codebase is now applying the rest twice.
	_skeleton.set_bone_pose_rotation(_bone, Quaternion.IDENTITY)
	if not _assert_euler(
		"identity pose",
		Vector3.ZERO,
		"a pose COMPOSED on the rest would read (0, 90, 0) here — it reads the pose itself,"
		+ " so the pose REPLACES the rest and an additive idle must carry the rest explicitly"
	):
		return

	# 2. A bare offset discards the rest entirely.
	_skeleton.set_bone_pose_rotation(_bone, offset)
	if not _assert_euler(
		"bare offset pose",
		Vector3(5.0, 0.0, 0.0),
		"writing an additive idle as a bare offset silently drops the bone's rest rotation"
	):
		return

	# 3. rest * offset is the composition an additive idle must write.
	_skeleton.set_bone_pose_rotation(_bone, rest_rotation * offset)
	if not _assert_euler(
		"rest * offset pose",
		Vector3(5.0, 90.0, 0.0),
		"rest_rotation * offset must yield the rest with the idle laid on top of it"
	):
		return

	# 4. reset_bone_pose puts the pose back AT the rest — only coherent if a
	#    pose is an absolute local transform.
	_skeleton.reset_bone_pose(_bone)
	if not _assert_euler(
		"reset_bone_pose",
		Vector3(0.0, 90.0, 0.0),
		"reset_bone_pose() must restore the rest, corroborating that a pose is absolute"
	):
		return

	print(
		"TEST PASS — Skeleton3D pose REPLACES rest (identity pose ⇒ identity, not rest);"
		+ " an additive idle must write rest_rotation * offset"
	)
	get_tree().quit(0)


## Compares the bone's measured global pose against expected Euler degrees.
## Returns false on mismatch — `get_tree().quit()` does NOT halt the frame, so
## every caller must stop on false or a failed run still reaches the TEST PASS
## line that CI greps for.
func _assert_euler(label: String, expected_deg: Vector3, why: String) -> bool:
	var measured := _skeleton.get_bone_global_pose(_bone).basis.get_euler()
	var measured_deg := Vector3(
		rad_to_deg(measured.x), rad_to_deg(measured.y), rad_to_deg(measured.z)
	)
	for axis in 3:
		if absf(measured_deg[axis] - expected_deg[axis]) > ANGLE_EPSILON_DEG:
			_fail(
				(
					"%s: expected %s, measured %s — %s"
					% [label, str(expected_deg), str(measured_deg), why]
				)
			)
			return false
	return true


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
