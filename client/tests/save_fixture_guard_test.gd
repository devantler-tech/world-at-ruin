extends Node
## THE consolidated no-resets guard (issue #36, parent #3): every historical
## save fixture loads through the real save path with ZERO loss.
##
## Discovers every tests/data/golden_recipe_v<N>.json by listing the
## directory — never a hardcoded list — so a fixture cannot silently fall out
## of coverage, and FAILS when any version 1..RECIPE_VERSION has no fixture,
## so a recipe-version bump cannot ship without its golden. Per fixture:
##  1. The raw bytes are placed at the real save path, exactly as the
##     historical client wrote them.
##  2. CharacterStore.load_saved() returns a Dictionary that deep-equals the
##     fixture — zero field loss, no silent normalisation.
##  3. It builds, twice, with identical fingerprints (a shipped save must
##     keep producing the same character within one build).
##
## Run: godot --headless --path client res://tests/save_fixture_guard_test.tscn

const DATA_DIR := "res://tests/data/"


func _ready() -> void:
	if not TestSaveBackup.backup():
		_fail("could not back up the live character save — refusing to touch it")
		return

	var discovered = _discover_fixtures()
	if discovered is String:
		_fail(discovered)
		return
	var fixtures: Dictionary = discovered
	if fixtures.is_empty():
		_fail("no golden_recipe_v*.json fixtures found in %s" % DATA_DIR)
		return
	for version in range(1, CharacterFactory.RECIPE_VERSION + 1):
		if version not in fixtures:
			_fail("RECIPE_VERSION is %d but golden_recipe_v%d.json does not exist — a recipe version may not ship without its fixture" % [
				CharacterFactory.RECIPE_VERSION, version])
			return
	for version: int in fixtures:
		if version > CharacterFactory.RECIPE_VERSION:
			_fail("fixture golden_recipe_v%d.json is newer than this client (RECIPE_VERSION %d)" % [
				version, CharacterFactory.RECIPE_VERSION])
			return

	var versions := fixtures.keys()
	versions.sort()
	for version: int in versions:
		var reason := _check_fixture(fixtures[version])
		if reason != "":
			_fail("golden_recipe_v%d.json: %s" % [version, reason])
			return

	CharacterStore.clear()
	TestSaveBackup.restore()
	print("TEST PASS — %d historical saves (v1..v%d) load with zero loss" % [
		versions.size(), CharacterFactory.RECIPE_VERSION])
	get_tree().quit(0)


func _exit_tree() -> void:
	TestSaveBackup.restore()


## "" when the fixture survives the full write→load→build path, else why not.
func _check_fixture(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "unreadable"
	var raw := file.get_as_text()
	var expected = JSON.parse_string(raw)
	if expected is not Dictionary:
		return "not a JSON object"

	# The fixture's raw bytes ARE the save a historical client left on disk.
	var save := FileAccess.open(CharacterStore.PATH, FileAccess.WRITE)
	if save == null:
		return "could not write the save path"
	save.store_string(raw)
	save.close()

	var loaded = CharacterStore.load_saved()
	if loaded is not Dictionary:
		return "HISTORICAL SAVE REFUSED TO LOAD (no-resets law)"
	var lost := _diff(expected, loaded, "recipe")
	if lost != "":
		return "LOAD LOST DATA (no-resets law): %s" % lost

	var built_a := CharacterFactory.build(loaded)
	if built_a == null:
		return "HISTORICAL SAVE NO LONGER BUILDS (no-resets law)"
	var built_b := CharacterFactory.build(loaded)
	if built_b == null:
		built_a.free()
		return "built once but not twice"
	var fp_a := CharacterFactory.fingerprint(built_a)
	var fp_b := CharacterFactory.fingerprint(built_b)
	built_a.free()
	built_b.free()
	if fp_a != fp_b:
		return "same save produced different characters:\n  %s\n  %s" % [fp_a, fp_b]
	return ""


## Dictionary of version -> res:// path for every golden_recipe_v<N>.json in
## DATA_DIR, or a String error when a fixture name does not parse.
func _discover_fixtures() -> Variant:
	var out := {}
	for file_name in DirAccess.get_files_at(DATA_DIR):
		if not (file_name.begins_with("golden_recipe_v") and file_name.ends_with(".json")):
			continue
		var stem := file_name.trim_prefix("golden_recipe_v").trim_suffix(".json")
		if not stem.is_valid_int() or int(stem) < 1:
			return "fixture name %s does not parse as golden_recipe_v<N>.json" % file_name
		out[int(stem)] = DATA_DIR + file_name
	return out


## "" when equal; else the path of the first divergence and what changed.
func _diff(expected: Variant, actual: Variant, path: String) -> String:
	if typeof(expected) != typeof(actual):
		return "%s: type %s became %s" % [
			path, type_string(typeof(expected)), type_string(typeof(actual))]
	if expected is Dictionary:
		for key in expected:
			if key not in (actual as Dictionary):
				return "%s.%s: field vanished" % [path, key]
			var nested := _diff(expected[key], actual[key], "%s.%s" % [path, key])
			if nested != "":
				return nested
		for key in actual:
			if key not in (expected as Dictionary):
				return "%s.%s: field appeared from nowhere" % [path, key]
		return ""
	if expected is Array:
		if (expected as Array).size() != (actual as Array).size():
			return "%s: array size %d became %d" % [
				path, (expected as Array).size(), (actual as Array).size()]
		for i in (expected as Array).size():
			var nested := _diff(expected[i], actual[i], "%s[%d]" % [path, i])
			if nested != "":
				return nested
		return ""
	if expected != actual:
		return "%s: %s became %s" % [path, expected, actual]
	return ""


func _fail(message: String) -> void:
	CharacterStore.clear()
	TestSaveBackup.restore()
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
