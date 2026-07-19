extends Node
## Regression test for the wanderer's contrapposto rest stance (#237, first
## slice of #224).
##
## The stance replaces bilateral symmetry with weight on one leg, and symmetry
## is exactly what a test can be blind to: a build that silently skipped the
## whole pose still produces a perfectly valid, perfectly upright, perfectly
## symmetric character. Every law here therefore measures ASYMMETRY of the
## built skeleton, not that a function was called.
##
## What it holds:
##  1. HIPS TILT — the engaged hip rides measurably higher than the free one.
##  2. SHOULDERS OPPOSE THE HIPS — the shoulder line tilts the OTHER way. This
##     is the definition of contrapposto and the one law a naive "lean the
##     whole body sideways" implementation fails: leaning tilts hips and
##     shoulders the SAME way, which reads as listing, not standing.
##  3. THE FREE KNEE IS BENT — the unweighted leg is not a second column.
##  4. THE HEAD STAYS LEVEL — the stance must not read as a slump; the neck
##     returns the head over the tilted shoulders.
##  5. EVERY BODY WEARS IT — the stance survives the extreme morph sliders and
##     the heaviest bone-op recipe, because it is applied relative to each
##     bone's current rest rather than as an absolute pose.
##  6. DETERMINISTIC — same recipe, same stance, every build (the #58 law).
##
## Law 2 is the load-bearing one. Laws 1 and 3 are satisfied by any sideways
## lean or any single bent knee; only the OPPOSITION of the two lines is
## contrapposto.
##
## Run: godot --headless --path client res://tests/rest_stance_test.tscn

const GOLDEN := "res://tests/data/golden_recipe_v1.json"
## Minimum height difference between the two hip joints, in metres. The pose
## hikes the engaged hip by a few degrees over a ~0.1 m half-width, so a real
## tilt clears this comfortably while a symmetric build sits at ~0.
const MIN_HIP_TILT := 0.004
## Minimum height difference between the two shoulder joints, same reasoning.
const MIN_SHOULDER_TILT := 0.004
## Minimum bend of the free knee relative to the engaged one, in degrees,
## measured between the thigh and calf directions.
const MIN_FREE_KNEE_BEND := 4.0
## The head must stay within this of level, in metres, measured as the
## side-to-side offset of the head joint from the pelvis joint. A stance that
## dumps the head sideways reads as a slump rather than a rest.
const MAX_HEAD_OFFSET := 0.06


func _ready() -> void:
	var golden = CharacterFactory.load_recipe(GOLDEN)
	if golden == null:
		_fail("golden recipe unreadable")
		return

	var body := CharacterFactory.build({ "version": 1 })
	if body == null:
		_fail("plain v1 recipe should build")
		return
	var problem := _check_stance(body, "plain body")
	body.free()
	if problem != "":
		_fail(problem)
		return

	# 5. EVERY BODY WEARS IT — heaviest bone-op recipe, then extreme sliders.
	var heavy := CharacterFactory.build(golden)
	if heavy == null:
		_fail("golden recipe should build")
		return
	problem = _check_stance(heavy, "golden recipe")
	heavy.free()
	if problem != "":
		_fail(problem)
		return

	var extreme := CharacterFactory.build(_extreme_recipe())
	if extreme == null:
		_fail("extreme-slider recipe should build")
		return
	problem = _check_stance(extreme, "extreme sliders")
	extreme.free()
	if problem != "":
		_fail(problem)
		return

	# 6. DETERMINISTIC
	var a := CharacterFactory.build(golden)
	var b := CharacterFactory.build(golden)
	var fa := CharacterFactory.fingerprint(a)
	var fb := CharacterFactory.fingerprint(b)
	a.free()
	b.free()
	if fa != fb:
		_fail("two builds of the same recipe differ — the stance is not deterministic")
		return

	print("TEST PASS — contrapposto holds on 3 bodies (hips tilt, shoulders oppose, free knee bent, head level), deterministic")
	get_tree().quit(0)


