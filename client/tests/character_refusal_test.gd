extends Node
## Regression test for the character recipe's refusal latch (issue #333).
##
## The recipe on disk is player state under the no-resets law, so a build that
## cannot ACCEPT an existing recipe must not treat the session as a first run.
## Without the latch, two boot paths end in the player's character being
## replaced:
##  - a recipe that did not parse read as null, which is also what a genuinely
##    missing save reads as, so the writable first-run creator opened over a
##    file that was still there and the first apply overwrote it;
##  - a recipe that parsed but failed validation left the body unbuilt with no
##    refusal recorded, so the character-editor key opened the writable editor
##    and applying replaced a save this build had already judged unreadable.
##
## Both are the rollback case: the file may hold perfectly good state written by
## a NEWER build. Refusing has to preserve those bytes and stop writing.
##
## The five controls the contract names are exercised here — future version,
## unknown field, malformed, disappearing after refusal, and missing file — plus
## the control that keeps the whole set from passing vacuously: a CORRECT recipe
## must still load and still be writable. A guard that refused everything would
## satisfy every refusal assertion below and break the game.
##
## Pure and headless: every case runs against throwaway probe paths through
## load_from/save_to, so the player's own user://character.json is never read or
## written (no-resets law — a test may never strand a character).
##
## Run: godot --headless --path client res://tests/character_refusal_test.tscn

const PROBE := "user://character_refusal_probe.json"
const SECOND_PROBE := "user://character_refusal_probe_two.json"

var _failed := false


func _ready() -> void:
	_cleanup()
	CharacterStore.clear_refusals_for_test()

	_check_missing_file_is_a_first_run()
	_check_valid_recipe_loads_and_stays_writable()
	_check_refusal("a future-version recipe", _future_version_recipe())
	_check_refusal("an unknown-field recipe", _unknown_field_recipe())
	_check_refusal("an unknown-name recipe", _unknown_name_recipe())
	_check_refusal("a singular deformation recipe", _singular_deformation_recipe())
	_check_malformed_recipe_is_refused()
	_check_latch_survives_the_file_disappearing()

	_cleanup()
	if _failed:
		get_tree().quit(1)
		return
	print("TEST PASS — refusal latches on every unacceptable recipe and never on a good one")
	get_tree().quit(0)


## CONTROL: an absent save is a first run, not a refusal. Without this the
## refusal assertions could all be satisfied by a store that refused every path.
func _check_missing_file_is_a_first_run() -> void:
	if CharacterStore.load_from(PROBE) != null:
		_fail("a missing recipe did not read as null")
	if CharacterStore.is_refused(PROBE):
		_fail("a missing recipe latched a refusal — that is the first-run path")
	if not CharacterStore.can_write(PROBE):
		_fail("a missing recipe is not writable, so no character could ever be created")


## CONTROL: the guard must break against CORRECT data, not just accept it. A
## valid recipe has to load AND leave the path writable, or the latch is simply
## refusing everything and the refusal cases below prove nothing.
func _check_valid_recipe_loads_and_stays_writable() -> void:
	var recipe := _wanderer()
	if recipe.is_empty():
		return
	if not CharacterStore.save_to(PROBE, recipe):
		_fail("a valid recipe could not be written")
		return
	var loaded = CharacterStore.load_from(PROBE)
	if loaded is not Dictionary:
		_fail("a valid recipe did not load back")
	if CharacterStore.is_refused(PROBE):
		_fail("a valid recipe latched a refusal")
	if not CharacterStore.can_write(PROBE):
		_fail("a valid recipe left the path unwritable")
	_clear(PROBE)


## An unacceptable recipe: refused on read, latched, unwritable, bytes preserved.
func _check_refusal(label: String, recipe: Dictionary) -> void:
	if recipe.is_empty():
		return
	_clear(PROBE)
	CharacterStore.clear_refusals_for_test()
	# Seeded through the raw writer: save_to refuses a latched path, and the
	# point here is to start from a file that is already on disk.
	if not _write_text(PROBE, JSON.stringify(recipe, "  ")):
		_fail("%s: could not seed the probe" % label)
		return
	_assert_refused(label, PROBE)


