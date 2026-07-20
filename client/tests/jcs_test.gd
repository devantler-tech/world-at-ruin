extends Node
## Conformance test for [JCS] (issue #298, part of #69) — the RFC 8785
## canonicalization that fixes the exact bytes an update signature covers.
##
## The vectors are the point. `tests/data/jcs_vectors.json` is a SHARED contract:
## it was written from RFC 8785 by hand, not captured from this implementation's
## output, so it can catch this implementation being wrong. Any second
## implementation — a CI-side signer, a Go verifier — consumes the same file and
## must reproduce the same bytes, which is the whole reason the ADR pins a standard
## rather than letting each side sort keys its own way.
##
## Two guards stop this passing vacuously:
##
##   * `_test_vectors_discriminate` asserts the vectors actually REJECT the thing we
##     replaced. If [JCS.canonicalize] were quietly reverted to
##     `JSON.stringify(..., sort_keys)`, the suite must go red — so the test proves
##     the old path fails the vectors before trusting that the new one passes them.
##   * `_test_the_fixture_is_populated` refuses an empty or truncated vector file. A
##     loop over zero vectors passes every assertion in it.
##
## Pure logic — no network, no scene, no boot, no save file touched.
##
## Run: godot --headless --path client res://tests/jcs_test.tscn

const VECTORS := "res://tests/data/jcs_vectors.json"

## The vector that exists specifically because Godot gets it wrong: a
## supplementary-plane member name, where UTF-16 code-unit order and code-point
## order disagree. Named here so the discrimination guard cannot be satisfied by
## some unrelated vector happening to differ.
const DIVERGENT_VECTOR := "utf16_key_order_supplementary"

## Fewer vectors than this means the fixture was truncated, not that the contract
## shrank. Raise it when vectors are added; never lower it to make a run pass.
const MIN_VECTORS := 8

var _failed := false
var _fixture: Dictionary = {}


func _ready() -> void:
	_load_fixture()
	if _failed:
		return
	_test_the_fixture_is_populated()
	_test_every_vector_canonicalizes()
	_test_every_refusal_is_refused()
	_test_oversized_integer_is_refused()
	_test_vectors_discriminate()
	_test_utf16_order_is_not_code_point_order()
	_test_manifest_serialises_canonically()
	if _failed:
		return
	print("TEST PASS — %d RFC 8785 vectors and %d refusals hold, and the vectors reject the non-conformant path" % [
		(_fixture["vectors"] as Array).size(), (_fixture["refusals"] as Array).size()])
	get_tree().quit(0)


func _load_fixture() -> void:
	if not FileAccess.file_exists(VECTORS):
		_fail("%s is missing — the shared JCS contract is what makes two implementations agree; without it this test proves nothing" % VECTORS)
		return
	var text := FileAccess.get_file_as_string(VECTORS)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		_fail("%s did not parse as a JSON object" % VECTORS)
		return
	_fixture = parsed as Dictionary
	if not (_fixture.get("vectors") is Array and _fixture.get("refusals") is Array):
		_fail("%s must carry a `vectors` array and a `refusals` array" % VECTORS)


## A loop over an empty fixture passes silently, so the fixture's own size is an
## assertion.
func _test_the_fixture_is_populated() -> void:
	var vectors: Array = _fixture["vectors"]
	if vectors.size() < MIN_VECTORS:
		_fail("expected at least %d vectors, found %d — the shared contract has been truncated" % [MIN_VECTORS, vectors.size()])
		return
	if (_fixture["refusals"] as Array).is_empty():
		_fail("the fixture carries no refusals — fail-closed behaviour is part of this contract, not a detail")
		return
	var names := {}
	for vector in vectors:
		var name := str(vector.get("name", ""))
		if name == "":
			_fail("a vector has no name")
			return
		if names.has(name):
			_fail("two vectors share the name '%s' — one of them is unreachable in a failure report" % name)
			return
		names[name] = true
		if not vector.has("input") or not (vector.get("expected") is String):
			_fail("vector '%s' needs both an `input` and a string `expected`" % name)
			return


