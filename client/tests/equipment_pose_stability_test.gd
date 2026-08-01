extends Node
## Regression test for equipment changing the character's idle pose (#654).
##
## CharacterCreator rebuilds the real character whenever an outfit picker
## changes. The rebuilt body must keep the same animation phase: equipment may
## add a skinned mesh and tuck the covered body, but it may not move the
## canonical skeleton. A test that compares rest alone passes the bug, because
## the displacement lives in BreathingIdle's pose after the capture pins it.
##
## Run: godot --headless --path client res://tests/equipment_pose_stability_test.tscn

const WANDERER := "res://recipes/wanderer.json"
const PIECE := "ashen_bindings"

## Float32 skeleton pose storage leaves sub-micrometre position dust and
## sub-millionth quaternion-dot dust between equivalent imported instances.
const POSITION_EPSILON := 0.000001
const ROTATION_EPSILON := 0.000001


func _ready() -> void:
	var loaded: Variant = CharacterFactory.load_recipe(WANDERER)
	if loaded is not Dictionary:
		_fail("could not load the shipped wanderer recipe")
		return

	var plain_recipe := (loaded as Dictionary).duplicate(true)
	var equipped_recipe := plain_recipe.duplicate(true)
	(equipped_recipe["equipment"] as Dictionary)["hands"] = PIECE

	var plain := CharacterFactory.build(plain_recipe)
	var equipped := CharacterFactory.build(equipped_recipe)
	if plain == null or equipped == null:
		_free_if_valid(plain)
		_free_if_valid(equipped)
		_fail("the real CharacterFactory could not build both outfit states")
		return
	add_child(plain)
	add_child(equipped)

	var plain_skeleton := CharacterFactory.find_skeleton(plain)
	var equipped_skeleton := CharacterFactory.find_skeleton(equipped)
	var plain_idle := plain.get_node_or_null("BreathingIdle") as BreathingIdle
	var equipped_idle := equipped.get_node_or_null("BreathingIdle") as BreathingIdle
	if plain_skeleton == null or equipped_skeleton == null \
			or plain_idle == null or equipped_idle == null:
		_fail("one outfit state has no canonical skeleton or breathing idle")
		return
	if not plain_idle.freeze_at() or not equipped_idle.freeze_at():
		_fail("the real capture pin could not freeze both outfit states")
		return
	plain_skeleton.force_update_all_bone_transforms()
	equipped_skeleton.force_update_all_bone_transforms()

	var garment := equipped_skeleton.get_node_or_null(
		NodePath(CharacterFactory.EQUIP_PREFIX + PIECE)) as MeshInstance3D
	if garment == null or garment.mesh == null or not garment.visible:
		_fail("the equipped state did not retain the visible ashen-bindings mesh")
		return
	if CharacterFactory.cpu_skin(equipped_skeleton, garment).is_empty():
		_fail("the ashen bindings retained no skinned vertices")
		return

	if plain_skeleton.get_bone_count() != equipped_skeleton.get_bone_count():
		_fail("equipping hand armour changed the canonical skeleton")
		return
	var worst_bone := ""
	var worst_position := 0.0
	var worst_rotation := 0.0
	var worst_ratio := 0.0
	for bone in plain_skeleton.get_bone_count():
		var bone_name := plain_skeleton.get_bone_name(bone)
		if equipped_skeleton.get_bone_name(bone) != bone_name:
			_fail("equipping hand armour changed bone %d from '%s' to '%s'" % [
				bone,
				bone_name,
				equipped_skeleton.get_bone_name(bone),
			])
			return
		var plain_pose := plain_skeleton.get_bone_global_pose(bone)
		var equipped_pose := equipped_skeleton.get_bone_global_pose(bone)
		var position_delta := plain_pose.origin.distance_to(equipped_pose.origin)
		var rotation_delta := 1.0 - absf(
			plain_pose.basis.get_rotation_quaternion().dot(
				equipped_pose.basis.get_rotation_quaternion()))
		var ratio := maxf(
			position_delta / POSITION_EPSILON,
			rotation_delta / ROTATION_EPSILON)
		if ratio > worst_ratio:
			worst_bone = bone_name
			worst_position = position_delta
			worst_rotation = rotation_delta
			worst_ratio = ratio
	if worst_ratio > 1.0:
		_fail(("equipping ashen bindings displaced %s at the same pinned idle time "
			+ "(position %.8f m, rotation 1-|dot| %.9f; phases %.6f vs %.6f)") % [
			worst_bone,
			worst_position,
			worst_rotation,
			plain_idle.phase_offset,
			equipped_idle.phase_offset,
		])
		return

	print("TEST PASS — ashen bindings stay visible and skinned without changing any pinned body pose")
	get_tree().quit(0)


func _free_if_valid(node: Node) -> void:
	if node != null and is_instance_valid(node):
		node.free()


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
