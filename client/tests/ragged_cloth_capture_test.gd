extends Node
## The close-inspection plan is fixed and distinct from established cameras.
## This tests the production plan, including front/rear and gameplay distance.


## Check production camera offsets and challenge the garment-only metric with
## synthetic positive and negative controls before accepting the capture plan.
func _ready() -> void:
	var script := load("res://tools/frame_capture.gd") as GDScript
	var capture := script.new() as Node
	if not capture.has_method("ragged_cloth_capture_plan") or not capture.has_method("ragged_drape_capture_plan"):
		_fail("actual capture tool has no ragged-cloth inspection plan")
		capture.free()
		return
	var material_plan: Array = capture.call("ragged_cloth_capture_plan")
	if material_plan.size() != 3 or material_plan[0][0] != "cloth_front" or material_plan[1][0] != "cloth_rear" or material_plan[2][0] != "cloth_gameplay":
		_fail("the established material plan must retain front, rear and gameplay range")
		capture.free()
		return
	var plan: Array = capture.call("ragged_drape_capture_plan")
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
		if not _tailoring_controls(capture):
			capture.free()
			return
		if not _fold_controls(capture):
			capture.free()
			return
		if not _disabled_material_controls(capture):
			capture.free()
			return
		print("TEST PASS — ragged-cloth evidence frames both panels and gameplay range")
		get_tree().quit(0)
	capture.free()

## Disabled detail must copy the active material without consulting source
## metadata. A stale source is irrelevant when the experiment is off.
func _disabled_material_controls(capture: Node) -> bool:
	var state := TestEnvironment.snapshot([RaggedCloth.FLAG_ENV])
	OS.set_environment(RaggedCloth.FLAG_ENV, "")
	var garment := MeshInstance3D.new()
	garment.mesh = BoxMesh.new()
	var original := StandardMaterial3D.new()
	original.albedo_color = Color(0.3, 0.4, 0.5)
	original.roughness = 0.37
	garment.set_surface_override_material(0, original)
	garment.set_meta(RaggedDrape.SOURCE_META, "unused stale metadata")
	var valid := true
	for method: String in ["ragged_tailoring_material", "ragged_unfolded_material"]:
		var copied := capture.call(method, garment) as StandardMaterial3D
		valid = valid and copied != original and copied.albedo_color == original.albedo_color
		valid = valid and copied.roughness == original.roughness and garment.get_active_material(0) == original
	garment.free()
	TestEnvironment.restore(state)
	if not valid:
		_fail("disabled cloth must copy the active material without mutating it")
	return valid


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


## A flat generic material or a swapped mesh cannot isolate broad folds.
## Sewing bands stay byte-identical, while broad hanging normals must change.
func _fold_controls(capture: Node) -> bool:
	var fixture := RaggedTestSupport.preview_fixture()
	var garment: MeshInstance3D = fixture["garment"]
	var mesh: Mesh = fixture["mesh"]
	var preview: StandardMaterial3D = fixture["preview"]
	var ablation := capture.call("ragged_unfolded_material", garment) as StandardMaterial3D
	var valid := RaggedTestSupport.retained_settings(garment, mesh, preview, ablation)
	valid = valid and ablation.normal_enabled
	valid = valid and ablation.roughness_texture.get_image().get_data() == preview.roughness_texture.get_image().get_data()
	var drawn := preview.albedo_texture.get_image()
	var unfolded := ablation.albedo_texture.get_image()
	for y: int in [184, 285]:
		for x in range(205, 820):
			valid = valid and drawn.get_pixel(x, y) == unfolded.get_pixel(x, y)
	var normal := preview.normal_texture.get_image()
	var flat := ablation.normal_texture.get_image()
	var changed := 0
	for y in range(380, 650, 4):
		for x in range(365, 662, 4):
			if absf(normal.get_pixel(x, y).r - flat.get_pixel(x, y).r) > 0.10:
				changed += 1
	valid = valid and changed > 500 and flat.get_mipmap_count() > 0
	RaggedTestSupport.release_fixture(fixture)
	if not valid:
		_fail("fold-off must remove broad relief while retaining sewing, weave, mesh and render settings")
	return valid


## A tailoring ablation must retain the actual cloth colour, weave, geometry
## and render settings. A generic flat material cannot isolate sewn threads.
func _tailoring_controls(capture: Node) -> bool:
	if not capture.has_method("ragged_tailoring_material"):
		_fail("tailoring evidence needs an independent weave-only ablation")
		return false
	var fixture := RaggedTestSupport.preview_fixture()
	var garment: MeshInstance3D = fixture["garment"]
	var mesh: Mesh = fixture["mesh"]
	var preview: StandardMaterial3D = fixture["preview"]
	var ablation := capture.call("ragged_tailoring_material", garment) as StandardMaterial3D
	var valid := RaggedTestSupport.retained_settings(garment, mesh, preview, ablation)
	valid = valid and ablation.normal_enabled
	var drawn := preview.albedo_texture.get_image()
	var plain := ablation.albedo_texture.get_image()
	var drawn_roughness := preview.roughness_texture.get_image()
	var plain_roughness := ablation.roughness_texture.get_image()
	# Sewing changes seam roughness; untouched weave texels must stay identical.
	for point: Vector2i in [Vector2i(400, 400), Vector2i(600, 620), Vector2i(500, 500)]:
		valid = valid and drawn.get_pixelv(point) == plain.get_pixelv(point)
		valid = valid and drawn_roughness.get_pixelv(point) == plain_roughness.get_pixelv(point)
	var changed := 0
	for x in range(205, 820):
		if drawn.get_pixel(x, 184).r - plain.get_pixel(x, 184).r > 0.04:
			changed += 1
	valid = valid and changed > 200 and plain.get_mipmap_count() > 0
	RaggedTestSupport.release_fixture(fixture)
	if not valid:
		_fail("seam-off must remove visible threads while retaining actual weave and render settings")
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
	if not capture.has_method("ragged_tailoring_difference"):
		_fail("sparse tailoring needs a localized garment-only metric")
		return false
	var local_points: Array[Vector2i] = []
	for y in range(2, 6):
		for x in range(2, 6):
			local_points.append(Vector2i(x, y))
	b.fill(Color.BLACK)
	b.set_pixel(0, 0, Color.WHITE)
	if capture.call("ragged_tailoring_difference", a, b, local_points) != 0.0:
		_fail("sparse tailoring metric must reject scenery changes")
		return false
	b.set_pixel(2, 2, Color.WHITE)
	b.set_pixel(3, 3, Color.WHITE)
	if capture.call("ragged_tailoring_difference", a, b, local_points) < 0.9:
		_fail("localized garment construction must not disappear into unchanged cloth")
		return false
	if capture.call("ragged_tailoring_difference", a, a, local_points) != 0.0:
		_fail("identical cloth must not produce a tailoring signal")
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
