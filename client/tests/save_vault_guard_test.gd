extends Node
## THE no-resets guard for PROGRESSION state (issue #249, parent #3) — the
## sibling of save_fixture_guard_test, which guards the character recipe.
## Every historical vault fixture loads through the real vault path with ZERO
## loss.
##
## Discovers every tests/data/golden_vault_v<N>.json by listing the directory —
## never a hardcoded list — so a fixture cannot silently fall out of coverage,
## and FAILS when any version 1..VAULT_READ_VERSION has no fixture, so a vault
## version bump cannot ship without its golden. The required range is anchored
## by tests/data/shipped_vault_versions.txt, an APPEND-ONLY ledger of every
## version that ever shipped — lowering VAULT_READ_VERSION or deleting a fixture
## cannot pass without also editing the ledger, which is the explicit,
## reviewable act of breaking the law.
##
## Per fixture:
##  1. Its declared "version" matches its filename (a stale copy cannot stand
##     in for a new version's coverage).
##  2. The raw bytes are written to a throwaway probe file, exactly as a
##     historical client wrote them — the player's own vault is never touched.
##  3. SaveVault.load_from() returns a Dictionary that deep-equals the fixture
##     — zero field loss, no silent normalisation.
##  4. It survives a WRITE-BACK round-trip through attune(): re-saving a loaded
##     vault preserves every field and name, including ones this build does not
##     use. Load-only checking cannot see a save path that drops them.
##  5. A v2 fixture's discoveries restore through the real Discovery tracker,
##     proving the expansion has an application path rather than parser-only
##     support.
##
## Then the LIVE-NAME law (added after review — the gap a zero-loss guard cannot
## see on its own):
##  6. Every attunement name in every shipped fixture, and every name in the
##     append-only tests/data/shipped_attunements.txt ledger, is still
##     RECOGNISED by this build (SaveVault.KNOWN_ATTUNEMENTS). A byte round-trip
##     proves a name survives; it does not prove the game still acts on it.
##     Renaming a shipped name and its call site together would otherwise keep
##     every guard green while stranding existing players.
##  7. Every production discovery id is bidirectionally bound to the append-only
##     shipped_discoveries.txt id=landmark ledger. The real boot guard separately
##     proves every ledger id is still registered to that exact point of interest.
##
## Then the refusal laws, which are what make the separate-file design safe:
##  8. A vault one version NEWER than this client is refused, not half-applied.
##  9. A vault that exists but cannot be read is NOT writable — refuse-to-read
##     implies refuse-to-write, or a downgrade would overwrite progression a
##     newer client wrote.
## 10. An absent vault reads as an empty vault, never as a failure — a missing
##     vault must degrade to session-only, never block a boot.
## 11. A refusal LATCHES for the session: once refused, the path stays
##     unwritable even if the file then disappears. Cloud sync or a second
##     client can remove an unreadable vault mid-session, and a build that
##     re-derived writability from the file's current state would then write a
##     v1 document that syncs back over the newer progression it just refused.
##
## Run: godot --headless --path client res://tests/save_vault_guard_test.tscn

const DATA_DIR := "res://tests/data/"
const SHIPPED_VERSIONS := DATA_DIR + "shipped_vault_versions.txt"
const SHIPPED_ATTUNEMENTS := DATA_DIR + "shipped_attunements.txt"
const SHIPPED_DISCOVERIES := DATA_DIR + "shipped_discoveries.txt"
# A throwaway vault file: fixtures are loaded through the vault's real load
# path via this probe, so the player's user://vault.json is never read or
# written (no test can destroy progression — no-resets law).
const PROBE := "user://vault_guard_probe.json"
## The name the write-back check attunes. Deliberately NOT a real respawn point
## and never present in a fixture: the check is only meaningful when the name
## added differs from the names already there (see _check_fixture).
const WRITEBACK_PROBE_NAME := "__guard_writeback_probe"


