extends Node
## The close-inspection plan is fixed and distinct from established cameras.
## This tests the production plan, including front/rear and gameplay distance.


## Check production camera offsets and challenge the garment-only metric with
## synthetic positive and negative controls before accepting the capture plan.
func _ready() -> void:
	var script := load("res://tools/frame_capture.gd") as GDScript
	var capture := script.new() as Node
	if not capture.has_method("ragged_cloth_capture_plan"):
		_fail("actual capture tool has no ragged-cloth inspection plan")
		capture.free()
		return
	var plan: Array = capture.call("ragged_cloth_capture_plan")
	if plan.size() != 4 or plan[0][0] != "cloth_front" or plan[1][0] != "cloth_rear" or plan[2][0] != "cloth_profile" or plan[3][0] != "cloth_gameplay":
		_fail("fixed inspection plan must include both panels, a silhouette profile and gameplay range")
	elif Vector3(plan[0][1]).z * Vector3(plan[1][1]).z >= 0.0:
		_fail("front and rear cameras must face opposite garment panels")
	else:
		if not _camera_controls(capture):
			capture.free()
			return
		if not _pixel_controls(capture):
			capture.free()
			return
		if not _geometry_controls(capture):
			capture.free()
			return
		print("TEST PASS — ragged-cloth evidence frames both panels and gameplay range")
		get_tree().quit(0)
	capture.free()


## Gameplay evidence must use the production follow rig without moving it or
## replacing its projection; only the two inspection views use the close lens.
func _camera_controls(capture: Node) -> bool:
	if not capture.has_method("ragged_cloth_camera"):
		_fail("cloth gameplay evidence cannot select the production follow camera")
		return false
	var player := Player.new()
	add_child(player)
	player.set_physics_process(false)
	player.set_process(false)
	var follow := player.get("_camera") as Camera3D
	var spring := player.get("_spring") as SpringArm3D
	var original := follow.transform
	var inspection := Camera3D.new()
	inspection.fov = 36.0
	add_child(inspection)
	var gameplay := capture.call("ragged_cloth_camera", "cloth_gameplay", inspection, player) as Camera3D
	var valid := gameplay == follow and is_equal_approx(gameplay.fov, 70.0) and is_equal_approx(spring.spring_length, 4.6)
	valid = valid and gameplay.projection == Camera3D.PROJECTION_PERSPECTIVE and follow.transform == original
	for view: String in ["cloth_front", "cloth_rear", "cloth_profile"]:
		valid = valid and capture.call("ragged_cloth_camera", view, inspection, player) == inspection
	valid = valid and inspection.fov == 36.0
	inspection.free()
	player.free()
	if not valid:
		_fail("cloth gameplay must retain the actual 70-degree, 4.6-metre follow rig")
	return valid


## Only actual garment marker pixels may contribute to the read. An unrelated
## background change must measure zero, while a changed garment must not.
func _pixel_controls(capture: Node) -> bool:
	var mask := Image.create(8, 8, false, Image.FORMAT_RGB8)
	mask.fill(Color.BLACK)
	if not capture.call("ragged_cloth_pixels", mask).is_empty():
		_fail("an absent garment must produce no mask points")
		return false
	mask.set_pixel(2, 2, Color.MAGENTA)
	var points: Array[Vector2i] = capture.call("ragged_cloth_pixels", mask)
	if points != [Vector2i(2, 2)]:
		_fail("mask sampling must name only the drawn garment pixel")
		return false
	for point: Vector2i in [Vector2i(2, 3), Vector2i(3, 2), Vector2i(3, 3)]:
		mask.set_pixelv(point, Color.MAGENTA)
	if capture.call("ragged_cloth_pixels", mask, 1).size() != 4:
		_fail("minified gameplay must inspect every garment pixel without background samples")
		return false
	var a := Image.create(8, 8, false, Image.FORMAT_RGB8)
	a.fill(Color.BLACK)
	var b := a.duplicate() as Image
	b.set_pixel(4, 4, Color.WHITE)
	if capture.call("ragged_cloth_difference", a, b, points) != 0.0:
		_fail("background-only changes must not masquerade as material detail")
		return false
	b.set_pixel(2, 2, Color.WHITE)
	if capture.call("ragged_cloth_difference", a, b, points) < 0.9:
		_fail("the evidence metric must detect a changed garment")
		return false
	return true


## Fail through the canonical scene-runner marker as well as the exit status.
func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — " + message)
	get_tree().quit(1)


## Swapping the ablation mesh must not reset the player's actual morphs;
## evidence with a different body shape would confound geometry with recipes.
func _geometry_controls(capture: Node) -> bool:
	if not capture.has_method("ragged_cloth_swap_mesh") or not capture.has_method("ragged_cloth_union_pixels"):
		_fail("geometry evidence needs morph-preserving swapping and both silhouettes")
		return false
	var character := CharacterFactory.build({"version": 1, "shapes": {"hips_wide": 0.8}})
	var garment := CharacterFactory.find_skeleton(character).get_node("Equip_loincloth_ragged") as MeshInstance3D
	var index := garment.find_blend_shape_by_name("hips_wide")
	var source := garment.mesh
	capture.call("ragged_cloth_swap_mesh", garment, source.duplicate())
	var valid := is_equal_approx(garment.get_blend_shape_value(index), 0.8)
	capture.call("ragged_cloth_swap_mesh", garment, source)
	valid = valid and is_equal_approx(garment.get_blend_shape_value(index), 0.8)
	character.free()
	var a := Image.create(8, 8, false, Image.FORMAT_RGB8)
	a.fill(Color.BLACK)
	var b := a.duplicate() as Image
	a.set_pixel(2, 2, Color.MAGENTA)
	b.set_pixel(3, 3, Color.MAGENTA)
	var union: Array = capture.call("ragged_cloth_union_pixels", a, b, 1)
	valid = valid and union.size() == 2 and Vector2i(2, 2) in union and Vector2i(3, 3) in union
	if not valid:
		_fail("the geometry arm must preserve actual morphs and inspect both silhouettes")
	return valid
