extends Node
## Regression test for [UpdateManifest] (issue #267, part of #105) — the module
## that states what this build reads and writes.
##
## The test that matters here is the ROUND TRIP: the manifest this build produces
## is fed to the REAL [UpdateDecision.decide], the same code that will act on it
## in front of a player. A generator checked only against a hand-written
## expectation proves that two things I wrote agree with each other; running it
## through the actual consumer proves it would be believed.
##
## Everything else in this file exists to stop that round trip passing vacuously.
## `_test_every_required_field_is_load_bearing` deletes each required field in
## turn and demands `invalid_manifest` — so "the manifest was accepted" cannot be
## the trivial consequence of a decision core that accepts anything.
##
## Pure logic — no network, no scene, no boot, and no save file touched — so it
## is safe to run locally and deterministic in CI.
##
## Run: godot --headless --path client res://tests/update_manifest_test.tscn

const DATA_DIR := "res://tests/data"
const CAPABILITY_LEDGER := "res://tests/data/shipped_save_capability.txt"
const EXPORT_PRESETS := "res://export_presets.cfg"

## A download that satisfies every predicate `RollbackSelection.is_wellformed`
## applies — a real https URL and a 64-character hex digest. A shorthand would be
## rejected as unselectable and the test would pass for the wrong reason.
const GOOD_ARTIFACT := {
	"url": "https://ghcr.io/v2/devantler-tech/world-at-ruin/client/blobs/sha256:deadbeef",
	"sha256": "1111111111111111111111111111111111111111111111111111111111111111",
	"size": 12345,
}

var _failed := false


func _ready() -> void:
	_test_round_trip_is_accepted()
	_test_round_trip_offers_a_pack_update()
	_test_every_required_field_is_load_bearing()
	_test_values_track_their_sources()
	_test_pack_full_is_a_selectable_entry()
	_test_save_floor_has_its_golden_fixture()
	_test_save_capability_matches_its_ledger()
	_test_export_is_still_monolithic()
	_test_no_unauthorized_shell_download()
	_test_a_bad_artifact_fails_closed()
	_test_json_is_stable_and_parseable()
	if _failed:
		return
	print("TEST PASS — the generated update manifest is accepted by the real decision core, and every required field is load-bearing")
	get_tree().quit(0)


# --- the round trip ---

## A client running exactly this build, asked about exactly this build, is up to
## date. This is the whole point of the module: the manifest describes the thing
## that produced it, so it must not propose moving anywhere.
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
## manifest, the round-trip test above would be proving nothing about that field
## — it would just be riding on a decision core that waves everything through.
func _test_every_required_field_is_load_bearing() -> void:
	var required := [
		"schema",
		"channel",
		"shell",
		"shell.current",
		"shell.min_supported",
		"shell.reads_min",
		"shell.reads_capability_max",
		"pack",
		"pack.version",
		"pack.min_shell",
		"protocol",
		"protocol.min",
		"protocol.max",
		"save_schema",
		"save_schema.min",
		"save_schema.writes",
		"save_schema.capability",
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


# --- the manifest must not restate what already exists ---

## Every value the manifest asserts is checked against the constant it claims to
## come from. A generator that hardcoded "3" would pass the round trip today and
## start lying the moment the real constant moved.
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
		"save_schema.capability": [m["save_schema"]["capability"], UpdateManifest.SAVE_CAPABILITY],
		"shell.reads_min": [m["shell"]["reads_min"], UpdateManifest.SAVE_SCHEMA_MIN],
		"shell.reads_capability_max": [m["shell"]["reads_capability_max"], UpdateManifest.SAVE_CAPABILITY],
	}
	for path: String in checks:
		var pair: Array = checks[path]
		if pair[0] != pair[1]:
			_fail("%s is %s but its source of truth says %s — the manifest has drifted from the build" % [
				path, str(pair[0]), str(pair[1])])
			return


