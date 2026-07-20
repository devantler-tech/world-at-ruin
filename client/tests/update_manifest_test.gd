extends Node
## Regression test for [UpdateManifest] (issue #267, part of #105) — the module
## that states what this build reads, writes and speaks.
##
## The test that matters here is the ROUND TRIP: the manifest this build produces
## is fed to the REAL [UpdateDecision.decide], the same code that will act on it
## in front of a player. A generator checked only against a hand-written
## expectation proves that two things I wrote agree with each other; running it
## through the actual consumer proves it would be believed.
##
## Everything else exists to stop that round trip passing vacuously.
## `_test_every_required_field_is_load_bearing` deletes each required field in
## turn and demands `invalid_manifest`, so "the manifest was accepted" cannot be
## the trivial consequence of a decision core that accepts anything.
##
## The remaining tests guard the three assumptions that are true TODAY and will
## expire: that the build is a single artifact, that no pack exists to point at,
## and that client and server speak one pinned protocol version. Each fails when
## its assumption does, which is the only way a comment about it stays honest.
##
## Pure logic — no network, no scene, no boot, no save file touched — so it is
## safe to run locally and deterministic in CI.
##
## Run: godot --headless --path client res://tests/update_manifest_test.tscn

const DATA_DIR := "res://tests/data"
const CAPABILITY_LEDGER := "res://tests/data/shipped_save_capability.txt"
const RECIPE_LEDGER := "res://tests/data/shipped_recipe_versions.txt"
const EXPORT_PRESETS := "res://export_presets.cfg"
const SERVER_WIRE := "res://../server/wire/wire.go"

var _failed := false


func _ready() -> void:
	_test_round_trip_is_accepted()
	_test_round_trip_offers_a_pack_update()
	_test_every_required_field_is_load_bearing()
	_test_values_track_their_sources()
	_test_no_delivery_is_published()
	_test_read_capability_covers_what_is_written()
	_test_save_floor_has_its_golden_fixture()
	_test_save_capability_matches_its_ledger()
	_test_export_is_still_monolithic()
	_test_protocol_matches_the_server()
	_test_json_is_stable_and_parseable()
	if _failed:
		return
	print("TEST PASS — the generated update manifest is accepted by the real decision core, every required field is load-bearing, and no unbacked delivery is published")
	get_tree().quit(0)


# --- the round trip ---

## A client running exactly this build, asked about exactly this build, is up to
## date. The manifest describes the thing that produced it, so it must not
## propose moving anywhere.
func _test_round_trip_is_accepted() -> void:
	var m := _manifest()
	if _failed:
		return
	_expect(_installed_current(), m, UpdateDecision.UP_TO_DATE, "this build described by its own manifest")


## The same manifest, seen by a client whose pack is older, is a pack update —
## proving the manifest is not merely "not rejected" but actually actionable.
func _test_round_trip_offers_a_pack_update() -> void:
	var m := _manifest()
	if _failed:
		return
	var older := _installed_current()
	older["pack_version"] = "0.1.0"
	_expect(older, m, UpdateDecision.PACK_UPDATE, "an older pack offered this build")


## THE VACUITY GUARD. Delete each field the decision core requires, one at a
## time, and demand a clean refusal. If any deletion still yielded an accepted
## manifest, the round trip above would be proving nothing about that field.
func _test_every_required_field_is_load_bearing() -> void:
	var required := [
		"schema", "channel",
		"shell", "shell.current", "shell.min_supported", "shell.reads_min", "shell.reads_capability_max",
		"pack", "pack.version", "pack.min_shell",
		"protocol", "protocol.min", "protocol.max",
		"save_schema", "save_schema.min", "save_schema.writes", "save_schema.capability",
	]
	for path: String in required:
		var m := _manifest()
		if _failed:
			return
		if not _erase_path(m, path):
			_fail("the manifest has no '%s' to remove — the generator stopped emitting a field the decision core requires" % path)
			return
		var got: Dictionary = UpdateDecision.decide(_installed_current(), m)
		if got.get("action") != UpdateDecision.INVALID_MANIFEST:
			_fail("removing '%s' still produced %s — that field is not actually load-bearing, so the round-trip test does not cover it" % [
				path, got.get("action")])
			return


