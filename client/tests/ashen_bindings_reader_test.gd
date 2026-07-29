extends Node
## Reader-expansion contract for the first hand-slot armour (#542, epic #222).
##
## Capability 5 is deliberately asymmetric in this release:
##  1. the real reader registry and CharacterFactory can render `ashen_bindings`;
##  2. the stable update envelope advertises that capability to rollback selection;
##  3. production creation cannot originate the name, even when the existing
##     layered-outfit preview is opted in; and
##  4. an already-present future recipe keeps loading and may be preserved.
##
## Run: godot --headless --path client res://tests/ashen_bindings_reader_test.tscn
## Visual evidence:
##   WAR_ASHEN_BINDINGS_SHOT=/tmp/ashen-bindings.png \
##     godot --path client --resolution 1600x900 \
##     res://tests/ashen_bindings_reader_test.tscn

const PIECE := "ashen_bindings"
const SLOT := "hands"
const PREVIEW_ENV := "WAR_LAYERED_OUTFIT_PICKERS"
const SHOT_ENV := "WAR_ASHEN_BINDINGS_SHOT"
const MANIFEST_SEQUENCE := 43
const MANIFEST_NOT_AFTER := "2026-07-30T12:00:00Z"

var _original_preview := ""


func _ready() -> void:
	_original_preview = OS.get_environment(PREVIEW_ENV)

	var registry := CharacterFactory.equipment_registry()
	var pieces: Dictionary = registry.get("pieces", {})
	if PIECE not in pieces:
		_fail("reader registry has no '%s' hand-slot armour" % PIECE)
		return
	var piece := pieces[PIECE] as Dictionary
	if String(piece.get("slot", "")) != SLOT \
			or String(piece.get("layer", "")) != "armor":
		_fail("reader registry does not place '%s' on hands/armor: %s" % [PIECE, piece])
		return

	# Exercise the real composition path. A registry row with no usable GLB
	# would otherwise look like a reader expansion while rendering nothing.
	var recipe := {
		"version": 2,
		"equipment": {SLOT: PIECE},
	}
	var built := CharacterFactory.build(recipe)
	if built == null:
		_fail("the real CharacterFactory cannot build a recipe carrying '%s'" % PIECE)
		return
	add_child(built)
	var skeleton := CharacterFactory.find_skeleton(built)
	var garment := skeleton.get_node_or_null(
		NodePath(CharacterFactory.EQUIP_PREFIX + PIECE)) as MeshInstance3D
	if garment == null or garment.mesh == null \
			or garment.mesh.get_surface_count() == 0 \
			or garment.mesh.get_blend_shape_count() == 0:
		_fail("the real build attached no skinned, shaped mesh for '%s'" % PIECE)
		return

	# Test the published behavior, not only the source constants: capability 5
	# is readable while capability 4 remains the only production writer.
	var built_manifest := UpdateManifest.build(MANIFEST_SEQUENCE, MANIFEST_NOT_AFTER)
	var manifest := built_manifest.get("manifest", {}) as Dictionary
	if not String(built_manifest.get("error", "")).is_empty() or manifest.is_empty():
		_fail("the reader build could not produce its stable update envelope")
		return
	if int((manifest["shell"] as Dictionary).get("reads_capability_max", -1)) != 5 \
			or int((manifest["save_schema"] as Dictionary).get("capability", -1)) != 4:
		_fail("reader expansion advertises the wrong read/write capabilities: %s/%s" % [
			(manifest["shell"] as Dictionary).get("reads_capability_max"),
			(manifest["save_schema"] as Dictionary).get("capability"),
		])
		return

	var vocabulary := CharacterCreator.writer_vocabulary()
	if PIECE in (vocabulary.get("equipment", {}) as Dictionary):
		_fail("reader-only '%s' entered the production writer vocabulary" % PIECE)
		return
	if CharacterCreator.writer_vocabulary_problem({}, recipe).is_empty():
		_fail("a new recipe can originate reader-only '%s'" % PIECE)
		return
	if not CharacterCreator.writer_vocabulary_problem(recipe, recipe).is_empty():
		_fail("an already-present '%s' recipe cannot be preserved" % PIECE)
		return
	var round_trip_problem := _round_trip_supported_edit(recipe)
	if not round_trip_problem.is_empty():
		_fail(round_trip_problem)
		return

	# Both flag states must stay non-writing during expansion. The flag controls
	# the existing capability-2 layer editor; it is not permission to bypass the
	# capability-5 writer boundary.
	for preview_value: String in ["", "1"]:
		OS.set_environment(PREVIEW_ENV, preview_value)
		var player := Player.new()
		add_child(player)
		var creator := CharacterCreator.new()
		add_child(creator)
		creator.open(player, {"version": 1}, false)
		var portrait_camera := creator._camera
		var portrait_light := creator._light
		if _picker_with(creator, PIECE) != null:
			_fail("preview value '%s' offered reader-only '%s'" % [preview_value, PIECE])
			return
		creator._close(false)
		await get_tree().process_frame
		if is_instance_valid(portrait_camera) or is_instance_valid(portrait_light):
			_fail("preview value '%s' left its portrait rig active before evidence capture" \
				% preview_value)
			return
		player.free()

	var shot_path := OS.get_environment(SHOT_ENV)
	if not shot_path.is_empty():
		if DisplayServer.get_name() == "headless":
			_fail("%s is set, but a headless run cannot render frame evidence" % SHOT_ENV)
			return
		var capture_problem := await _capture_reader_frame(built, shot_path)
		if not capture_problem.is_empty():
			_fail(capture_problem)
			return

	built.free()
	print("TEST PASS — capability-5 reader renders and preserves ashen bindings through real CharacterStore I/O while both creator flag states remain capability-4 writers")
	get_tree().quit(0)


