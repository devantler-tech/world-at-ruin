extends Node3D
## First-party reader evidence with the unmodified Player visual-root path. Seeds owned fixture files, never player saves.

func _ready() -> void:
	var out := OS.get_environment("WAR_STATURE_CAPTURE_DIR")
	if DisplayServer.get_name() == "headless" or not out.is_absolute_path():
		_fail("run windowed with an owned absolute WAR_STATURE_CAPTURE_DIR")
		return
	if DirAccess.make_dir_recursive_absolute(out) != OK:
		_fail("cannot create evidence output")
		return
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.055, 0.065, 0.08)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.82, 0.87, 1.0)
	env.ambient_light_energy = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env_node.environment = env
	add_child(env_node)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35, -25, 0)
	light.light_energy = 1.8
	light.shadow_enabled = true
	add_child(light)
	var floor_mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(20, 0.1, 20)
	floor_mesh.mesh = box
	floor_mesh.position.y = -0.05
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.12, 0.14, 0.17)
	material.roughness = 0.85
	floor_mesh.material_override = material
	add_child(floor_mesh)
	var ui := CanvasLayer.new()
	add_child(ui)
	var names := ["short", "unchanged", "tall"]
	var factors := [0.85, 1.0, 1.2]
	var heights := []
	for index in 3:
		var recipe: Dictionary = CharacterFactory.load_recipe("res://recipes/wanderer.json")
		if index != 1:
			recipe["version"] = 5
			recipe["joint_push"]["thigh"] = factors[index]
			recipe["joint_push"]["calf"] = factors[index]
		# The same shirt and trousers as the historical control; boots expose fit.
		recipe["equipment"]["feet"] = "boots_worn"
		var probe := out.path_join("fixture-%s.json" % names[index])
		var file := FileAccess.open(probe, FileAccess.WRITE)
		if file == null:
			_fail("cannot seed owned evidence fixture")
			return
		var serialized := JSON.stringify(recipe, "  ", true, true)
		file.store_string(serialized)
		file.close()
		var accepted: Variant = CharacterStore.load_from(probe)
		DirAccess.remove_absolute(probe)
		if accepted != JSON.parse_string(serialized):
			_fail("fixture did not survive the real recipe reader")
			return
		var player := Player.new()
		add_child(player)
		player.set_character(accepted)
		player.process_mode = Node.PROCESS_MODE_DISABLED
		var body := player.get("_character_body") as Node3D
		var skeleton := CharacterFactory.find_skeleton(body)
		skeleton.force_update_all_bone_transforms()
		var vertices := CharacterFactory.cpu_skin(skeleton, CharacterFactory.find_skinned_mesh(skeleton))
		var low := INF
		var high := -INF
		for vertex: Vector3 in vertices:
			low = minf(low, vertex.y)
			high = maxf(high, vertex.y)
		heights.append(high - low)
		player.position = Vector3((1 - index) * 1.4, 0, 0)
		var label := Label.new()
		label.text = names[index]
		label.position = Vector2(170 + index * 425, 635)
		label.add_theme_font_size_override("font_size", 24)
		ui.add_child(label)
	if heights[2] - heights[0] < 0.2:
		_fail("rendered evidence has no meaningful stature difference")
		return
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.size = 5.4
	cam.position = Vector3(0, 1.1, -7)
	add_child(cam)
	cam.look_at(Vector3(0, 1.1, 0), Vector3.UP)
	cam.current = true
	for _frame in 60:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var frame := get_viewport().get_texture().get_image()
	if frame == null or frame.save_png(out.path_join("stature-front.png")) != OK:
		_fail("native renderer produced no readable evidence")
		return
	print("TEST PASS — stature capture heights=", heights)
	get_tree().quit(0)


func _fail(message: String) -> void:
	print("TEST FAIL — stature capture: ", message)
	get_tree().quit(1)