## Malformed bytes — not a JSON object at all. This is the shape corruption
## actually produces (a truncated or zero-byte file), and the one that reads
## identically to "no save" unless the refusal is latched.
func _check_malformed_recipe_is_refused() -> void:
	_clear(PROBE)
	CharacterStore.clear_refusals_for_test()
	if not _write_text(PROBE, "{ this is not json"):
		_fail("malformed: could not seed the probe")
		return
	_assert_refused("a malformed recipe", PROBE)


## The latch is keyed to the PATH and never re-derived from the file's current
## state. Cloud sync, a second client, or the player deleting the file can all
## make a refused recipe vanish mid-session; re-deriving would then answer
## "writable" and let this build write over state it just refused to read.
func _check_latch_survives_the_file_disappearing() -> void:
	_clear(SECOND_PROBE)
	CharacterStore.clear_refusals_for_test()
	if not _write_text(SECOND_PROBE, JSON.stringify(_future_version_recipe(), "  ")):
		_fail("disappearing: could not seed the probe")
		return
	if CharacterStore.load_from(SECOND_PROBE) != null:
		_fail("disappearing: the future-version recipe was not refused")
		return
	_clear(SECOND_PROBE)
	if not CharacterStore.is_refused(SECOND_PROBE):
		_fail("the refusal did not survive the file disappearing")
	if CharacterStore.can_write(SECOND_PROBE):
		_fail("a refused path became writable once the file vanished")
	if CharacterStore.save_to(SECOND_PROBE, _wanderer()):
		_fail("a refused path accepted a write after the file vanished")
	if FileAccess.file_exists(SECOND_PROBE):
		_fail("a refused path was recreated by a write that should have been refused")


## Every promise refusal makes, asserted together: read refused, latch recorded,
## path unwritable, write actually blocked, and the original bytes untouched.
func _assert_refused(label: String, path: String) -> void:
	var before := FileAccess.get_sha256(path)
	if CharacterStore.load_from(path) != null:
		_fail("%s: loaded instead of being refused" % label)
	if not CharacterStore.is_refused(path):
		_fail("%s: no refusal was latched" % label)
	if CharacterStore.can_write(path):
		_fail("%s: the path stayed writable" % label)
	if CharacterStore.save_to(path, _wanderer()):
		_fail("%s: a write was accepted over a refused recipe" % label)
	# Deleting is a write too, and the destructive one.
	OS.set_environment(CharacterStore.SAVE_PATH_ENV, path)
	CharacterStore.clear()
	OS.set_environment(CharacterStore.SAVE_PATH_ENV, "")
	if not FileAccess.file_exists(path):
		_fail("%s: a refused recipe was deleted" % label)
	if FileAccess.get_sha256(path) != before:
		_fail("%s: the original bytes were modified" % label)


func _wanderer() -> Dictionary:
	var recipe = CharacterFactory.load_recipe("res://recipes/wanderer.json")
	if recipe is not Dictionary:
		_fail("wanderer preset unreadable")
		return {}
	var copy: Dictionary = (recipe as Dictionary).duplicate(true)
	copy.erase("comment")
	return copy


func _future_version_recipe() -> Dictionary:
	var recipe := _wanderer()
	if recipe.is_empty():
		return {}
	recipe["version"] = CharacterFactory.RECIPE_VERSION + 1
	return recipe


func _unknown_field_recipe() -> Dictionary:
	var recipe := _wanderer()
	if recipe.is_empty():
		return {}
	recipe["wings"] = { "span": 2 }
	return recipe


## A recipe whose FIELDS are all legal but which names something this build does
## not have. Distinct from the unknown-FIELD case: the shape is perfectly
## well-formed, so nothing short of running the real validation catches it — which
## is exactly why the store has to ask the factory rather than only parsing.
func _unknown_name_recipe() -> Dictionary:
	var recipe := _wanderer()
	if recipe.is_empty():
		return {}
	recipe["skin"] = "no_such_skin"
	return recipe


## A persisted recipe can be structurally valid while carrying a scalar that
## makes skeleton transforms singular. It must take the same path-latched,
## byte-preserving refusal path as every other unreadable character (#692).
func _singular_deformation_recipe() -> Dictionary:
	var recipe := _wanderer()
	if recipe.is_empty():
		return {}
	recipe["bone_girth"] = { "upperarm": 0.0 }
	return recipe


func _write_text(path: String, text: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	file.close()
	return true


func _clear(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _cleanup() -> void:
	CharacterStore.clear_refusals_for_test()
	_clear(PROBE)
	_clear(SECOND_PROBE)


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
