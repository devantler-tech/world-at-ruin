extends Node
## Exercise the real Player and recipe rig; expected pose and lens are literal.

class Ground:
	extends WorldGen
	var height := 5.0
	func _ready() -> void:
		pass
	func surface_height_at(_x: float, _z: float) -> float:
		return height

func _ready() -> void:
	var capture := load("res://tools/frame_capture.gd") as GDScript
	if not capture.has_method("prepare_motion_capture"):
		_fail("actual capture tool lacks the shared motion rig seam")
		return
	var world := Ground.new()
	add_child(world)
	var player := Player.new()
	add_child(player)
	player.set_character(CharacterFactory.load_recipe("res://recipes/wanderer.json"))
	# The shipped capture waits for boot before adding its inspection camera.
	await get_tree().process_frame
	var skeleton := CharacterFactory.find_skeleton(player.get_node("Visual"))
	var body := player.get("_character_body") as Node
	var idle := body.get_node("BreathingIdle") as BreathingIdle
	idle.set_process(true)
	BreathingIdle.apply_at(skeleton, 0.71)
	var result: Dictionary = capture.call("prepare_motion_capture", player, world, get_tree().root, "walk")
	if not result["problem"].is_empty():
		_fail(result["problem"])
		return
	var camera: Camera3D = result["camera"]
	var chest := skeleton.find_bone("spine_03")
	var focus := skeleton.global_transform * skeleton.get_bone_global_pose(chest).origin
	var target := focus - Vector3(0, 0.45, 0)
	if player.is_physics_processing() or player.control_enabled or idle.is_processing() \
			or not player.global_position.is_equal_approx(Vector3(0, 5.1, 18)) \
			or result["skeleton"] != skeleton or result["left_foot"] != skeleton.find_bone("foot_l") \
			or camera.far != 400.0 or camera.fov != 42.0 \
			or not camera.global_position.is_equal_approx(focus + Vector3(2, 0.5, -3.2)) \
			or not (-camera.global_basis.z).is_equal_approx(camera.global_position.direction_to(target)):
		_fail("motion rig freeze, seating, bones or camera changed")
		return
	var pinned := skeleton.get_bone_pose_rotation(chest)
	BreathingIdle.apply_at(skeleton, 0.0)
	if not pinned.is_equal_approx(skeleton.get_bone_pose_rotation(chest)):
		_fail("capture must pin the actual breath to phase zero")
		return
	camera.free()
	world.height = WorldGen.NO_GROUND
	result = capture.call("prepare_motion_capture", player, world, get_tree().root, "jump")
	if result["problem"] != "the committed jump vantage has no terrain under it" or result.has("camera"):
		_fail("no-ground refusal created a capture camera")
		return
	world.height = 5.0
	player.get_node("Visual").remove_child(body)
	# The detached body is owned here until its refusal has been checked.
	result = capture.call("prepare_motion_capture", player, world, get_tree().root, "walk")
	if result["problem"] != "the shipped Wanderer has no recipe skeleton":
		_fail("missing skeleton must refuse the capture")
		return
	player.get_node("Visual").add_child(body)
	skeleton.set_bone_name(skeleton.find_bone("foot_l"), "missing_foot")
	result = capture.call("prepare_motion_capture", player, world, get_tree().root, "gait-transition")
	if result["problem"] != "the gait-transition evidence rig lacks spine_03 or foot_l" or result.has("camera"):
		_fail("incomplete motion bones must refuse before creating a camera")
		return
	player.free()
	world.free()
	print("TEST PASS — real motion rig freezes input, breath and camera")
	get_tree().quit(0)

func _fail(reason: String) -> void:
	push_error("TEST FAIL — " + reason)
	get_tree().quit(1)
