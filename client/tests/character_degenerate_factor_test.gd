extends Node
## Regression test for a degenerate bone factor reaching the rest transforms (#1446).
##
## The reader accepts every finite bone factor so a legacy document is never
## stranded, but the build divides by girth and multiplies rests by the bone
## factors. A zero, negative or near-zero factor used to build a non-finite or
## collapsed skeleton. The build now treats such a factor as absent (neutral 1.0),
## so a degenerate build must stay finite and match the same recipe with that key
## removed, bone for bone. A real authored value must still change the rests, or
## the comparison would prove nothing.
##
## Run: godot --headless --path client res://tests/character_degenerate_factor_test.tscn

const DEGENERATE_VALUES := [0.0, 1e-9, -0.5, -1.0]
const TOLERANCE := 1e-5


func _ready() -> void:
	var baseline: Variant = _rests(_recipe({}))
	if baseline == null:
		_fail("the baseline recipe with no bone factors must build")
		return

	for value: float in DEGENERATE_VALUES:
		for field: String in ["bone_girth", "bone_scale", "joint_push"]:
			var key := "upperarm" if field != "bone_scale" else "hand"
			var degenerate: Variant = _rests(_recipe({field: {key: value}}))
			if degenerate == null:
				_fail("a finite degenerate %s factor must still build (the reader keeps legacy documents): %s = %s" % [field, key, value])
				return
			if not _all_finite(degenerate):
				_fail("a degenerate %s factor %s = %s produced a non-finite rest" % [field, key, value])
				return
			if _max_diff(degenerate, baseline) > TOLERANCE:
				_fail("a degenerate %s factor %s = %s did not build as absent" % [field, key, value])
				return

	# Stature joints are only legal from recipe v5; a zero thigh push must also
	# build as absent rather than collapsing the leg.
	var stature_zero: Variant = _rests(_recipe({"joint_push": {"thigh": 0.0}}))
	if stature_zero == null or not _all_finite(stature_zero):
		_fail("a zero thigh push must build with finite rests")
		return
	if _max_diff(stature_zero, baseline) > TOLERANCE:
		_fail("a zero thigh push did not build as absent")
		return

	# Negative control: an authored in-range girth must still move the rests. If it
	# did not, the equality above would be vacuous.
	var authored: Variant = _rests(_recipe({"bone_girth": {"upperarm": 1.2}}))
	if authored == null:
		_fail("an authored girth of 1.2 must build")
		return
	if _max_diff(authored, baseline) <= TOLERANCE:
		_fail("an authored girth of 1.2 did not change the rests, so the test cannot tell degenerate from absent")
		return

	print("TEST PASS — degenerate bone factors build as absent and stay finite")
	get_tree().quit(0)


func _recipe(overrides: Dictionary) -> Dictionary:
	var recipe := {
		"version": 5,
		"shapes": {},
		"bone_girth": {},
		"bone_scale": {},
		"joint_push": {},
	}
	for field: String in overrides:
		recipe[field] = overrides[field]
	return recipe


## The bone rests of one built body, or null when the recipe is refused.
func _rests(recipe: Dictionary) -> Variant:
	var built := CharacterFactory.build(recipe)
	if built == null:
		return null
	var skeleton := CharacterFactory.find_skeleton(built)
	var rests: Array = []
	for bone in skeleton.get_bone_count():
		rests.append(skeleton.get_bone_rest(bone))
	built.free()
	return rests


func _all_finite(rests: Array) -> bool:
	for rest: Transform3D in rests:
		for axis: Vector3 in [rest.origin, rest.basis.x, rest.basis.y, rest.basis.z]:
			if not (is_finite(axis.x) and is_finite(axis.y) and is_finite(axis.z)):
				return false
	return true


func _max_diff(a: Array, b: Array) -> float:
	if a.size() != b.size():
		return INF
	var worst := 0.0
	for i in a.size():
		var x: Transform3D = a[i]
		var y: Transform3D = b[i]
		worst = maxf(worst, x.origin.distance_to(y.origin))
		worst = maxf(worst, (x.basis.x - y.basis.x).length())
		worst = maxf(worst, (x.basis.y - y.basis.y).length())
		worst = maxf(worst, (x.basis.z - y.basis.z).length())
	return worst


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
