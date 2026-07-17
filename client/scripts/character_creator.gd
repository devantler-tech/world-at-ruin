class_name CharacterCreator
extends CanvasLayer
## The character creation screen — the first thing a new wanderer ever does,
## and (early-build testing, maintainer direction 2026-07-17) reachable any
## time with C to reshape the character.
##
## No separate scene, no loading screen: the world stays live behind it. The
## player's own in-world body is the preview — shape sliders drive its blend
## weights immediately; bone sliders rebuild the body on release (bone edits
## are rest-pose surgery, not a per-frame knob). A portrait camera and a
## soft key light are brought along and removed on close.

signal applied(recipe: Dictionary)
signal closed

const COL_BONE := Color(0.88, 0.84, 0.76)
const COL_DIM := Color(0.88, 0.84, 0.76, 0.55)
const COL_EMBER := Color(1.0, 0.62, 0.25)

const PRESET_DIR := "res://recipes/"
const PRESETS := ["wanderer", "villager", "brute"]

## Bone sliders: label, recipe field, bone key, range. Kept deliberately
## short — the interesting range of each op before skinning artifacts.
const BONE_SLIDERS := [
	["shoulders", "joint_push", "upperarm", 0.94, 1.15],
	["hands", "bone_scale", "hand", 0.9, 1.35],
	["feet", "bone_scale", "foot", 0.9, 1.25],
	["head", "bone_scale", "head", 0.92, 1.12],
	["forearms", "bone_girth", "lowerarm", 0.9, 1.25],
	["calves", "bone_girth", "calf", 0.9, 1.25],
]

var first_run := false

var _player: Player
var _recipe: Dictionary
var _shape_sliders := {}
var _bone_sliders := {}
var _camera: Camera3D
var _light: DirectionalLight3D
var _syncing := false


## Builds and shows the creator over a live player. `initial` is the starting
## recipe (the saved character, or the wanderer preset for a first run).
func open(player: Player, initial: Dictionary, p_first_run: bool) -> void:
	_player = player
	_recipe = initial.duplicate(true)
	first_run = p_first_run
	_player.control_enabled = false
	_player.set_character(_recipe)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_portrait_rig()
	_build_panel()
	_sync_sliders_from_recipe()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and not first_run:
		_close(false)
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	# Track the body — it settles onto the floor for a few ticks after spawn.
	if _camera != null and _player != null:
		var eye := _player.global_position + Vector3(0, 1.0, 0)
		_camera.look_at(eye, Vector3.UP)


func _build_portrait_rig() -> void:
	var eye := _player.global_position + Vector3(0, 1.25, 0)
	# The third-person camera sits behind the body looking the way it faces,
	# so "in front of the face" is one camera-forward step ahead of the body.
	var view := _player.get_viewport().get_camera_3d()
	var forward := -view.global_transform.basis.z if view != null else Vector3.FORWARD
	forward.y = 0.0
	forward = forward.normalized() if forward.length() > 0.01 else Vector3.FORWARD
	# Parent the rig next to the player — current_scene is null under test
	# harnesses that instance main.tscn by hand.
	var stage := _player.get_parent()
	_camera = Camera3D.new()
	_camera.fov = 45.0
	stage.add_child(_camera)
	_camera.global_position = eye + forward * 3.4 + Vector3(0.5, 0.0, 0.0).rotated(Vector3.UP, atan2(forward.x, forward.z))
	_camera.look_at(eye, Vector3.UP)
	_camera.make_current()

	_light = DirectionalLight3D.new()
	_light.light_color = Color(1.0, 0.9, 0.78)
	_light.light_energy = 1.4
	stage.add_child(_light)
	_light.global_position = _camera.global_position + Vector3(0, 2, 0)
	_light.look_at(eye, Vector3.UP)


