extends Node
## Writer contract for the first hand-slot armour (#544, epic #222).
##
## Capability 5 has a retained reader and an explicitly guarded writer:
##  1. the real reader registry and CharacterFactory can render `ashen_bindings`;
##  2. the stable update envelope advertises project-wide capability 6
##     reads/writes without removing the capability-5 character vocabulary;
##  3. the shipped default creator cannot originate the preview-only hand piece;
##  4. the explicit layered-outfit preview can select, apply, save and reload it.
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
	# character vocabulary remains writable after the separate vault contract
	# advances the project-wide envelope to capability 6.
	var built_manifest := UpdateManifest.build(MANIFEST_SEQUENCE, MANIFEST_NOT_AFTER, WireCodec.LEGACY_VERSION, WireCodec.VERSION)
	var manifest := built_manifest.get("manifest", {}) as Dictionary
	if not String(built_manifest.get("error", "")).is_empty() or manifest.is_empty():
		_fail("the reader build could not produce its stable update envelope")
		return
	if int((manifest["shell"] as Dictionary).get("reads_capability_max", -1)) != 6 \
			or int((manifest["save_schema"] as Dictionary).get("capability", -1)) != 6:
		_fail("active contracts advertise the wrong read/write capabilities: %s/%s" % [
			(manifest["shell"] as Dictionary).get("reads_capability_max"),
			(manifest["save_schema"] as Dictionary).get("capability"),
		])
		return

	var vocabulary := CharacterCreator.writer_vocabulary()
	if String((vocabulary.get("equipment", {}) as Dictionary).get(PIECE, "")) != SLOT:
		_fail("writer vocabulary does not activate '%s -> %s'" % [PIECE, SLOT])
		return
	if not CharacterCreator.writer_vocabulary_problem({}, recipe).is_empty():
		_fail("a new recipe cannot originate activated '%s'" % PIECE)
		return
	if not CharacterCreator.writer_vocabulary_problem(recipe, recipe).is_empty():
		_fail("an already-present '%s' recipe cannot be preserved" % PIECE)
		return
	var round_trip_problem := _round_trip_supported_edit(recipe)
	if not round_trip_problem.is_empty():
		_fail(round_trip_problem)
		return
	built.free()

	# The raw layered controls remain opt-in. A plain boot must not expose this
	# below-bar preview piece through the single-region default surface.
	OS.set_environment(PREVIEW_ENV, "")
	var default_player := Player.new()
	add_child(default_player)
	var default_creator := CharacterCreator.new()
	add_child(default_creator)
	default_creator.open(default_player, {"version": 1}, false)
	if _picker_with(default_creator, PIECE) != null:
		_fail("the default creator offered preview-only '%s'" % PIECE)
		return
	default_creator._close(false)
	await get_tree().process_frame
	default_player.free()

	# The explicit preview drives the real OptionButton and apply signal, then
	# persists that emitted recipe through CharacterStore and reads it back.
	OS.set_environment(PREVIEW_ENV, "1")
	var player := Player.new()
	add_child(player)
	var creator := CharacterCreator.new()
	add_child(creator)
	creator.open(player, {"version": 1}, false)
	var picker := _picker_with(creator, PIECE)
	if picker == null or picker.disabled:
		_fail("the layered-outfit preview did not expose enabled '%s'" % PIECE)
		return
	if not _select_item(picker, PIECE):
		return
	var applied_recipes: Array = []
	creator.applied.connect(func(candidate: Dictionary) -> void:
		applied_recipes.append(candidate.duplicate(true)))

	var shot_path := OS.get_environment(SHOT_ENV)
	if not shot_path.is_empty():
		if DisplayServer.get_name() == "headless":
			_fail("%s is set, but a headless run cannot render frame evidence" % SHOT_ENV)
			return
		var capture_problem := await _capture_writer_frame(creator, shot_path)
		if not capture_problem.is_empty():
			_fail(capture_problem)
			return

	creator._close(true)
	await get_tree().process_frame
	if applied_recipes.size() != 1:
		_fail("the real apply path emitted %d recipes; expected one" % applied_recipes.size())
		return
	var writer_problem := _write_and_reload(applied_recipes[0] as Dictionary)
	if not writer_problem.is_empty():
		_fail(writer_problem)
		return
	player.free()

	print("TEST PASS — capability-5 writer keeps ashen bindings preview-only while the opt-in creator applies, saves and reloads the hand armour")
	get_tree().quit(0)


func _capture_writer_frame(creator: CharacterCreator, shot_path: String) -> String:
	creator.expand_all_sections()
	for frame in 12:
		await get_tree().process_frame
	var pose_problem := _pose_writer_evidence(creator)
	if not pose_problem.is_empty():
		return pose_problem
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image == null or image.get_width() < 1 or image.get_height() < 1:
		return "reader evidence rendered no image"
	var error := image.save_png(shot_path)
	if error != OK:
		return "could not write reader evidence to '%s' (error %d)" % [shot_path, error]
	print("CAPTURED ashen_bindings writer -> %s (%dx%d)" % [
		shot_path, image.get_width(), image.get_height()])
	return ""


func _pose_writer_evidence(creator: CharacterCreator) -> String:
	# The rest pose hides both hand slots behind the torso from the portrait
	# camera. Pose the SAME runtime skeleton through its shipped locomotion
	# driver so the captured frame proves the selected bindings render on the
	# character instead of proving only that the OptionButton says they do.
	if creator._player == null:
		return "writer evidence has no preview player to pose"
	var locomotion := creator._player.get_node_or_null("WalkLocomotion") as WalkLocomotion
	if locomotion == null:
		return "writer evidence has no runtime locomotion driver"
	locomotion.apply_phase(0.0, true)
	return ""


func _write_and_reload(recipe: Dictionary) -> String:
	var path := "user://ashen-bindings-writer-%d-%d.json" % [
		OS.get_process_id(), Time.get_ticks_usec()]
	if not CharacterStore.save_to(path, recipe):
		return "CharacterStore refused the recipe emitted by the real preview apply path"
	var reloaded = CharacterStore.load_from(path)
	_cleanup_io_path(path)
	if not (reloaded is Dictionary):
		return "CharacterStore could not reload the recipe emitted by the preview"
	var equipment := (reloaded as Dictionary).get("equipment", {}) as Dictionary
	if String(equipment.get(SLOT, "")) != PIECE:
		return "CharacterStore reload lost '%s': %s" % [PIECE, JSON.stringify(reloaded)]
	var rebuilt := CharacterFactory.build(reloaded)
	if rebuilt == null:
		return "CharacterFactory could not rebuild the reloaded '%s' recipe" % PIECE
	rebuilt.free()
	return ""


func _round_trip_supported_edit(recipe: Dictionary) -> String:
	# Seed the activated recipe through the public store entry point, take the same
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


func _select_item(picker: OptionButton, item_name: String) -> bool:
	for index in picker.item_count:
		if picker.get_item_text(index) == item_name:
			picker.select(index)
			picker.item_selected.emit(index)
			return true
	_fail("the picker does not offer '%s'" % item_name)
	return false


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _exit_tree() -> void:
	OS.set_environment(PREVIEW_ENV, _original_preview)
