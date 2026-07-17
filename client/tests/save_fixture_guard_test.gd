extends Node
## THE consolidated no-resets guard (issue #36, parent #3): every historical
## save fixture loads through the real save path with ZERO loss.
##
## Discovers every tests/data/golden_recipe_v<N>.json by listing the
## directory — never a hardcoded list — so a fixture cannot silently fall out
## of coverage, and FAILS when any version 1..RECIPE_VERSION has no fixture,
## so a recipe-version bump cannot ship without its golden. The required
## range is anchored by tests/data/shipped_recipe_versions.txt, an
## APPEND-ONLY ledger of every version that ever shipped — lowering
## RECIPE_VERSION or deleting a fixture cannot pass without also editing the
## ledger, which is the explicit, reviewable act of breaking the law.
## Per fixture:
##  1. Its declared "version" matches its filename (a stale copy cannot
##     stand in for a new version's coverage).
##  2. The raw bytes are written to a throwaway probe file, exactly as a
##     historical client wrote them — the player's own save is never touched.
##  3. CharacterStore.load_from() returns a Dictionary that deep-equals the
##     fixture — zero field loss, no silent normalisation.
##  4. It builds, twice, with identical fingerprints (a shipped save must
##     keep producing the same character within one build).
##  5. Every persisted field group still has an EFFECT: building the recipe
##     without it changes the fingerprint (determinism alone cannot see a
##     deleted application path silently ignoring saved customization).
##
## Run: godot --headless --path client res://tests/save_fixture_guard_test.tscn

const DATA_DIR := "res://tests/data/"
const SHIPPED_VERSIONS := DATA_DIR + "shipped_recipe_versions.txt"
# A throwaway save file: the fixtures are loaded through the store's real
# load path via this probe, so the player's user://character.json is never
# read or written (no test can strand a character — no-resets law).
const PROBE := "user://fixture_guard_probe.json"


func _ready() -> void:
	var discovered = _discover_fixtures()
	if discovered is String:
		_fail(discovered)
		return
	var fixtures: Dictionary = discovered
	if fixtures.is_empty():
		_fail("no golden_recipe_v*.json fixtures found in %s" % DATA_DIR)
		return

	var shipped := _shipped_versions()
	if shipped.is_empty():
		_fail("shipped_recipe_versions.txt is missing, empty, or malformed — the forward-only ledger must exist")
		return
	var max_shipped: int = shipped[shipped.size() - 1]
	if CharacterFactory.RECIPE_VERSION < max_shipped:
		_fail("RECIPE VERSION ROLLBACK (no-resets law): RECIPE_VERSION is %d but v%d already shipped per the ledger" % [
			CharacterFactory.RECIPE_VERSION, max_shipped])
		return
	if CharacterFactory.RECIPE_VERSION > max_shipped:
		_fail("RECIPE_VERSION is %d but the ledger stops at v%d — append the new version to shipped_recipe_versions.txt with its fixture" % [
			CharacterFactory.RECIPE_VERSION, max_shipped])
		return
	for version in range(1, CharacterFactory.RECIPE_VERSION + 1):
		if version not in shipped:
			_fail("the ledger has a hole: v%d is missing from shipped_recipe_versions.txt" % version)
			return
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
		var reason := _check_fixture(version, fixtures[version])
		if reason != "":
			_fail("golden_recipe_v%d.json: %s" % [version, reason])
			return

	_cleanup_probe()
	print("TEST PASS — %d historical saves (v1..v%d) load with zero loss" % [
		versions.size(), CharacterFactory.RECIPE_VERSION])
	get_tree().quit(0)


func _exit_tree() -> void:
	_cleanup_probe()


func _cleanup_probe() -> void:
	if FileAccess.file_exists(PROBE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PROBE))


## "" when the fixture survives the full write→load→build path, else why not.
func _check_fixture(version: int, path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "unreadable"
	var raw := file.get_as_text()
	var expected = JSON.parse_string(raw)
	if expected is not Dictionary:
		return "not a JSON object"
	if int(expected.get("version", -1)) != version:
		return "declares version %s but its filename says v%d — a stale copy cannot stand in for v%d coverage" % [
			str(expected.get("version", "none")), version, version]

	# The fixture's raw bytes ARE the save a historical client wrote — placed
	# at the throwaway probe, never the player's own save.
	var save := FileAccess.open(PROBE, FileAccess.WRITE)
	if save == null:
		return "could not write the probe path"
	save.store_string(raw)
	save.close()

	var loaded = CharacterStore.load_from(PROBE)
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

	# Determinism alone cannot see application-layer loss: if a field's apply
	# code is deleted, both builds ignore it identically. So every persisted
	# LEAF must still have an EFFECT — building the recipe without it must
	# change the fingerprint. Leaf granularity (each dict entry, not just the
	# whole group) catches a change that stops applying one saved entry while
	# its siblings still move the fingerprint.
	for field: String in expected:
		if field == "version" or field == "comment":
			continue
		var value: Variant = expected[field]
		if value is Dictionary:
			for key: String in value:
				var ablated: Dictionary = (expected as Dictionary).duplicate(true)
				(ablated[field] as Dictionary).erase(key)
				var reason := _ablation_reason(ablated, fp_a, "%s.%s" % [field, key])
				if reason != "":
					return reason
		else:
			var ablated: Dictionary = (expected as Dictionary).duplicate(true)
			ablated.erase(field)
			var reason := _ablation_reason(ablated, fp_a, field)
			if reason != "":
				return reason
	return ""


## "" when the ablated recipe builds AND differs from the full one (the
## removed leaf had an effect); else why the leaf is silently ignored.
func _ablation_reason(ablated: Dictionary, full_fp: String, label: String) -> String:
	var without := CharacterFactory.build(ablated)
	if without == null:
		return "recipe without '%s' failed to build" % label
	var fp := CharacterFactory.fingerprint(without)
	without.free()
	if fp == full_fp:
		return "LEAF '%s' HAS NO EFFECT — saved customization is silently ignored (no-resets law)" % label
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


## The version ledger: every line is a shipped version int in CANONICAL form
## (unsigned, no sign or leading zeros); # and blanks skipped; ascending-
## sorted on return. Empty on any malformed line. Canonical-only keeps this
## parser and the CI append-only check in lockstep — is_valid_int() would
## accept "+4", which a digit-only CI grep omits, opening a deletion bypass.
func _shipped_versions() -> PackedInt32Array:
	var out := PackedInt32Array()
	var f := FileAccess.open(SHIPPED_VERSIONS, FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line == "" or line.begins_with("#"):
			continue
		if not line.is_valid_int() or int(line) < 1 or line != str(int(line)):
			return PackedInt32Array()
		out.append(int(line))
	out.sort()
	return out


func _fail(message: String) -> void:
	_cleanup_probe()
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