## The pack entry must be one the rollback selector would actually accept. Today's
## pack is tomorrow's rollback target; publishing it in a shape the selector skips
## would mean discovering, only after a release aged, that nothing can roll back
## to it.
func _test_pack_full_is_a_selectable_entry() -> void:
	var m := _manifest()
	if _failed:
		return
	var full: Dictionary = m["pack"]["full"]
	if not RollbackSelection.is_wellformed(full):
		_fail("pack.full is not a well-formed catalogue entry — RollbackSelection would skip this build as unselectable")
		return
	# `read_ceiling` is a MAXIMUM (`RollbackSelection` asks `read_ceiling >=
	# save_schema`), so a build must claim to read at least as high as it writes.
	# Nothing consumes pack.full yet, which is exactly why this needs pinning: the
	# error would stay invisible until this pack aged into the catalogue and began
	# blocking updates it should have allowed.
	if int(full["read_ceiling"]) < int(m["save_schema"]["writes"]):
		_fail("pack.full.read_ceiling is %d but this build WRITES save schema %d — a build that cannot read what it writes is unselectable as its own rollback target (read_ceiling is a maximum, not a floor)" % [
			int(full["read_ceiling"]), int(m["save_schema"]["writes"])])
		return
	if int(full["save_capability"]) != UpdateManifest.SAVE_CAPABILITY:
		_fail("pack.full.save_capability is %d but this build writes capability %d" % [
			int(full["save_capability"]), UpdateManifest.SAVE_CAPABILITY])


## The declared save floor must have its committed golden fixture, or "this build
## reads down to schema N" is an unbacked claim. `save_fixture_guard_test.gd`
## proves the fixtures are READ; this proves the manifest points at one of them.
func _test_save_floor_has_its_golden_fixture() -> void:
	var path := "%s/golden_recipe_v%d.json" % [DATA_DIR, UpdateManifest.SAVE_SCHEMA_MIN]
	if not FileAccess.file_exists(path):
		_fail("SAVE_SCHEMA_MIN is %d but %s does not exist — the manifest would claim a read floor nothing proves" % [
			UpdateManifest.SAVE_SCHEMA_MIN, path])


## The capability is append-only, and this is what enforces it. A constant that
## dropped below a shipped value would tell a returning player's client that this
## build understands less than the vault already holds.
func _test_save_capability_matches_its_ledger() -> void:
	var shipped := _shipped_capabilities()
	if _failed:
		return
	if shipped.is_empty():
		_fail("%s is missing, empty or malformed — the append-only capability ledger must exist" % CAPABILITY_LEDGER)
		return
	var newest: int = shipped[shipped.size() - 1]
	if UpdateManifest.SAVE_CAPABILITY < newest:
		_fail("CAPABILITY ROLLBACK (no-resets law): SAVE_CAPABILITY is %d but v%d already shipped per the ledger" % [
			UpdateManifest.SAVE_CAPABILITY, newest])
		return
	if UpdateManifest.SAVE_CAPABILITY > newest:
		_fail("SAVE_CAPABILITY is %d but the ledger stops at %d — append the new capability to %s in this same change" % [
			UpdateManifest.SAVE_CAPABILITY, newest, CAPABILITY_LEDGER])
		return
	for capability in range(1, UpdateManifest.SAVE_CAPABILITY + 1):
		if capability not in shipped:
			_fail("the capability ledger has a hole: %d is missing from %s" % [capability, CAPABILITY_LEDGER])
			return


## THE ASSUMPTION GUARD. [UpdateManifest] publishes the pack version as the shell
## version, which is honest ONLY while the build is a single artifact. The day a
## pack split lands, that stops being true — and a comment would not notice.
## This does: it fails, and whoever lands the split must give the shell its own
## source of record in the same change.
func _test_export_is_still_monolithic() -> void:
	var text := _read_text(EXPORT_PRESETS)
	if _failed:
		return
	if text.is_empty():
		_fail("%s is missing or unreadable — cannot confirm the build is still a single artifact" % EXPORT_PRESETS)
		return
	for line in text.split("\n"):
		var trimmed := line.strip_edges()
		# `patches=` is how a Godot preset declares a pack overlay. Its appearance
		# means shell and pack are no longer one thing.
		if trimmed.begins_with("patches=") and trimmed != "patches=PackedStringArray()":
			_fail("%s declares a pack split (%s), so shell and pack are no longer one artifact — UpdateManifest must stop deriving shell.current from the pack version and take a real shell version instead" % [
				EXPORT_PRESETS, trimmed])
			return