# --- the manifest must not restate, nor overstate ---

## Every value is checked against the constant it claims to come from. A
## generator that hardcoded "3" would pass the round trip today and start lying
## the moment the real constant moved.
func _test_values_track_their_sources() -> void:
	var m := _manifest()
	if _failed:
		return
	var checks := {
		"schema": [m["schema"], UpdateDecision.SUPPORTED_MANIFEST_SCHEMA],
		"pack.version": [m["pack"]["version"], DevLog.VERSION],
		"protocol.min": [m["protocol"]["min"], WireCodec.VERSION],
		"protocol.max": [m["protocol"]["max"], WireCodec.VERSION],
		"save_schema.writes": [m["save_schema"]["writes"], CharacterFactory.RECIPE_VERSION],
		"save_schema.min": [m["save_schema"]["min"], UpdateManifest.SAVE_SCHEMA_MIN],
		"save_schema.capability": [m["save_schema"]["capability"], UpdateManifest.SAVE_CAPABILITY_WRITES],
		"shell.reads_min": [m["shell"]["reads_min"], UpdateManifest.SAVE_SCHEMA_MIN],
		"shell.reads_capability_max": [m["shell"]["reads_capability_max"], UpdateManifest.SAVE_CAPABILITY_READS],
	}
	for path: String in checks:
		var pair: Array = checks[path]
		if pair[0] != pair[1]:
			_fail("%s is %s but its source of truth says %s — the manifest has drifted from the build" % [
				path, str(pair[0]), str(pair[1])])
			return


## NOTHING FETCHABLE MAY BE PUBLISHED. There is no pack artifact (CD builds a
## macOS `.app` ZIP, not a mountable `.pck`) and no root authorization for a shell
## download. Either one would hand a recovering client something it cannot use —
## an application archive to the pack-mount path, or an unauthenticated place to
## fetch an executable.
##
## This is the guard on the most dangerous class of field in the format, so it
## checks for the whole class rather than one name.
func _test_no_delivery_is_published() -> void:
	var m := _manifest()
	if _failed:
		return
	var pack: Dictionary = m["pack"]
	for forbidden: String in ["full", "deltas"]:
		if pack.has(forbidden):
			_fail("pack.%s is published, but no pack artifact exists — CD builds a .app ZIP, and a client selecting it for recovery would hand an application archive to the pack-mount path. Omit it until the pack pipeline produces a real .pck." % forbidden)
			return
	if (m["shell"] as Dictionary).has("download") and not m.has("shell_authorization"):
		_fail("shell.download is published with no shell_authorization — that offers an UNAUTHORIZED shell replacement. Ship the root-signed authorization in the same change, or omit the download.")
		return
	if not (m["rollback_targets"] as Array).is_empty():
		_fail("rollback_targets is non-empty, but nothing is retained yet — an entry here would point a recovery at an artifact that does not exist")


## A build must be able to read what it writes, or it can never serve as its own
## rollback target. The two capabilities are separate constants precisely so an
## expand-before-write build can read ahead of what it writes — but never behind.
func _test_read_capability_covers_what_is_written() -> void:
	if UpdateManifest.SAVE_CAPABILITY_READS < UpdateManifest.SAVE_CAPABILITY_WRITES:
		_fail("SAVE_CAPABILITY_READS (%d) is below SAVE_CAPABILITY_WRITES (%d) — a build that cannot read what it writes strands its own saves" % [
			UpdateManifest.SAVE_CAPABILITY_READS, UpdateManifest.SAVE_CAPABILITY_WRITES])


