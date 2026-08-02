extends Node
## Regression test for `tools/update_manifest_emit.gd` (issue #280, part of #105) — the CD
## step that turns [UpdateManifest] from a capability into a published fact.
##
## The test that matters here is the SAME round trip `update_manifest_test.gd`
## runs, but against the BYTES rather than the Dictionary: the emitted text is
## parsed back as JSON and fed to the real [UpdateDecision.decide]. A generator
## checked against its own in-memory Dictionary proves the emitter did not lose
## anything on the way out; parsing the published bytes proves the thing an
## updater actually downloads would be believed.
##
## Everything else exists to stop that round trip passing vacuously.
## `_test_a_malformed_envelope_publishes_nothing` walks a table of publisher
## mistakes and demands an error AND empty text — with a positive control in the
## same table, because a parser that refused everything would pass a
## refusal-only matrix perfectly.
##
## `_test_the_written_file_is_the_signed_bytes` is the one test that touches
## disk, because the file is what CD pushes: an emitter that returned correct
## text and wrote a trailing newline would satisfy every other assertion here
## and still publish bytes no verifier could reproduce.
##
## Pure logic plus one `user://` write — no network, no scene, no boot — so it is
## safe to run locally and deterministic in CI.
##
## Run: godot --headless --path client res://tests/update_manifest_emit_test.tscn

const Emit := preload("res://tools/update_manifest_emit.gd")

const SEQUENCE := 1780000000
const SEQUENCE_TEXT := "1780000000"
const NOT_AFTER := "2026-07-31T12:00:00Z"
const OBSERVED_AT := "2026-07-30T12:00:00Z"
const OUT_PATH := "user://update_manifest_emit_test.json"

var _failed := false


func _ready() -> void:
	_test_emitted_bytes_are_accepted_by_the_real_decision_core()
	_test_the_emitter_adds_nothing_to_the_canonical_form()
	_test_a_malformed_envelope_publishes_nothing()
	_test_the_written_file_is_the_signed_bytes()
	if _failed:
		return
	print("TEST PASS — the emitted manifest bytes are accepted by the real decision core, a malformed publication envelope emits nothing, and the written file is exactly the canonical bytes")
	get_tree().quit(0)


# --- the round trip, against the bytes ---

## The published bytes, parsed as a client would parse them, describe this build
## to a client running this build: up to date, and actionable for an older one.
func _test_emitted_bytes_are_accepted_by_the_real_decision_core() -> void:
	var text := _emit_ok()
	if _failed:
		return

	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail("the emitted bytes are not a JSON object — a client could not parse what CD would publish")
		return
	var manifest: Dictionary = parsed

	var installed := _installed_current()
	var got: Dictionary = UpdateDecision.decide(installed, manifest)
	if got.get("action") != UpdateDecision.UP_TO_DATE:
		_fail("this build described by its own published bytes gave %s (reason: %s)" % [got.get("action"), got.get("reason")])
		return

	# Not merely "not rejected": a client on an older pack must be offered this
	# one, or the published manifest would be inert.
	var older := _installed_current()
	older["pack_version"] = "0.1.0"
	var offered: Dictionary = UpdateDecision.decide(older, manifest)
	if offered.get("action") != UpdateDecision.PACK_UPDATE:
		_fail("an older pack offered the published bytes gave %s (reason: %s)" % [offered.get("action"), offered.get("reason")])
		return


## The emitter is a transport, not a second author. Its output must equal the
## canonical form of what [UpdateManifest] built — so a future emitter that
## "helpfully" reordered, pretty-printed or added a field fails here rather than
## in a verifier nobody can run yet.
func _test_the_emitter_adds_nothing_to_the_canonical_form() -> void:
	var text := _emit_ok()
	if _failed:
		return

	var built := UpdateManifest.build(SEQUENCE, NOT_AFTER, WireCodec.LEGACY_VERSION, WireCodec.VERSION)
	if built["error"] != "":
		_fail("UpdateManifest.build refused the test envelope: %s" % built["error"])
		return
	var canonical := UpdateManifest.to_json(built["manifest"])
	if canonical["error"] != "":
		_fail("UpdateManifest.to_json refused the built manifest: %s" % canonical["error"])
		return

	if text != canonical["text"]:
		_fail("the emitted bytes differ from the canonical manifest — the emitter is altering what it publishes")


# --- the vacuity guard ---

