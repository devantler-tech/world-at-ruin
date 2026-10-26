extends Node
## Regression test for character persistence (issue #24 stage 3): the saved
## recipe is player state under the no-resets law.
##  1. Save → load round-trips to an identical character (fingerprint).
##  2. A missing save reads as null (the first-run path).
##  3. A recipe from a NEWER client version refuses to load into a character
##     rather than half-applying (CharacterFactory validation through the
##     store path).
##  4. A save the PREVIOUS engine wrote loads unchanged under this one (#1454):
##     the committed fixture's bytes were written by CharacterStore.save_to
##     under Godot 4.7.1, so a run on a newer engine observes the cross-engine
##     load itself rather than a same-engine round trip.
##
## The store's real save/load logic is exercised through a throwaway probe
## file (save_to/load_from), so the player's own user://character.json is
## never touched — a test can never strand a character (no-resets law).
##
## Run: godot --headless --path client res://tests/character_persistence_test.tscn

const PROBE := "user://persistence_probe.json"
const PREVIOUS_ENGINE_SAVE := "res://tests/data/engine_4_7_1_saved_character.json"


func _ready() -> void:
	_cleanup_probe()
	if CharacterStore.load_from(PROBE) != null:
		_fail("missing save did not read as null")
		return

	var recipe = CharacterFactory.load_recipe("res://recipes/wanderer.json")
	if recipe is not Dictionary:
		_fail("wanderer preset unreadable")
		return
	if not CharacterStore.save_to(PROBE, recipe):
		_fail("save failed")
		return
	var loaded = CharacterStore.load_from(PROBE)
	if loaded is not Dictionary:
		_fail("saved recipe did not load")
		return

	var direct := CharacterFactory.build(recipe)
	var restored := CharacterFactory.build(loaded)
	if direct == null or restored == null:
		_fail("recipe failed to build (direct=%s restored=%s)" % [direct != null, restored != null])
		return
	var fp_direct := CharacterFactory.fingerprint(direct)
	var fp_restored := CharacterFactory.fingerprint(restored)
	if fp_direct != fp_restored:
		_fail("save/load changed the character:\n  %s\n  %s" % [fp_direct, fp_restored])
		return
	direct.free()
	restored.free()

	# A save written by the previous engine must load, and must be the same
	# character this engine's own save/load round trip of it produces.
	var engine_save = CharacterStore.load_from(PREVIOUS_ENGINE_SAVE)
	if engine_save is not Dictionary:
		_fail("the 4.7.1-written save did not load")
		return
	if not CharacterStore.save_to(PROBE, engine_save):
		_fail("the 4.7.1-written save could not be saved again")
		return
	var resaved = CharacterStore.load_from(PROBE)
	if resaved != engine_save:
		_fail("re-saving the 4.7.1-written save changed the recipe")
		return
	var old_build := CharacterFactory.build(engine_save)
	var new_build := CharacterFactory.build(resaved)
	if old_build == null or new_build == null:
		_fail(
			(
				"4.7.1-written save failed to build (old=%s new=%s)"
				% [old_build != null, new_build != null]
			)
		)
		return
	var fp_old := CharacterFactory.fingerprint(old_build)
	var fp_new := CharacterFactory.fingerprint(new_build)
	old_build.free()
	new_build.free()
	if fp_old != fp_new:
		_fail("the 4.7.1-written save built a different character:\n  %s\n  %s" % [fp_old, fp_new])
		return

	# A future-version recipe must be refused, not half-applied.
	var future: Dictionary = recipe.duplicate(true)
	future["version"] = CharacterFactory.RECIPE_VERSION + 1
	# Written raw because the production writer must reject a document this
	# build cannot read back; this fixture must already exist before load_from().
	if not _write_text(PROBE, JSON.stringify(future, "  ")):
		_fail("could not seed the future-version recipe")
		return
	var reloaded = CharacterStore.load_from(PROBE)
	if reloaded is Dictionary:
		var built := CharacterFactory.build(reloaded)
		if built != null:
			built.free()
			_fail("a future-version recipe built on an old client")
			return

	_cleanup_probe()
	print("TEST PASS — %s" % fp_direct)
	get_tree().quit(0)


func _fail(message: String) -> void:
	_cleanup_probe()
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _exit_tree() -> void:
	_cleanup_probe()


func _cleanup_probe() -> void:
	PersistenceTestSupport.remove_file(PROBE)


func _write_text(path: String, text: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	file.close()
	return true
