extends Node
## Emit this build's update manifest as the exact bytes a signature will cover.
##
## [UpdateManifest] derives what this build reads, writes and speaks from the
## constants the build actually runs on, and nothing called it. The manifest
## existed as a capability and never as a published fact, so the OCI origin
## served a build that made no statement about itself: an updater resolving
## against it had a payload and no contract (#280).
##
## THE ENVELOPE IS SUPPLIED, NOT DERIVED. `sequence` and `not_after` are
## publication facts rather than build facts — see
## `docs/design/distribution-and-self-update.md`. Deriving them here would either
## conflate SemVer with the anti-replay counter or read the wall clock and make
## identical builds nondeterministic, so the publisher passes them in and this
## emitter's whole job on that side is to REFUSE anything malformed.
##
## THE PARSE IS THE POINT, AND IT IS WHY THE ENVELOPE ARRIVES AS TEXT.
## `String.to_int()` is not a validator: it returns `0` for `"abc"`, for `""` and
## for `"1e9"`. Sequence `0` is a valid manifest that publishes the LOWEST
## possible anti-replay floor, so a mistyped publisher variable would not fail —
## it would ship a manifest every future client accepts and no future manifest
## can supersede by being newer. [method parse_sequence] therefore matches digits
## explicitly and refuses everything else, rather than letting a coercion decide.
##
## Run:
##   WAR_MANIFEST_SEQUENCE=1780000000 \
##   WAR_MANIFEST_NOT_AFTER=2026-07-31T12:00:00Z \
##   WAR_MANIFEST_PROTOCOL_MIN=1 \
##   WAR_MANIFEST_PROTOCOL_MAX=2 \
##   WAR_MANIFEST_OUT=/tmp/manifest.json \
##   godot --headless --path client res://tools/update_manifest_emit.tscn
##
## Writes the JCS (RFC 8785) canonical bytes with NO trailing newline: the bytes
## are what a signature covers, so anything this adds is a byte a verifier would
## have to know to strip.

## Publication envelope and destination. Environment rather than command-line
## arguments because `godot --headless <scene>` forwards unrecognised arguments
## to the engine, which warns on them and would bury a typo in the log.
const SEQUENCE_ENV := "WAR_MANIFEST_SEQUENCE"
const NOT_AFTER_ENV := "WAR_MANIFEST_NOT_AFTER"
const OUT_ENV := "WAR_MANIFEST_OUT"
const PROTOCOL_MIN_ENV := "WAR_MANIFEST_PROTOCOL_MIN"
const PROTOCOL_MAX_ENV := "WAR_MANIFEST_PROTOCOL_MAX"

## Digits only. Deliberately narrower than [method String.is_valid_int], which
## accepts a leading sign: `"-1"` would parse cleanly here and then be refused
## one layer down by [method UpdateDecision.is_int_id], reporting a coercion
## failure for what is really an unusable publisher value.
const SEQUENCE_PATTERN := "^[0-9]+$"


func _ready() -> void:
	var sequence_text := OS.get_environment(SEQUENCE_ENV)
	var not_after_text := OS.get_environment(NOT_AFTER_ENV)
	var out_path := OS.get_environment(OUT_ENV)
	var protocol_min_text := OS.get_environment(PROTOCOL_MIN_ENV)
	var protocol_max_text := OS.get_environment(PROTOCOL_MAX_ENV)

	if out_path.is_empty():
		_fail("%s is not set — nowhere to write the manifest" % OUT_ENV)
		return

	var emitted := emit(sequence_text, not_after_text, protocol_min_text, protocol_max_text)
	if emitted["error"] != "":
		_fail(emitted["error"])
		return

	var written := write(out_path, emitted["text"])
	if written != "":
		_fail(written)
		return

	print("MANIFEST OK — %d bytes to %s" % [emitted["text"].length(), out_path])
	get_tree().quit(0)


## Build and canonicalize this build's manifest from a publisher-supplied envelope.
##
## Returns `{ error: String, text: String }` — the shape [UpdateManifest] uses.
## `error` is "" on success; otherwise `text` is EMPTY, so a caller that ignores
## the error still cannot publish a partial manifest.
static func emit(sequence_text: String, not_after_text: String, protocol_min_text: String, protocol_max_text: String) -> Dictionary:
	var sequence := parse_sequence(sequence_text)
	if sequence["error"] != "":
		return {"error": sequence["error"], "text": ""}
	var protocol_min := parse_protocol_version(protocol_min_text, PROTOCOL_MIN_ENV)
	if protocol_min["error"] != "":
		return {"error": protocol_min["error"], "text": ""}
	var protocol_max := parse_protocol_version(protocol_max_text, PROTOCOL_MAX_ENV)
	if protocol_max["error"] != "":
		return {"error": protocol_max["error"], "text": ""}

	# `not_after` passes through as text on purpose: `UpdateManifest.build`
	# validates it with the same `UpdateDecision.is_utc_datetime` the client
	# enforces in the field, so re-checking the grammar here would be a second
	# implementation of it that could disagree.
	var built := UpdateManifest.build(sequence["value"], not_after_text, protocol_min["value"], protocol_max["value"])
	if built["error"] != "":
		return {"error": "manifest: %s" % built["error"], "text": ""}

	var canonical := UpdateManifest.to_json(built["manifest"])
	if canonical["error"] != "":
		return {"error": "canonicalize: %s" % canonical["error"], "text": ""}

	return {"error": "", "text": canonical["text"]}


## Parse the publication sequence from text, refusing anything a coercion would
## have silently turned into a number.
##
## Returns `{ error: String, value: int }`.
static func parse_sequence(text: String) -> Dictionary:
	if text.is_empty():
		return {"error": "%s is not set — the publication sequence has no default" % SEQUENCE_ENV, "value": 0}

	var pattern := RegEx.new()
	# The pattern is a literal, so a compile failure is a bug in this file rather
	# than a bad input; asserting keeps the happy path from reading as if a
	# runtime condition were being handled.
	assert(pattern.compile(SEQUENCE_PATTERN) == OK, "sequence pattern must compile")
	if pattern.search(text) == null:
		return {"error": "%s='%s' is not a sequence of digits" % [SEQUENCE_ENV, text], "value": 0}

	return {"error": "", "value": text.to_int()}


static func parse_protocol_version(text: String, env_name: String) -> Dictionary:
	if text.is_empty():
		return {"error": "%s is not set — the live server range has no default" % env_name, "value": 0}
	var pattern := RegEx.new()
	assert(pattern.compile(SEQUENCE_PATTERN) == OK, "protocol-version pattern must compile")
	if pattern.search(text) == null or text.to_int() < 1:
		return {"error": "%s='%s' is not a positive protocol version" % [env_name, text], "value": 0}
	return {"error": "", "value": text.to_int()}


## Write the canonical bytes, creating nothing and appending nothing.
##
## Returns "" on success, or what went wrong.
static func write(out_path: String, text: String) -> String:
	var file := FileAccess.open(out_path, FileAccess.WRITE)
	if file == null:
		return "could not open %s for writing (%d)" % [out_path, FileAccess.get_open_error()]
	# `store_string`, not `store_line`: a trailing newline is a byte the
	# signature would cover and every verifier would have to agree to strip.
	file.store_string(text)
	file.close()
	return ""


func _fail(message: String) -> void:
	push_error(message)
	print("MANIFEST FAIL — %s" % message)
	get_tree().quit(1)