## The declared save floor must be the OLDEST SCHEMA THAT EVER SHIPPED — not
## merely a schema that happens to have a fixture.
##
## Checking only for a matching fixture is too weak: raising `SAVE_SCHEMA_MIN` to
## 2 would still pass while `shipped_recipe_versions.txt` and the fixture suite
## still carry schema 1. The manifest would then advertise `reads_min: 2`, and
## `UpdateDecision` would return `blocked_incompatible` for a schema-1 player whose
## save this very build still reads — silently stranding historical state, which is
## exactly what the no-resets law forbids.
##
## So the floor is pinned to the shipped ledger, and the fixture must also exist.
func _test_save_floor_has_its_golden_fixture() -> void:
	var shipped := _ledger_ints(RECIPE_LEDGER)
	if _failed:
		return
	if shipped.is_empty():
		_fail("%s is missing, empty or malformed — the save floor cannot be anchored" % RECIPE_LEDGER)
		return
	var oldest: int = shipped[0]
	if UpdateManifest.SAVE_SCHEMA_MIN != oldest:
		_fail("SAVE_SCHEMA_MIN is %d but the oldest schema that ever shipped is %d (%s) — advertising the higher floor makes UpdateDecision block a schema-%d player whose save this build still reads. Lower the floor, or retire that schema deliberately by removing it from the ledger." % [
			UpdateManifest.SAVE_SCHEMA_MIN, oldest, RECIPE_LEDGER, oldest])
		return
	var path := "%s/golden_recipe_v%d.json" % [DATA_DIR, UpdateManifest.SAVE_SCHEMA_MIN]
	if not FileAccess.file_exists(path):
		_fail("SAVE_SCHEMA_MIN is %d but %s does not exist — the manifest would claim a read floor nothing proves" % [
			UpdateManifest.SAVE_SCHEMA_MIN, path])


## The WRITE capability is append-only. A constant dropping below a shipped value
## would tell a returning player's client that this build understands less than
## the vault already holds.
func _test_save_capability_matches_its_ledger() -> void:
	var shipped := _shipped_capabilities()
	if _failed:
		return
	if shipped.is_empty():
		_fail("%s is missing, empty or malformed — the append-only capability ledger must exist" % CAPABILITY_LEDGER)
		return
	var newest: int = shipped[shipped.size() - 1]
	if UpdateManifest.SAVE_CAPABILITY_WRITES < newest:
		_fail("CAPABILITY ROLLBACK (no-resets law): SAVE_CAPABILITY_WRITES is %d but %d already shipped per the ledger" % [
			UpdateManifest.SAVE_CAPABILITY_WRITES, newest])
		return
	if UpdateManifest.SAVE_CAPABILITY_WRITES > newest:
		_fail("SAVE_CAPABILITY_WRITES is %d but the ledger stops at %d — append the new capability to %s in this same change" % [
			UpdateManifest.SAVE_CAPABILITY_WRITES, newest, CAPABILITY_LEDGER])
		return
	for capability in range(1, UpdateManifest.SAVE_CAPABILITY_WRITES + 1):
		if capability not in shipped:
			_fail("the capability ledger has a hole: %d is missing from %s" % [capability, CAPABILITY_LEDGER])
			return


## THE ASSUMPTION GUARD. [UpdateManifest] publishes the pack version as the shell
## version, honest ONLY while the build is a single artifact. The day a pack split
## lands, whoever lands it must give the shell its own source of record.
func _test_export_is_still_monolithic() -> void:
	var text := _read_text(EXPORT_PRESETS)
	if _failed:
		return
	if text.is_empty():
		_fail("%s is missing or unreadable — cannot confirm the build is still a single artifact" % EXPORT_PRESETS)
		return
	for line in text.split("\n"):
		var trimmed := line.strip_edges()
		# `patches=` is how a Godot preset declares a pack overlay.
		if trimmed.begins_with("patches=") and trimmed != "patches=PackedStringArray()":
			_fail("%s declares a pack split (%s), so shell and pack are no longer one artifact — UpdateManifest must stop deriving shell.current from the pack version and take a real shell version instead" % [
				EXPORT_PRESETS, trimmed])
			return