func _build_panel() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	panel.custom_minimum_size = Vector2(360, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.06, 0.055, 0.93)
	style.border_color = Color(0.55, 0.35, 0.18)
	style.set_border_width_all(1)
	style.set_content_margin_all(14)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	panel.add_child(column)

	var title := Label.new()
	title.text = "SHAPE YOUR WANDERER" if first_run else "RESHAPE YOUR WANDERER"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", COL_EMBER)
	column.add_child(title)

	var blurb := Label.new()
	blurb.text = "This body is yours to keep — it can always be reshaped here (C)."
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.add_theme_font_size_override("font_size", 12)
	blurb.add_theme_color_override("font_color", COL_DIM)
	column.add_child(blurb)

	var presets_row := HBoxContainer.new()
	presets_row.add_theme_constant_override("separation", 8)
	column.add_child(presets_row)
	for preset_name in PRESETS:
		var b := Button.new()
		b.text = preset_name
		b.pressed.connect(_on_preset.bind(preset_name))
		presets_row.add_child(b)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(330, 380)
	column.add_child(scroll)
	var sliders := VBoxContainer.new()
	sliders.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sliders.add_theme_constant_override("separation", 2)
	scroll.add_child(sliders)

	_add_heading(sliders, "BUILD")
	for shape_name in _shape_names():
		_add_shape_slider(sliders, shape_name)
	_add_heading(sliders, "FRAME")
	for spec: Array in BONE_SLIDERS:
		_add_bone_slider(sliders, spec)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	column.add_child(buttons)
	var apply := Button.new()
	apply.text = "Wake" if first_run else "Apply"
	apply.pressed.connect(func() -> void: _close(true))
	buttons.add_child(apply)
	if not first_run:
		var cancel := Button.new()
		cancel.text = "Cancel (Esc)"
		cancel.pressed.connect(func() -> void: _close(false))
		buttons.add_child(cancel)


func _add_heading(into: Container, text: String) -> void:
	var heading := Label.new()
	heading.text = text
	heading.add_theme_font_size_override("font_size", 13)
	heading.add_theme_color_override("font_color", COL_EMBER)
	into.add_child(heading)


func _add_shape_slider(into: Container, shape_name: String) -> void:
	var slider := _labeled_slider(into, shape_name.replace("_", " "), -0.5, 1.2)
	slider.value_changed.connect(func(v: float) -> void:
		if _syncing:
			return
		_set_recipe_shape(shape_name, v)
		var mesh := _player.character_mesh()
		if mesh != null:
			var idx := mesh.find_blend_shape_by_name(shape_name)
			if idx >= 0:
				mesh.set_blend_shape_value(idx, v))
	_shape_sliders[shape_name] = slider


func _add_bone_slider(into: Container, spec: Array) -> void:
	var slider := _labeled_slider(into, spec[0], spec[3], spec[4])
	slider.drag_ended.connect(func(changed: bool) -> void:
		if changed and not _syncing:
			_set_recipe_bone(spec[1], spec[2], slider.value)
			_player.set_character(_recipe))
	_bone_sliders[spec[0]] = slider


func _labeled_slider(into: Container, text: String, minimum: float, maximum: float) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	into.add_child(row)
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(130, 0)
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", COL_BONE)
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = 0.01
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)
	return slider


## The kit's shape list, straight from the live mesh — the creator never goes
## stale when the kit gains shapes.
func _shape_names() -> PackedStringArray:
	var names := PackedStringArray()
	var mesh := _player.character_mesh()
	if mesh != null:
		for i in mesh.mesh.get_blend_shape_count():
			names.append(String(mesh.mesh.get_blend_shape_name(i)))
	return names


func _set_recipe_shape(shape_name: String, value: float) -> void:
	if not _recipe.has("shapes"):
		_recipe["shapes"] = {}
	if is_zero_approx(value):
		_recipe["shapes"].erase(shape_name)
	else:
		_recipe["shapes"][shape_name] = value


func _set_recipe_bone(field: String, key: String, value: float) -> void:
	if not _recipe.has(field):
		_recipe[field] = {}
	if is_equal_approx(value, 1.0):
		_recipe[field].erase(key)
	else:
		_recipe[field][key] = value


func _on_preset(preset_name: String) -> void:
	var recipe = CharacterFactory.load_recipe(PRESET_DIR + preset_name + ".json")
	if recipe == null:
		return
	_recipe = recipe.duplicate(true)
	_recipe.erase("comment")
	_player.set_character(_recipe)
	_sync_sliders_from_recipe()


func _sync_sliders_from_recipe() -> void:
	_syncing = true
	var shapes: Dictionary = _recipe.get("shapes", {})
	for shape_name: String in _shape_sliders:
		(_shape_sliders[shape_name] as HSlider).value = shapes.get(shape_name, 0.0)
	for spec: Array in BONE_SLIDERS:
		(_bone_sliders[spec[0]] as HSlider).value = _recipe.get(spec[1], {}).get(spec[2], 1.0)
	_syncing = false


func _close(apply_changes: bool) -> void:
	if apply_changes:
		applied.emit(_recipe)
	elif not first_run:
		# Rebuild the body the recipe on disk describes.
		var saved = CharacterStore.load_saved()
		if saved is Dictionary:
			_player.set_character(saved)
	_player.control_enabled = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _camera != null:
		_camera.queue_free()
	if _light != null:
		_light.queue_free()
	closed.emit()
	queue_free()
