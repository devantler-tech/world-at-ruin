extends Node
## Regression test for character persistence (issue #24 stage 3): the saved
## recipe is player state under the no-resets law.
##  1. Save → load round-trips to an identical character (fingerprint).
##  2. A missing save reads as null (the first-run path).
##  3. A recipe from a NEWER client version refuses to load into a character
##     rather than half-applying (CharacterFactory validation through the
##     store path).
##
## Run: godot --headless --path client res://tests/character_persistence_test.tscn


func _ready() -> void:
	if not _backup_live_save():
		_fail("could not back up the live character save — refusing to touch it")
		return
	CharacterStore.clear()
	if CharacterStore.load_saved() != null:
		_fail("missing save did not read as null")
		return

	var recipe = CharacterFactory.load_recipe("res://recipes/wanderer.json")
	if recipe is not Dictionary:
		_fail("wanderer preset unreadable")
		return
	if not CharacterStore.save_recipe(recipe):
		_fail("save failed")
		return
	var loaded = CharacterStore.load_saved()
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

	# A future-version recipe must be refused, not half-applied.
	var future: Dictionary = recipe.duplicate(true)
	future["version"] = CharacterFactory.RECIPE_VERSION + 1
	CharacterStore.save_recipe(future)
	var reloaded = CharacterStore.load_saved()
	if reloaded is Dictionary:
		var built := CharacterFactory.build(reloaded)
		if built != null:
			built.free()
			_fail("a future-version recipe built on an old client")
			return

	CharacterStore.clear()
	_restore_live_save()
	print("TEST PASS — %s" % fp_direct)
	get_tree().quit(0)


func _fail(message: String) -> void:
	_restore_live_save()
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
## The tests exercise first-run flows by clearing the save — but a LIVE
## character save is player state (no-resets law): back it up first and put
## it back whatever happens. CRASH-SAFE: a stale backup from a killed run is
## restored (never clobbered) before a new backup is taken, the copy is
## verified before anything destructive runs, and tree teardown restores too.
const BACKUP := "user://character.json.test-backup"


func _exit_tree() -> void:
	_restore_live_save()


func _backup_live_save() -> bool:
	if FileAccess.file_exists(BACKUP):
		# A previous run died before restoring: put the original back first.
		_restore_live_save()
	if not FileAccess.file_exists(CharacterStore.PATH):
		return true
	return DirAccess.copy_absolute(
		ProjectSettings.globalize_path(CharacterStore.PATH),
		ProjectSettings.globalize_path(BACKUP)) == OK


func _restore_live_save() -> void:
	if FileAccess.file_exists(BACKUP):
		DirAccess.rename_absolute(
			ProjectSettings.globalize_path(BACKUP),
			ProjectSettings.globalize_path(CharacterStore.PATH))

