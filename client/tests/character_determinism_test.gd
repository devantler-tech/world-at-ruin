extends Node
## Regression test for the Phase 0 art pipeline, stage 2 (issue #1): the
## character generator must be deterministic, preset-sensitive, and must
## actually reshape the committed base body.
##  1. Same preset twice ⇒ identical fingerprint (skeleton global rests +
##     CPU-skinned vertex stream, SHA-256).
##  2. BASE / GROUNDED / HERO ⇒ three distinct fingerprints.
##  3. HERO widened the shoulders and grew the hands by the promised amounts,
##     without changing overall height (proportions, not size).
##  4. The arms hang (rest-pose edit brought them down from the T-pose).
##  5. The committed asset still carries its three skinned meshes.
##
## Run: godot --headless --path client res://tests/character_determinism_test.tscn

const HANG_DEG := 62.0


func _ready() -> void:
	var hero_a := CharacterGen.build(CharacterGen.Preset.HERO, HANG_DEG)
	var hero_b := CharacterGen.build(CharacterGen.Preset.HERO, HANG_DEG)
	var base := CharacterGen.build(CharacterGen.Preset.BASE, HANG_DEG)
	var grounded := CharacterGen.build(CharacterGen.Preset.GROUNDED, HANG_DEG)
	if hero_a == null or hero_b == null or base == null or grounded == null:
		_fail("build returned null — committed base mesh missing or unimported")
		return

	var fp_hero_a := CharacterGen.fingerprint(hero_a)
	var fp_hero_b := CharacterGen.fingerprint(hero_b)
	var fp_base := CharacterGen.fingerprint(base)
	var fp_grounded := CharacterGen.fingerprint(grounded)

	if fp_hero_a != fp_hero_b:
		_fail("same preset produced different characters:\n  %s\n  %s" % [fp_hero_a, fp_hero_b])
		return
	if fp_hero_a == fp_base or fp_hero_a == fp_grounded or fp_base == fp_grounded:
		_fail("presets did not diverge:\n  hero=%s\n  base=%s\n  grounded=%s" % [fp_hero_a, fp_base, fp_grounded])
		return

	var hero_skel := CharacterGen.find_skeleton(hero_a)
	var base_skel := CharacterGen.find_skeleton(base)
	if hero_skel == null or base_skel == null:
		_fail("no Skeleton3D in built character")
		return

	# Shoulder push-out: +8% on the upperarm joint origins must widen the
	# global span by at least 4% (the clavicle root offset dilutes it).
	var hero_span := _shoulder_span(hero_skel)
	var base_span := _shoulder_span(base_skel)
	if hero_span < base_span * 1.04:
		_fail("hero shoulders not wider: %f vs base %f" % [hero_span, base_span])
		return

	# Hand growth: 1.28x uniform subtree scale, read back from the global rest
	# basis (girth compensation on the forearm makes this approximate).
	var hand := hero_skel.find_bone("hand_l")
	var hand_scale := hero_skel.get_bone_global_rest(hand).basis.get_scale()
	if absf(hand_scale.y - 1.28) > 0.03:
		_fail("hero hand scale off: %s (wanted ~1.28)" % hand_scale)
		return

	# Proportions, not size: skinned-mesh height stays within 6%.
	var hero_h := _mesh_height(hero_skel)
	var base_h := _mesh_height(base_skel)
	if absf(hero_h - base_h) > base_h * 0.06:
		_fail("hero height drifted: %f vs base %f" % [hero_h, base_h])
		return

	# BOTH arms hang, and pose == rest per hand. Poses are TRS — a rest with
	# shear baked in (non-uniform scale compensated through a rotated child)
	# decomposes lossily and one arm silently springs back to the T-pose;
	# skinning consumes poses, so the render lies while rests look right.
	hero_skel.force_update_all_bone_transforms()
	for hand_name in ["hand_l", "hand_r"]:
		var h := hero_skel.find_bone(hand_name)
		var rest_o := hero_skel.get_bone_global_rest(h).origin
		var pose_o := hero_skel.get_bone_global_pose(h).origin
		if rest_o.distance_to(pose_o) > 0.001:
			_fail("%s pose diverged from rest (shear in a rest?): pose=%s rest=%s" % [hand_name, pose_o, rest_o])
			return
		if pose_o.y > 1.0:
			_fail("%s still in T-pose: y=%f" % [hand_name, pose_o.y])
			return

	# The committed asset's three skinned meshes are all present and skinned.
	var skinned := 0
	for child in hero_skel.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).skin != null:
			skinned += 1
	if skinned != 3:
		_fail("expected 3 skinned meshes (body, eyes, eyebrows), found %d" % skinned)
		return

	hero_a.free()
	hero_b.free()
	base.free()
	grounded.free()
	print("TEST PASS — %s" % fp_hero_a)
	get_tree().quit(0)


func _shoulder_span(skel: Skeleton3D) -> float:
	var l := skel.get_bone_global_rest(skel.find_bone("upperarm_l")).origin
	var r := skel.get_bone_global_rest(skel.find_bone("upperarm_r")).origin
	return l.distance_to(r)


## Height of the CPU-skinned body: max Y over the deformed vertex stream.
func _mesh_height(skel: Skeleton3D) -> float:
	skel.force_update_all_bone_transforms()
	var top := 0.0
	for child in skel.get_children():
		if child is not MeshInstance3D:
			continue
		for p in CharacterGen._cpu_skin(skel, child as MeshInstance3D):
			top = maxf(top, p.y)
	return top


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