## Every stance law, measured on one built body. Returns "" when they hold.
func _check_stance(instance: Node3D, label: String) -> String:
	var skeleton := CharacterFactory.find_skeleton(instance)
	if skeleton == null:
		return "%s: no skeleton" % label
	skeleton.force_update_all_bone_transforms()

	var hip_l := _origin(skeleton, "thigh_l")
	var hip_r := _origin(skeleton, "thigh_r")
	var sho_l := _origin(skeleton, "clavicle_l")
	var sho_r := _origin(skeleton, "clavicle_r")
	if hip_l == null or hip_r == null or sho_l == null or sho_r == null:
		return "%s: hip or shoulder bone missing from the rig" % label

	# 1. HIPS TILT
	var hip_tilt: float = (hip_l as Vector3).y - (hip_r as Vector3).y
	if absf(hip_tilt) < MIN_HIP_TILT:
		return "%s: hips are level (%.4f m) — the body is standing on both legs, not one" % [label, hip_tilt]

	# 2. SHOULDERS OPPOSE THE HIPS
	var shoulder_tilt: float = (sho_l as Vector3).y - (sho_r as Vector3).y
	if absf(shoulder_tilt) < MIN_SHOULDER_TILT:
		return "%s: shoulders are level (%.4f m) — the torso never answered the hips" % [label, shoulder_tilt]
	if signf(shoulder_tilt) == signf(hip_tilt):
		return "%s: shoulders tilt the SAME way as the hips (hip %.4f, shoulder %.4f) — that is a body listing sideways, not contrapposto" % [label, hip_tilt, shoulder_tilt]

	# 3. THE FREE KNEE IS BENT
	var bend_l := _knee_bend_deg(skeleton, "l")
	var bend_r := _knee_bend_deg(skeleton, "r")
	if is_nan(bend_l) or is_nan(bend_r):
		return "%s: leg bones missing from the rig" % label
	if absf(bend_r - bend_l) < MIN_FREE_KNEE_BEND:
		return "%s: both knees are equally straight (%.2f vs %.2f deg) — the free leg is a second column" % [label, bend_l, bend_r]

	# 4. THE HEAD STAYS LEVEL
	var head := _origin(skeleton, "head")
	var pelvis := _origin(skeleton, "pelvis")
	if head == null or pelvis == null:
		return "%s: head or pelvis bone missing" % label
	var head_offset: float = absf((head as Vector3).x - (pelvis as Vector3).x)
	if head_offset > MAX_HEAD_OFFSET:
		return "%s: head sits %.4f m to the side of the pelvis — that reads as a slump, not a rest" % [label, head_offset]

	return ""


## Angle between a leg's thigh and calf directions, in degrees. 0 is a
## perfectly straight leg.
func _knee_bend_deg(skeleton: Skeleton3D, side: String) -> float:
	var thigh := skeleton.find_bone("thigh_%s" % side)
	var calf := skeleton.find_bone("calf_%s" % side)
	if thigh < 0 or calf < 0:
		return NAN
	var t: Vector3 = skeleton.get_bone_global_rest(thigh).basis.y.normalized()
	var c: Vector3 = skeleton.get_bone_global_rest(calf).basis.y.normalized()
	return rad_to_deg(t.angle_to(c))


func _origin(skeleton: Skeleton3D, bone_name: String):
	var bone := skeleton.find_bone(bone_name)
	if bone < 0:
		return null
	return skeleton.get_bone_global_rest(bone).origin


## A recipe pushed to the ends of the sliders the factory guards, so the
## stance is proven on a body whose bones have genuinely moved.
func _extreme_recipe() -> Dictionary:
	return {
		"version": 1,
		"bone_girth": { "thigh": 1.35, "calf": 0.75, "upperarm": 1.3, "spine_03": 1.25 },
		"bone_scale": { "head": 1.2, "foot": 0.85 },
		"joint_push": { "upperarm": 1.2, "hand": 0.9 },
	}


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