func _capture_reader_frame(built: Node3D, shot_path: String) -> String:
	# The evidence frame renders the same CharacterFactory instance asserted
	# above. It is a reader proof, not a hidden writer or a second preview.
	built.position = Vector3.ZERO
	built.rotation.y = deg_to_rad(-8.0)
	var locomotion := WalkLocomotion.new()
	add_child(locomotion)
	locomotion.bind(built)
	locomotion.apply_phase(PI * 0.5)
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.055, 0.06, 0.075)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.38, 0.42, 0.5)
	environment.ambient_light_energy = 0.34
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world_environment.environment = environment
	add_child(world_environment)

	var key := DirectionalLight3D.new()
	key.light_color = Color(1.0, 0.78, 0.62)
	key.light_energy = 1.45
	key.rotation_degrees = Vector3(-34.0, -28.0, 0.0)
	key.shadow_enabled = true
	add_child(key)

	var rim := DirectionalLight3D.new()
	rim.light_color = Color(0.44, 0.58, 1.0)
	rim.light_energy = 0.72
	rim.rotation_degrees = Vector3(-18.0, 142.0, 0.0)
	add_child(rim)

	var camera := Camera3D.new()
	camera.fov = 38.0
	camera.position = Vector3(0.0, 1.02, 2.45)
	camera.current = true
	add_child(camera)
	camera.look_at(Vector3(0.0, 1.05, 0.0), Vector3.UP)

	for frame in 12:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image == null or image.get_width() < 1 or image.get_height() < 1:
		return "reader evidence rendered no image"
	var error := image.save_png(shot_path)
	if error != OK:
		return "could not write reader evidence to '%s' (error %d)" % [shot_path, error]
	print("CAPTURED ashen_bindings reader -> %s (%dx%d)" % [
		shot_path, image.get_width(), image.get_height()])
	return ""


func _round_trip_supported_edit(recipe: Dictionary) -> String:
	# Seed the future recipe through the public store entry point, take the same
	# byte identity a real editor does, make one already-supported body edit,
	# and write it back through the CAS path. A vocabulary predicate alone
	# cannot prove the reader survives real JSON I/O or the production writer.
	var path := "user://ashen-bindings-reader-%d-%d.json" % [
		OS.get_process_id(), Time.get_ticks_usec()]
	if not CharacterStore.save_to(path, recipe):
		return "could not seed the future '%s' recipe through CharacterStore" % PIECE
	var loaded = CharacterStore.load_from(path)
	if not (loaded is Dictionary):
		_cleanup_io_path(path)
		return "CharacterStore could not read the seeded future '%s' recipe" % PIECE
	var edited := (loaded as Dictionary).duplicate(true)
	edited["shapes"] = {"torso_vshape": 0.35}
	var vocabulary_problem := CharacterCreator.writer_vocabulary_problem(loaded, edited)
	if not vocabulary_problem.is_empty():
		_cleanup_io_path(path)
		return "an ordinary supported edit cannot preserve '%s': %s" % [
			PIECE, vocabulary_problem]
	var identity := CharacterStore.document_identity(path)
	if not CharacterStore.save_to(path, edited, identity):
		_cleanup_io_path(path)
		return "the CAS writer refused an ordinary edit preserving '%s'" % PIECE
	var reloaded = CharacterStore.load_from(path)
	_cleanup_io_path(path)
	if not (reloaded is Dictionary):
		return "the edited future '%s' recipe no longer loads" % PIECE
	var equipment := (reloaded as Dictionary).get("equipment", {}) as Dictionary
	var shapes := (reloaded as Dictionary).get("shapes", {}) as Dictionary
	if String(equipment.get(SLOT, "")) != PIECE \
			or not is_equal_approx(float(shapes.get("torso_vshape", -1.0)), 0.35):
		return "ordinary CharacterStore I/O lost the future piece or the supported edit: %s" \
			% JSON.stringify(reloaded)
	return ""


func _cleanup_io_path(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _picker_with(creator: CharacterCreator, item_name: String) -> OptionButton:
	for node: Node in creator.find_children("*", "OptionButton", true, false):
		var picker := node as OptionButton
		for index in picker.item_count:
			if picker.get_item_text(index) == item_name:
				return picker
	return null


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _exit_tree() -> void:
	OS.set_environment(PREVIEW_ENV, _original_preview)
