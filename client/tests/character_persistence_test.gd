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
	print("TEST PASS — %s" % fp_direct)
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