func _ready() -> void:
	var discovered = _discover_fixtures()
	if discovered is String:
		_fail(discovered)
		return
	var fixtures: Dictionary = discovered
	if fixtures.is_empty():
		_fail("no golden_vault_v*.json fixtures found in %s" % DATA_DIR)
		return

	var shipped := _shipped_versions()
	if shipped.is_empty():
		_fail("shipped_vault_versions.txt is missing, empty, or malformed — the forward-only ledger must exist")
		return
	var max_shipped: int = shipped[shipped.size() - 1]
	if SaveVault.VAULT_READ_VERSION < max_shipped:
		_fail("VAULT VERSION ROLLBACK (no-resets law): VAULT_READ_VERSION is %d but v%d already shipped per the ledger" % [
			SaveVault.VAULT_READ_VERSION, max_shipped])
		return
	if SaveVault.VAULT_READ_VERSION > max_shipped:
		_fail("VAULT_READ_VERSION is %d but the ledger stops at v%d — append the new version to shipped_vault_versions.txt with its fixture" % [
			SaveVault.VAULT_READ_VERSION, max_shipped])
		return
	for version in range(1, SaveVault.VAULT_READ_VERSION + 1):
		if version not in shipped:
			_fail("the ledger has a hole: v%d is missing from shipped_vault_versions.txt" % version)
			return
		if version not in fixtures:
			_fail("VAULT_READ_VERSION is %d but golden_vault_v%d.json does not exist — a vault version may not ship without its fixture" % [
				SaveVault.VAULT_READ_VERSION, version])
			return
	for version: int in fixtures:
		if version > SaveVault.VAULT_READ_VERSION:
			_fail("fixture golden_vault_v%d.json is newer than this client (VAULT_READ_VERSION %d)" % [
				version, SaveVault.VAULT_READ_VERSION])
			return

	# The fixture loop writes and re-saves through PROBE; start from a clean
	# latch so a refusal left by an earlier run of this scene cannot block it.
	SaveVault.clear_refusals_for_test()
	var versions := fixtures.keys()
	versions.sort()
	for version: int in versions:
		var reason := _check_fixture(version, fixtures[version])
		if reason != "":
			_fail("golden_vault_v%d.json: %s" % [version, reason])
			return

	var live := _check_live_names(fixtures)
	if live != "":
		_fail(live)
		return
	var discovery_names := _check_discovery_names()
	if discovery_names != "":
		_fail(discovery_names)
		return

	var refusal := _check_refusal_laws(fixtures[versions[versions.size() - 1]])
	if refusal != "":
		_fail(refusal)
		return

	_cleanup_probe()
	print("TEST PASS — %d historical vaults (v1..v%d) load and re-save with zero loss" % [
		versions.size(), SaveVault.VAULT_READ_VERSION])
	get_tree().quit(0)


## "" when the fixture survives the full write→load→re-save path, else why not.
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

	# The fixture's raw bytes ARE the vault a historical client wrote — placed
	# at the throwaway probe, never the player's own vault.
	if not _write_probe(raw):
		return "could not write the probe path"

	var loaded = SaveVault.load_from(PROBE)
	if loaded is not Dictionary:
		return "HISTORICAL VAULT REFUSED TO LOAD (no-resets law)"
	var lost := _diff(expected, loaded, "vault")
	if lost != "":
		return "LOAD LOST DATA (no-resets law): %s" % lost

	# Reader support is not enough unless the application can act on the shape.
	# Feed the fixture through the real tracker and prove every persisted name,
	# including an unknown future one, enters its deterministic found set.
	if version >= 2:
		var tracker := Discovery.new()
		var persisted: Array = loaded.get("discoveries", [])
		if not tracker.restore(persisted):
			return "the Discovery application path refused a valid v2 fixture"
		var expected_discoveries: Array[String] = []
		for name: String in persisted:
			if name not in expected_discoveries:
				expected_discoveries.append(name)
		expected_discoveries.sort()
		if tracker.discovered() != expected_discoveries:
			return "the Discovery application path did not restore the v2 fixture exactly"

	# Write-back: re-saving a loaded vault must preserve everything, including
	# fields and names this build does not itself use. A load-only check cannot
	# see a save path that quietly drops them.
	#
	# The name attuned here MUST NOT be one the fixture already carries. Attuning
	# a name the fixture already has makes an attune() that wipes the list and
	# re-adds that one name indistinguishable from one that preserves it — the
	# check would pass while proving nothing (caught by ablation: an attune()
	# that cleared `attuned` still went green against golden_vault_v1).
	var rewritten: Dictionary = SaveVault.attune(loaded, WRITEBACK_PROBE_NAME)
	if not SaveVault.save_to(PROBE, rewritten):
		return "re-saving a loaded vault failed"
	var reloaded = SaveVault.load_from(PROBE)
	if reloaded is not Dictionary:
		return "a re-saved vault no longer loads"
	var dropped := _diff(expected, reloaded, "vault")
	if dropped != "":
		return "SAVE DROPPED DATA (no-resets law): %s" % dropped
	# ...and the newly attuned name actually landed, so an attune() that simply
	# did nothing cannot satisfy the preservation check above by inaction.
	if not SaveVault.is_attuned(reloaded, WRITEBACK_PROBE_NAME):
		return "attune() did not record the new name on write-back"

	# Attuning something already attuned must not duplicate it — the list is
	# append-only, and a duplicate would grow the file without bound.
	var names := SaveVault.attuned(reloaded)
	var seen := {}
	for name: String in names:
		if seen.has(name):
			return "attuning an already-attuned point duplicated '%s'" % name
		seen[name] = true
	return ""