## THE FAIL-CLOSED MATRIX, WITH ITS OWN CONTROL. Each malformed envelope must
## produce an error and EMPTY text: a caller that ignored the error must still
## have nothing publishable in its hand.
##
## The control row is why this proves anything. `parse_sequence` refuses by
## pattern, and a pattern that matched nothing would refuse every row here and
## look perfect — so a known-good envelope runs through the same table and must
## SUCCEED.
func _test_a_malformed_envelope_publishes_nothing() -> void:
	# [sequence, not_after, must_succeed, what it is]
	var rows := [
		[SEQUENCE_TEXT, NOT_AFTER, true, "the control — a well-formed envelope"],
		["", NOT_AFTER, false, "an unset sequence"],
		["abc", NOT_AFTER, false, "a sequence that String.to_int() would coerce to 0"],
		["1e9", NOT_AFTER, false, "a sequence in exponent notation"],
		["1.5", NOT_AFTER, false, "a fractional sequence"],
		["-1", NOT_AFTER, false, "a negative sequence"],
		[" 42", NOT_AFTER, false, "a sequence with leading whitespace"],
		["42 ", NOT_AFTER, false, "a sequence with trailing whitespace"],
		[SEQUENCE_TEXT, "", false, "an unset not_after"],
		[SEQUENCE_TEXT, "2026-07-31 12:00:00", false, "a not_after that is not canonical UTC"],
		[SEQUENCE_TEXT, "2026-02-30T12:00:00Z", false, "a not_after that is not a real date"],
	]

	for row: Array in rows:
		var emitted := Emit.emit(row[0], row[1], str(WireCodec.LEGACY_VERSION), str(WireCodec.VERSION))
		var errored: bool = str(emitted["error"]) != ""
		var text: String = emitted["text"]

		if row[2]:
			if errored:
				_fail("%s was refused (%s) — the matrix below it proves nothing if nothing can pass" % [row[3], emitted["error"]])
				return
			if text.is_empty():
				_fail("%s emitted no text" % row[3])
				return
			continue

		if not errored:
			_fail("%s was accepted — CD would publish it" % row[3])
			return
		if not text.is_empty():
			_fail("%s reported an error but still returned %d bytes to publish" % [row[3], text.length()])
			return

	for bad_protocol: String in ["", "0", "abc", "1.5", " 1", "65536"]:
		for position: String in ["minimum", "maximum"]:
			var minimum := bad_protocol if position == "minimum" else str(WireCodec.LEGACY_VERSION)
			var maximum := bad_protocol if position == "maximum" else str(WireCodec.VERSION)
			var emitted := Emit.emit(SEQUENCE_TEXT, NOT_AFTER, minimum, maximum)
			if emitted["error"] == "" or emitted["text"] != "":
				_fail("malformed live protocol %s '%s' left publishable bytes" % [position, bad_protocol])
				return
	var inverted := Emit.emit(SEQUENCE_TEXT, NOT_AFTER, "2", "1")
	if inverted["error"] == "" or inverted["text"] != "":
		_fail("an inverted live protocol range left publishable bytes")
		return


# --- what CD actually pushes ---

## The bytes on disk are the bytes a signature covers. Anything the writer adds —
## a trailing newline above all — is a byte every verifier would have to know to
## strip, so the file must equal the emitted text exactly.
func _test_the_written_file_is_the_signed_bytes() -> void:
	var text := _emit_ok()
	if _failed:
		return

	var error := Emit.write(OUT_PATH, text)
	if error != "":
		_fail("write() refused a valid destination: %s" % error)
		return

	var file := FileAccess.open(OUT_PATH, FileAccess.READ)
	if file == null:
		_fail("write() reported success but %s cannot be opened" % OUT_PATH)
		return
	var on_disk := file.get_buffer(file.get_length())
	file.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(OUT_PATH))

	# Compared as BYTES, not as text: a trailing newline is exactly the
	# difference a string comparison after `get_as_text()` can hide.
	if on_disk != text.to_utf8_buffer():
		_fail("the written file is %d bytes where the manifest is %d — the writer is not publishing the canonical bytes" % [
			on_disk.size(), text.to_utf8_buffer().size()])
		return

	var unwritable := Emit.write("user://no_such_dir/manifest.json", text)
	if unwritable == "":
		_fail("write() reported success for a path it cannot create — CD would believe it published a manifest that is not there")


# --- helpers ---


func _emit_ok() -> String:
	var emitted := Emit.emit(SEQUENCE_TEXT, NOT_AFTER, str(WireCodec.LEGACY_VERSION), str(WireCodec.VERSION))
	if emitted["error"] != "":
		_fail("the emitter refused a well-formed envelope: %s" % emitted["error"])
		return ""
	return emitted["text"]


func _installed_current() -> Dictionary:
	return {
		"shell_version": DevLog.VERSION,
		"pack_version": DevLog.VERSION,
		"save_schema": CharacterFactory.RECIPE_VERSION,
		"save_capability": UpdateManifest.SAVE_CAPABILITY_WRITES,
		"protocol": WireCodec.VERSION,
		"manifest_sequence_high_water": SEQUENCE - 1,
		"observed_at": OBSERVED_AT,
	}


func _fail(message: String) -> void:
	if _failed:
		return
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