## A shell replacement must be authorized by the offline root (ADR: "a
## `shell.download` is authorized by the offline root or platform codesign"),
## carried in `shell_authorization`. Neither exists yet, so the manifest must
## offer no shell download at all.
##
## This is the guard on the most dangerous field in the format: publishing an
## unauthenticated place to fetch a new executable from. Whoever adds the
## download must add its authorization in the same change, and this fails until
## they do.
func _test_no_unauthorized_shell_download() -> void:
	var m := _manifest()
	if _failed:
		return
	var offers_download: bool = (m["shell"] as Dictionary).has("download")
	var is_authorized: bool = m.has("shell_authorization")
	if offers_download and not is_authorized:
		_fail("the manifest offers shell.download with no shell_authorization — that publishes an UNAUTHORIZED shell replacement. Ship the root-signed authorization in the same change, or omit the download.")


# --- fail-closed on the one thing the client cannot know ---

## The download is the only fact CI supplies, so it is the only one that can
## arrive wrong. Every rejection here is a manifest NOT published — far better
## than one that points a player's updater at nothing.
func _test_a_bad_artifact_fails_closed() -> void:
	var bad := {
		"a missing url": {"sha256": GOOD_ARTIFACT["sha256"], "size": 1},
		"a missing sha256": {"url": GOOD_ARTIFACT["url"], "size": 1},
		"a missing size": {"url": GOOD_ARTIFACT["url"], "sha256": GOOD_ARTIFACT["sha256"]},
		"a plain-http url": {"url": "http://example.com/a.zip", "sha256": GOOD_ARTIFACT["sha256"], "size": 1},
		"a truncated digest": {"url": GOOD_ARTIFACT["url"], "sha256": "abc123", "size": 1},
		"a non-hex digest": {"url": GOOD_ARTIFACT["url"], "sha256": "z".repeat(64), "size": 1},
		"a negative size": {"url": GOOD_ARTIFACT["url"], "sha256": GOOD_ARTIFACT["sha256"], "size": -1},
		"a fractional size": {"url": GOOD_ARTIFACT["url"], "sha256": GOOD_ARTIFACT["sha256"], "size": 1.5},
	}
	for label: String in bad:
		var built: Dictionary = UpdateManifest.build(bad[label])
		if str(built.get("error", "")).is_empty():
			_fail("%s was accepted — build() must refuse an artifact it cannot honestly publish" % label)
			return
		if not (built.get("manifest") as Dictionary).is_empty():
			_fail("%s produced an error AND a manifest — a refused build must emit nothing to publish" % label)
			return


## The serialised bytes are what a signature will one day cover, so they must be
## parseable and stable across identical builds.
func _test_json_is_stable_and_parseable() -> void:
	var m := _manifest()
	if _failed:
		return
	var text := UpdateManifest.to_json(m)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		_fail("to_json did not produce a parseable JSON object")
		return
	if UpdateManifest.to_json(_manifest()) != text:
		_fail("two manifests built from the same build serialised differently — the signing bytes are not stable")
		return
	# And the parsed form must still satisfy the consumer: a serialisation that
	# quietly changed a type (an int becoming a float) would be accepted here and
	# refused in the field, where it is expensive.
	_expect(_installed_current(), parsed as Dictionary, UpdateDecision.UP_TO_DATE, "the manifest after a JSON round trip")


# --- helpers ---

func _manifest() -> Dictionary:
	var built := UpdateManifest.build(GOOD_ARTIFACT)
	if str(built.get("error", "")) != "":
		_fail("build() refused a well-formed artifact: %s" % str(built["error"]))
		return {}
	return built["manifest"]


## What a client running exactly this build looks like.
func _installed_current() -> Dictionary:
	return {
		"shell_version": DevLog.VERSION,
		"pack_version": DevLog.VERSION,
		"save_schema": CharacterFactory.RECIPE_VERSION,
		"save_capability": UpdateManifest.SAVE_CAPABILITY,
		"protocol": WireCodec.VERSION,
	}


## Remove a dotted path from a manifest. Returns false if it was not there, so a
## typo'd path in the negative-control list fails the test instead of silently
## checking nothing.
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


func _shipped_capabilities() -> Array[int]:
	var out: Array[int] = []
	var text := _read_text(CAPABILITY_LEDGER)
	if _failed:
		return out
	for line in text.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.is_empty() or trimmed.begins_with("#"):
			continue
		if not trimmed.is_valid_int():
			_fail("%s has a non-integer line: '%s'" % [CAPABILITY_LEDGER, trimmed])
			return out
		out.append(int(trimmed))
	out.sort()
	return out


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