## Every shipped attunement name — from the fixtures AND from the append-only
## ledger — must still be recognised by this build. "" when the law holds.
func _check_live_names(fixtures: Dictionary) -> String:
	var ledger := _shipped_attunements()
	if ledger.is_empty():
		return "shipped_attunements.txt is missing or empty — the forward-only live-name ledger must exist"
	for name: String in ledger:
		if not SaveVault.recognises(name):
			return ("SHIPPED ATTUNEMENT NO LONGER RECOGNISED (no-resets law): '%s' is in "
				+ "shipped_attunements.txt but not in SaveVault.KNOWN_ATTUNEMENTS — every player "
				+ "attuned there would wake in the cave forever") % name
	# ...and the REVERSE direction. Checking only "ledger name is recognised"
	# lets a name be added to KNOWN_ATTUNEMENTS and persisted in production
	# without ever reaching the ledger — it then ships unanchored, and the
	# append-only CI step (which only guards the ledger file) would not notice
	# it later disappearing. Both directions, or the anchor has a hole.
	for name: String in SaveVault.KNOWN_ATTUNEMENTS:
		if name not in ledger:
			return ("KNOWN ATTUNEMENT IS UNANCHORED (no-resets law): '%s' is in "
				+ "SaveVault.KNOWN_ATTUNEMENTS but missing from shipped_attunements.txt — once "
				+ "players persist it, nothing stops it being removed again") % name

	for version: int in fixtures:
		var file := FileAccess.open(fixtures[version], FileAccess.READ)
		if file == null:
			return "golden_vault_v%d.json unreadable" % version
		var doc = JSON.parse_string(file.get_as_text())
		if doc is not Dictionary:
			return "golden_vault_v%d.json is not a JSON object" % version
		for name in SaveVault.attuned(doc):
			if not SaveVault.recognises(name):
				return ("SHIPPED ATTUNEMENT NO LONGER RECOGNISED (no-resets law): golden_vault_v%d.json "
					+ "carries '%s', which this build no longer acts on") % [version, name]
			if name not in ledger:
				return ("golden_vault_v%d.json carries '%s' but it is missing from "
					+ "shipped_attunements.txt — the ledger must anchor every shipped name") % [version, name]
	return ""


## The append-only live-name ledger as an array of names; empty when unreadable.
func _shipped_attunements() -> Array:
	var file := FileAccess.open(SHIPPED_ATTUNEMENTS, FileAccess.READ)
	if file == null:
		return []
	var names := []
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		names.append(line)
	file.close()
	return names


