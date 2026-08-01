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
const LIVE_ELAPSED := 2.25

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
	var pinned_delta := _worst_pose_delta(_global_poses(plain_skeleton), equipped_skeleton)
	if pinned_delta["ratio"] > 1.0:
		_fail(("equipping ashen bindings displaced %s at the same pinned idle time "
			+ "(position %.8f m, rotation 1-|dot| %.9f; phases %.6f vs %.6f)") % [
			pinned_delta["bone"],
			pinned_delta["position"],
			pinned_delta["rotation"],
			plain_idle.phase_offset,
			equipped_idle.phase_offset,
		])
		return

	var failures: Array[String] = []
	var version_failure := _equipment_version_phase_failure(plain_recipe)
	if version_failure != "":
		failures.append(version_failure)
	var live_failure := _live_replacement_pose_failure(plain_recipe)
	if live_failure != "":
		failures.append(live_failure)
	if not failures.is_empty():
		_fail("; ".join(failures))
		return

	print("TEST PASS — ashen bindings stay visible and skinned without changing pinned or live body poses")
	get_tree().quit(0)


## A real creator edit can advance the recipe schema from v1 to v2 (or v3 to
## v4) solely because equipment became representable. Schema metadata is not
## body shape, so that restamp must not change the deterministic idle seed.
func _equipment_version_phase_failure(base_recipe: Dictionary) -> String:
	var plain_recipe := base_recipe.duplicate(true)
	plain_recipe.erase("skin")
	plain_recipe.erase("equipment")
	plain_recipe["version"] = 1
	var equipped_recipe := plain_recipe.duplicate(true)
	equipped_recipe["version"] = 2
	equipped_recipe["equipment"] = { "hands": PIECE }

	var plain := CharacterFactory.build(plain_recipe)
	var equipped := CharacterFactory.build(equipped_recipe)
	if plain == null or equipped == null:
		_free_if_valid(plain)
		_free_if_valid(equipped)
		return "the version-restamp pair could not be built"
	var plain_idle := plain.get_node_or_null("BreathingIdle") as BreathingIdle
	var equipped_idle := equipped.get_node_or_null("BreathingIdle") as BreathingIdle
	if plain_idle == null or equipped_idle == null:
		plain.free()
		equipped.free()
		return "the version-restamp pair has no breathing idle"
	var plain_phase := plain_idle.phase_offset
	var equipped_phase := equipped_idle.phase_offset
	plain.free()
	equipped.free()
	if not is_equal_approx(plain_phase, equipped_phase):
		return ("equipment-only version restamp changed idle phase %.6f -> %.6f"
			% [plain_phase, equipped_phase])
	return ""


## Exercise the shipping replacement path after the old body has actually
## breathed for a while. Equal seeds are insufficient if the new idle restarts
## its elapsed clock when Player replaces the body.
func _live_replacement_pose_failure(base_recipe: Dictionary) -> String:
	var plain_recipe := base_recipe.duplicate(true)
	var equipped_recipe := plain_recipe.duplicate(true)
	(equipped_recipe["equipment"] as Dictionary)["hands"] = PIECE

	var player := Player.new()
	add_child(player)
	player.set_physics_process(false)
	player.set_character(plain_recipe)
	var visual := player.get_node_or_null("Visual")
	if visual == null or visual.get_child_count() != 1:
		player.free()
		return "Player did not build exactly one live body before the outfit edit"
	var outgoing := visual.get_child(0) as Node3D
	var outgoing_skeleton := CharacterFactory.find_skeleton(outgoing)
	var outgoing_idle := outgoing.get_node_or_null("BreathingIdle") as BreathingIdle
	if outgoing_skeleton == null or outgoing_idle == null:
		player.free()
		return "Player's outgoing body has no canonical skeleton or breathing idle"
	outgoing_idle._process(LIVE_ELAPSED)
	outgoing_skeleton.force_update_all_bone_transforms()
	var before := _global_poses(outgoing_skeleton)

	player.set_character(equipped_recipe)
	if visual.get_child_count() != 1:
		player.free()
		return "Player did not leave exactly one live body after the outfit edit"
	var incoming := visual.get_child(0) as Node3D
	var incoming_skeleton := CharacterFactory.find_skeleton(incoming)
	var incoming_idle := incoming.get_node_or_null("BreathingIdle") as BreathingIdle
	if incoming_skeleton == null or incoming_idle == null:
		player.free()
		return "Player's replacement body has no canonical skeleton or breathing idle"
	# Apply the replacement's current clock without advancing another frame.
	incoming_idle._process(0.0)
	incoming_skeleton.force_update_all_bone_transforms()
	var live_delta := _worst_pose_delta(before, incoming_skeleton)
	player.free()
	if live_delta["ratio"] > 1.0:
		return ("live outfit replacement rewound %s after %.2fs "
			+ "(position %.8f m, rotation 1-|dot| %.9f)") % [
			live_delta["bone"],
			LIVE_ELAPSED,
			live_delta["position"],
			live_delta["rotation"],
		]
	return ""


func _global_poses(skeleton: Skeleton3D) -> Array[Transform3D]:
	var poses: Array[Transform3D] = []
	for bone in skeleton.get_bone_count():
		poses.append(skeleton.get_bone_global_pose(bone))
	return poses


func _worst_pose_delta(before: Array[Transform3D], after: Skeleton3D) -> Dictionary:
	if before.size() != after.get_bone_count():
		return {
			"bone": "bone-count",
			"position": INF,
			"rotation": INF,
			"ratio": INF,
		}
	var worst := {
		"bone": "",
		"position": 0.0,
		"rotation": 0.0,
		"ratio": 0.0,
	}
	for bone in after.get_bone_count():
		var after_pose := after.get_bone_global_pose(bone)
		var position_delta := before[bone].origin.distance_to(after_pose.origin)
		var rotation_delta := 1.0 - absf(
			before[bone].basis.get_rotation_quaternion().dot(
				after_pose.basis.get_rotation_quaternion()))
		var ratio := maxf(
			position_delta / POSITION_EPSILON,
			rotation_delta / ROTATION_EPSILON)
		if ratio > worst["ratio"]:
			worst = {
				"bone": after.get_bone_name(bone),
				"position": position_delta,
				"rotation": rotation_delta,
				"ratio": ratio,
			}
	return worst


func _free_if_valid(node: Node) -> void:
	if node != null and is_instance_valid(node):
		node.free()


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