## The contract itself: parse, canonicalize, reproduce the expected bytes exactly.
func _test_every_vector_canonicalizes() -> void:
	for vector in _fixture["vectors"] as Array:
		var name := str(vector["name"])
		var result := JCS.canonicalize(vector["input"])
		if str(result["error"]) != "":
			_fail("vector '%s' was refused: %s" % [name, str(result["error"])])
			return
		var produced: String = result["text"]
		var expected: String = vector["expected"]
		if produced != expected:
			_fail("vector '%s' produced the wrong canonical bytes.\n  expected: %s\n  produced: %s\n  why this vector exists: %s" % [
				name, expected, produced, str(vector.get("why", ""))])
			return


## Out-of-domain values must be REFUSED, not serialised on a best effort. A
## canonicalizer that guesses is worse than one that stops: the guess gets signed.
func _test_every_refusal_is_refused() -> void:
	for refusal in _fixture["refusals"] as Array:
		var name := str(refusal["name"])
		var result := JCS.canonicalize(refusal["input"])
		if str(result["error"]) == "":
			_fail("refusal '%s' was CANONICALIZED instead of refused, producing %s — %s" % [
				name, str(result["text"]), str(refusal.get("why", ""))])
			return
		if str(result["text"]) != "":
			_fail("refusal '%s' returned an error AND text; a refused value must yield no bytes at all, or a caller that checks only one of the two will sign the wrong thing" % name)
			return


## The integer path CANNOT be reached from the vector file — Godot's JSON parser
## returns every number as a float — so the 2^53 bound on GDScript-constructed
## integers needs its own assertion, built programmatically.
##
## This is not hypothetical: [UpdateManifest] assembles its manifest in code, so the
## integer path is the one production actually uses. A GDScript `int` is 64-bit and
## can hold values ECMAScript cannot represent, and RFC 8785 numbers follow
## ECMAScript `Number::toString` (IEEE 754 double) — so `9007199254740993` would
## canonicalize to `...992` in a conforming implementation and to `...993` here.
## Different signing bytes from the same input, invisible until verification fails.
func _test_oversized_integer_is_refused() -> void:
	# 2^53 is the last integer with an exact double; 2^53 + 1 is not.
	var representable := {"v": 9007199254740992}
	var beyond := {"v": 9007199254740993}
	if typeof(representable["v"]) != TYPE_INT or typeof(beyond["v"]) != TYPE_INT:
		_fail("this test must exercise the INT path, but the literals were not stored as integers — it would otherwise pass by testing the float path twice")
		return

	var accepted := JCS.canonicalize(representable)
	if str(accepted["error"]) != "":
		_fail("2^53 has an exact double and must be accepted, but was refused: %s" % str(accepted["error"]))
		return
	if str(accepted["text"]) != '{"v":9007199254740992}':
		_fail("2^53 canonicalized to %s" % str(accepted["text"]))
		return

	var refused := JCS.canonicalize(beyond)
	if str(refused["error"]) == "":
		_fail("the integer 2^53+1 was canonicalized to %s — no ECMAScript-based implementation can produce those bytes, because 9007199254740993 has no exact double, so the two would never agree on what was signed" % str(refused["text"]))
		return

	# The negative side must be bounded too. Guarding it with absi() would overflow
	# on the most negative int64, whose magnitude has no positive counterpart.
	var negative := JCS.canonicalize({"v": -9007199254740993})
	if str(negative["error"]) == "":
		_fail("the integer -(2^53+1) was canonicalized to %s — the bound must hold on both sides" % str(negative["text"]))
		return
	var extreme := JCS.canonicalize({"v": -9223372036854775808})
	if str(extreme["error"]) == "":
		_fail("the most negative int64 was canonicalized to %s" % str(extreme["text"]))


