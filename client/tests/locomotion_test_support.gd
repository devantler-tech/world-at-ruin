class_name LocomotionTestSupport
extends RefCounted
## Real Player fixtures for directly driven motion laws. The suite selects its
## flags and may re-enable physics for its runtime-hook scenario.


static func recipe_fixture(path: String) -> Dictionary:
	var loaded = CharacterFactory.load_recipe(path)
	if loaded is not Dictionary:
		return {"problem": "could not load %s" % path}
	return {"problem": "", "recipe": loaded}


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


## Report the first difference through the caller's existing failure method.
## Empty messages still return false without emitting a failure, and the caller
## retains its bone list, epsilon and distinct rotation-distance definition.
static func same_pose(a: Dictionary, b: Dictionary, bones: Array, epsilon: float, distance: Callable, message: String, fail: Callable) -> bool:
	var difference := pose_difference(a, b, bones, epsilon, distance)
	if not difference.is_empty():
		return fail.call("%s (%s differs by %.6f rad)" %
			[message, difference["bone"], difference["angle"]]) if not message.is_empty() else false
	return true