## THE CROSS-LANGUAGE GUARD. The manifest's top-level `protocol` range is what the
## LIVE SERVER accepts. Sourcing it from the client codec is defensible only
## because both sides are pinned to the same single version, so this asserts that
## directly against the server's Go source.
##
## When the two-phase expansion begins the server will accept a RANGE the client
## constant cannot express, this test will fail, and the range will have to become
## a CD-supplied input read from deployment state. That is the intended outcome —
## the failure is the design conversation, not a nuisance.
func _test_protocol_matches_the_server() -> void:
	var text := _read_text(SERVER_WIRE)
	if _failed:
		return
	var found := -1
	for line in text.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.begins_with("const Version uint16"):
			var parts := trimmed.split("=")
			if parts.size() == 2 and parts[1].strip_edges().is_valid_int():
				found = int(parts[1].strip_edges())
			break
	if found < 0:
		_fail("could not read `const Version uint16` from %s — the manifest's protocol range claims to match the server and can no longer prove it" % SERVER_WIRE)
		return
	if found != WireCodec.VERSION:
		_fail("server wire.Version is %d but the client's WireCodec.VERSION is %d — the manifest publishes the CLIENT value as the range the SERVER accepts, which is only valid while they agree. The accepted range must now come from deployment state, not from the client codec." % [
			found, WireCodec.VERSION])


## The serialised bytes are what a signature will one day cover, so they must be
## parseable and stable across identical builds.
func _test_json_is_stable_and_parseable() -> void:
	var m := _manifest()
	if _failed:
		return
	var serialised := UpdateManifest.to_json(m)
	if str(serialised["error"]) != "":
		_fail("to_json refused this build's manifest: %s" % str(serialised["error"]))
		return
	var text: String = serialised["text"]
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		_fail("to_json did not produce a parseable JSON object")
		return
	if str(UpdateManifest.to_json(_manifest())["text"]) != text:
		_fail("two manifests built from the same build serialised differently — the signing bytes are not stable")
		return
	# The parsed form must still satisfy the consumer: a serialisation that quietly
	# changed a type (an int becoming a float) would be accepted here and refused
	# in the field, where it is expensive.
	_expect(_installed_current(), parsed as Dictionary, UpdateDecision.UP_TO_DATE, "the manifest after a JSON round trip")


# --- helpers ---

func _manifest() -> Dictionary:
	var built := UpdateManifest.build()
	if str(built.get("error", "")) != "":
		_fail("build() refused to emit a manifest for this build: %s" % str(built["error"]))
		return {}
	return built["manifest"]


## What a client running exactly this build looks like.
func _installed_current() -> Dictionary:
	return {
		"shell_version": DevLog.VERSION,
		"pack_version": DevLog.VERSION,
		"save_schema": CharacterFactory.RECIPE_VERSION,
		"save_capability": UpdateManifest.SAVE_CAPABILITY_WRITES,
		"protocol": WireCodec.VERSION,
	}


## Remove a dotted path. Returns false if it was not there, so a typo'd path in
## the negative-control list fails the test instead of silently checking nothing.
func _erase_path(m: Dictionary, path: String) -> bool:
	var parts := path.split(".")
	var cursor: Dictionary = m
	for i in range(parts.size() - 1):
		var key := parts[i]
		if not (cursor.has(key) and cursor[key] is Dictionary):
			return false
		cursor = cursor[key]
	var leaf := parts[parts.size() - 1]
	if not cursor.has(leaf):
		return false
	cursor.erase(leaf)
	return true


## Parse an append-only integer ledger, sorted ascending. Shared by the capability
## and recipe-version ledgers so the two cannot drift in how they are read.
func _ledger_ints(path: String) -> Array[int]:
	var out: Array[int] = []
	var text := _read_text(path)
	if _failed:
		return out
	for line in text.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.is_empty() or trimmed.begins_with("#"):
			continue
		if not trimmed.is_valid_int():
			_fail("%s has a non-integer line: '%s'" % [path, trimmed])
			return out
		out.append(int(trimmed))
	out.sort()
	return out


func _shipped_capabilities() -> Array[int]:
	return _ledger_ints(CAPABILITY_LEDGER)


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_fail("could not open %s" % path)
		return ""
	var text := file.get_as_text()
	file.close()
	return text


func _expect(installed: Dictionary, manifest: Dictionary, want_action: String, label: String) -> void:
	if _failed:
		return
	var got: Dictionary = UpdateDecision.decide(installed, manifest)
	if got.get("action") != want_action:
		_fail("%s — expected %s, got %s (reason: %s)" % [label, want_action, got.get("action"), got.get("reason")])


func _fail(message: String) -> void:
	if _failed:
		return
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