## THE ANTI-VACUITY GUARD.
##
## Every vector passing tells us the implementation agrees with the fixture. It
## does not tell us the fixture is capable of disagreeing with anything. So: feed
## the vectors to the path this module REPLACED — Godot's sorted-key stringify —
## and require it to fail at least one. If it passes them all, the vectors are not
## testing canonicalization at all and every other assertion here is decoration.
func _test_vectors_discriminate() -> void:
	var divergences := 0
	var divergent_seen := false
	for vector in _fixture["vectors"] as Array:
		var legacy := JSON.stringify(vector["input"], "", true, true)
		if legacy != str(vector["expected"]):
			divergences += 1
			if str(vector["name"]) == DIVERGENT_VECTOR:
				divergent_seen = true
	if divergences == 0:
		_fail("EVERY vector is satisfied by JSON.stringify(sort_keys) — these vectors cannot detect a non-conformant canonicalizer, so they prove nothing")
		return
	if not divergent_seen:
		_fail("vector '%s' no longer distinguishes JCS from a code-point sort — it is the case Godot demonstrably gets wrong, so if it stops discriminating it has been weakened rather than fixed" % DIVERGENT_VECTOR)


## The concrete divergence, asserted directly rather than only through a fixture:
## a supplementary-plane name sorts BELOW a high BMP name by UTF-16 code unit, and
## ABOVE it by code point. Godot's String comparison is the latter.
func _test_utf16_order_is_not_code_point_order() -> void:
	var supplementary := String.chr(0x10000)  # UTF-16: D800 DC00
	var bmp := String.chr(0xFFFD)             # UTF-16: FFFD
	if not (bmp < supplementary):
		_fail("Godot no longer compares Strings by code point, so the premise of this module's key ordering has changed and must be re-derived")
		return
	var result := JCS.canonicalize({bmp: 2, supplementary: 1})
	if str(result["error"]) != "":
		_fail("canonicalizing a supplementary-plane member name was refused: %s" % str(result["error"]))
		return
	var expected := "{%s:1,%s:2}" % [JCS.quote(supplementary), JCS.quote(bmp)]
	if str(result["text"]) != expected:
		_fail("supplementary-plane member name sorted by code point, not UTF-16 code unit.\n  expected: %s\n  produced: %s" % [
			expected, str(result["text"])])


## The production caller. The manifest must serialise through the canonicalizer,
## and the bytes must still parse back to the same structure — a canonicalizer that
## produced unparseable output would be caught nowhere else.
func _test_manifest_serialises_canonically() -> void:
	var built := UpdateManifest.build()
	if str(built.get("error", "")) != "":
		_fail("build() refused to emit a manifest for this build: %s" % str(built["error"]))
		return
	var manifest: Dictionary = built["manifest"]
	var serialised := UpdateManifest.to_json(manifest)
	if str(serialised["error"]) != "":
		_fail("to_json refused this build's own manifest: %s — the manifest's value domain has outgrown what the canonicalizer has vectors for" % str(serialised["error"]))
		return
	var text: String = serialised["text"]
	var reparsed: Variant = JSON.parse_string(text)
	if not (reparsed is Dictionary):
		_fail("the canonical manifest bytes did not parse back as a JSON object")
		return
	# Canonicalizing the reparsed form must be a fixed point. This is what makes the
	# bytes verifiable at all: a verifier re-derives them from the parsed manifest,
	# so if that round trip moved, no signature could ever be checked.
	var again := JCS.canonicalize(reparsed)
	if str(again["error"]) != "":
		_fail("re-canonicalizing the parsed manifest was refused: %s" % str(again["error"]))
		return
	if str(again["text"]) != text:
		_fail("canonicalization is not a fixed point across a JSON round trip — a verifier re-deriving the bytes from the parsed manifest would compute a different signature.\n  first:  %s\n  second: %s" % [text, str(again["text"])])


func _fail(message: String) -> void:
	if _failed:
		return
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
