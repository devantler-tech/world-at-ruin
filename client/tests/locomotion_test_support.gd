class_name LocomotionTestSupport
extends RefCounted
## Real Player fixtures for directly driven motion laws. The suite selects its
## flags and may re-enable physics for its runtime-hook scenario.


static func build_subject(parent: Node, recipe: Dictionary, bones: Array, motion: String) -> Dictionary:
	var player := Player.new()
	parent.add_child(player)
	player.set_physics_process(false)
	player.set_character(recipe)
	var skeleton := CharacterFactory.find_skeleton(player.get_node("Visual"))
	if skeleton == null:
		player.free()
		return {"problem": "real Player path built no recipe skeleton"}
	for bone_name: String in bones:
		if skeleton.find_bone(bone_name) < 0:
			player.free()
			return {"problem": "the shipped rig has no required %s bone %s" % [motion, bone_name]}
	var animator := player.get_node_or_null("WalkLocomotion")
	if animator == null:
		player.free()
		var description := "shipping locomotion" if motion == "jump" else "WalkLocomotion"
		return {"problem": "real Player path has no %s driver" % description}
	return {"problem": "", "player": player, "skeleton": skeleton, "animator": animator}


## Compare animation contributions rather than independently imported rests.
static func snapshot(skeleton: Skeleton3D, bones: Array) -> Dictionary:
	var result := {}
	for bone_name: String in bones:
		var bone := skeleton.find_bone(bone_name)
		var rest := skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
		result[bone_name] = rest.inverse() * skeleton.get_bone_pose_rotation(bone)
	return result


## Exact near zero, where angle_to's acos cannot resolve single-precision dust.
static func rotation_distance(a: Quaternion, b: Quaternion) -> float:
	var delta := a.inverse() * b
	return 2.0 * atan2(Vector3(delta.x, delta.y, delta.z).length(), absf(delta.w))


## The caller retains its angle definition and tolerance. In particular jump's
## angle_to contract is distinct from walk's near-zero comparison.
static func pose_difference(a: Dictionary, b: Dictionary, bones: Array, epsilon: float, distance: Callable) -> Dictionary:
	for bone_name: String in bones:
		var apart: float = distance.call(a[bone_name], b[bone_name])
		if apart > epsilon:
			return {"bone": bone_name, "angle": apart}
	return {}