## Every discovery id a production writer can originate must be ledgered, and
## every ledgered id must remain recognised. This checkout-local half combines
## with CI's base-revision comparison and the boot test's registration walk.
func _check_discovery_names() -> String:
	var ledger := _shipped_discoveries()
	if ledger.is_empty():
		return "shipped_discoveries.txt is missing, malformed, or empty — persisted place ids need an immutable mapping ledger"
	var vault_api := load("res://scripts/save_vault.gd") as Script
	if not vault_api.has_method("recognises_discovery"):
		return "SaveVault has no recognises_discovery() runtime contract for ledgered place ids"
	var constants := vault_api.get_script_constant_map()
	var known: Variant = constants.get("KNOWN_DISCOVERIES", [])
	if known is not Array or (known as Array).is_empty():
		return "SaveVault.KNOWN_DISCOVERIES is missing or empty"
	for name: String in ledger:
		if not bool(vault_api.call("recognises_discovery", name)):
			return ("SHIPPED DISCOVERY NO LONGER RECOGNISED (no-resets law): '%s' is in "
				+ "shipped_discoveries.txt but not SaveVault.KNOWN_DISCOVERIES") % name
	for raw: Variant in known:
		if raw is not String or (raw as String).is_empty():
			return "SaveVault.KNOWN_DISCOVERIES carries an invalid stable id"
		if raw not in ledger:
			return ("KNOWN DISCOVERY IS UNANCHORED (no-resets law): '%s' is writable but missing "
				+ "from shipped_discoveries.txt") % str(raw)
	return ""


func _shipped_discoveries() -> Dictionary:
	var file := FileAccess.open(SHIPPED_DISCOVERIES, FileAccess.READ)
	if file == null:
		return {}
	var mappings := {}
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var parts := line.split("=", false, 1)
		if parts.size() != 2:
			return {}
		var name := String(parts[0]).strip_edges()
		var landmark := String(parts[1]).strip_edges()
		if name.is_empty() or landmark.is_empty() or mappings.has(name):
			return {}
		mappings[name] = landmark
	file.close()
	return mappings


## The refusal laws, exercised against a real fixture's bytes.
func _check_refusal_laws(fixture_path: String) -> String:
	var file := FileAccess.open(fixture_path, FileAccess.READ)
	if file == null:
		return "refusal check: fixture unreadable"
	var doc = JSON.parse_string(file.get_as_text())
	if doc is not Dictionary:
		return "refusal check: fixture is not a JSON object"

	# 5. A vault from a NEWER client is refused, never half-applied.
	var future: Dictionary = (doc as Dictionary).duplicate(true)
	future["version"] = SaveVault.VAULT_READ_VERSION + 1
	if not _write_probe(JSON.stringify(future)):
		return "refusal check: could not write the probe"
	if SaveVault.load_from(PROBE) != null:
		return "A NEWER-VERSION VAULT LOADED (no-resets law): v%d must be refused by a v%d client" % [
			SaveVault.VAULT_READ_VERSION + 1, SaveVault.VAULT_READ_VERSION]

	# 6. Refuse-to-read implies refuse-to-write: the unreadable newer vault
	# still on the probe must NOT be writable, or a downgrade would destroy
	# progression a newer client wrote.
	if SaveVault.can_write(PROBE):
		return "AN UNREADABLE VAULT WAS WRITABLE (no-resets law): overwriting it would destroy a newer client's progression"

	# The same must hold for outright corruption, not only a version we can
	# name — a half-written file is the likelier real-world case.
	if not _write_probe("{ this is not json"):
		return "refusal check: could not write the corrupt probe"
	if SaveVault.load_from(PROBE) != null:
		return "a corrupt vault loaded"
	if SaveVault.can_write(PROBE):
		return "A CORRUPT VAULT WAS WRITABLE (no-resets law): the unreadable file would be replaced"

	# 9b. A rejection on the BOOT path latches too, not only one reached through
	# can_write(). load_saved()/load_from() is what boot actually calls; if that
	# refused a newer vault without latching, and cloud sync then removed the
	# file, the next attunement would see an absent, never-refused path and write
	# a v1 document over the newer progression. Checked with load_from ALONE —
	# calling can_write here would latch by itself and mask the gap.
	SaveVault.clear_refusals_for_test()
	if not _write_probe(JSON.stringify(future)):
		return "boot-latch check: could not write the probe"
	if SaveVault.load_from(PROBE) != null:
		return "boot-latch check: a newer vault loaded"
	_cleanup_probe()
	if SaveVault.can_write(PROBE):
		return ("BOOT REJECTION DID NOT LATCH (no-resets law): load_from() refused a newer vault, "
			+ "the file then vanished, and the path became writable — a v1 write here could sync "
			+ "over the newer progression")

	# 9. The refusal LATCHES via the can_write path too. Re-establish an
	# unreadable file, refuse it through can_write, then remove it: still
	# unwritable. This is the whole point — a vault refused once stays refused
	# even when it vanishes, or a v1 build would write a document that syncs
	# back over newer progression.
	SaveVault.clear_refusals_for_test()
	if not _write_probe(JSON.stringify(future)):
		return "latch check: could not write the probe"
	if SaveVault.can_write(PROBE):
		return "latch check: an unreadable vault was writable"
	_cleanup_probe()
	if SaveVault.can_write(PROBE):
		return ("REFUSAL DID NOT LATCH (no-resets law): the vault was refused, then removed, and "
			+ "became writable again — a v1 write here could sync over the newer progression")

	# 8. An ABSENT vault is not a failure — it degrades to an empty vault, so a
	# player with no progression yet still boots normally. Needs a clean latch:
	# this asserts a property of the FILE's absence, not of the session's
	# history, and the probe carries refusals from the cases above.
	SaveVault.clear_refusals_for_test()
	if SaveVault.load_from(PROBE) != null:
		return "an absent vault did not read as null"
	if not SaveVault.can_write(PROBE):
		return "an absent vault was not writable — a first attunement could never be saved"
	return ""


