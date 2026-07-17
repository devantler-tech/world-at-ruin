extends Node
## Regression test for character persistence (issue #24 stage 3): the saved
## recipe is player state under the no-resets law.
##  1. Save → load round-trips to an identical character (fingerprint).
##  2. A missing save reads as null (the first-run path).
##  3. A recipe from a NEWER client version refuses to load into a character
##     rather than half-applying (CharacterFactory validation through the
##     store path).
##
## The store's real save/load logic is exercised through a throwaway probe
## file (save_to/load_from), so the player's own user://character.json is
## never touched — a test can never strand a character (no-resets law).
##
## Run: godot --headless --path client res://tests/character_persistence_test.tscn

const PROBE := "user://persistence_probe.json"


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

	# A future-version recipe must be refused, not half-applied.
	var future: Dictionary = recipe.duplicate(true)
	future["version"] = CharacterFactory.RECIPE_VERSION + 1
	CharacterStore.save_to(PROBE, future)
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
	if FileAccess.file_exists(PROBE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PROBE))