func _write_probe(raw: String) -> bool:
	var probe := FileAccess.open(PROBE, FileAccess.WRITE)
	if probe == null:
		return false
	probe.store_string(raw)
	probe.close()
	return true


## Every key/leaf in `expected` present and equal in `actual`. Returns "" when
## nothing was lost, else the first missing or changed path. Deliberately
## one-directional: `actual` may gain fields (a defaulted empty list), but may
## never lose or change what a shipped vault recorded.
func _diff(expected: Variant, actual: Variant, path: String) -> String:
	if expected is Dictionary:
		if actual is not Dictionary:
			return "%s: expected an object, got %s" % [path, type_string(typeof(actual))]
		for key: String in (expected as Dictionary):
			if not (actual as Dictionary).has(key):
				return "%s.%s is MISSING after the round-trip" % [path, key]
			var nested := _diff((expected as Dictionary)[key], (actual as Dictionary)[key], "%s.%s" % [path, key])
			if nested != "":
				return nested
		return ""
	if expected is Array:
		if actual is not Array:
			return "%s: expected an array, got %s" % [path, type_string(typeof(actual))]
		# Order-independent containment: the vault's lists are append-only sets,
		# so a shipped entry must survive, but a later entry may be appended.
		for item in (expected as Array):
			if item not in (actual as Array):
				return "%s: entry '%s' is MISSING after the round-trip" % [path, str(item)]
		return ""
	if expected != actual:
		return "%s changed: %s -> %s" % [path, str(expected), str(actual)]
	return ""


## version -> res:// path, for every golden_vault_v<N>.json in DATA_DIR.
## Returns a String on a directory error so the caller fails loudly rather than
## reporting "no fixtures" when the directory simply could not be opened.
func _discover_fixtures() -> Variant:
	var dir := DirAccess.open(DATA_DIR)
	if dir == null:
		return "cannot open %s (error %d)" % [DATA_DIR, DirAccess.get_open_error()]
	var fixtures := {}
	for name in dir.get_files():
		# Godot's exported/imported filesystem can present a .json as
		# .json.remap; match on the stem so discovery survives both.
		var stem := name.trim_suffix(".remap")
		if not (stem.begins_with("golden_vault_v") and stem.ends_with(".json")):
			continue
		var digits := stem.trim_prefix("golden_vault_v").trim_suffix(".json")
		if not digits.is_valid_int():
			return "fixture '%s' does not carry an integer version in its name" % name
		fixtures[int(digits)] = DATA_DIR + stem
	return fixtures


## The append-only ledger as a sorted int array; empty when unreadable or when
## it carries no version at all (both are failures for the caller).
func _shipped_versions() -> Array:
	var file := FileAccess.open(SHIPPED_VERSIONS, FileAccess.READ)
	if file == null:
		return []
	var versions := []
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		if not line.is_valid_int():
			return []
		versions.append(int(line))
	file.close()
	versions.sort()
	return versions


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
