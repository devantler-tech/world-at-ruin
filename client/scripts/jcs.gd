class_name JCS
## JSON Canonicalization Scheme (RFC 8785) — the exact bytes a signature covers.
##
## The distribution ADR pins the signed bytes to a published standard so that two
## conforming implementations never derive different bytes:
##
##   "Canonicalization pinned to a standard. The signed bytes use JCS (RFC 8785)
##    with shared test vectors both CI and the client consume, so two conforming
##    implementations never derive different bytes and reject every otherwise-valid
##    update."
##   — docs/design/distribution-and-self-update.md
##
## That is not a stylistic preference. A signer and a verifier that disagree by one
## byte reject every otherwise-valid update, and the player sees a client that has
## simply stopped updating. The failure is silent on both ends, which is why the
## standard is pinned rather than left to each implementation's JSON writer.
##
## [b]Why this is not [code]JSON.stringify(..., sort_keys)[/code].[/b] Godot sorts
## dictionary keys by CODE POINT; JCS mandates UTF-16 CODE UNIT order. The two
## disagree for every supplementary-plane key, because a code point above U+FFFF is
## a surrogate pair beginning in 0xD800-0xDBFF, which sorts BELOW the 0xE000-0xFFFF
## range it exceeds numerically. Godot serialises `{"�":2,"\U00010000":1}`
## where JCS requires `{"\U00010000":1,"�":2}` — opposite orders, same input.
## `tests/data/jcs_vectors.json` pins that case, among others.
##
## [b]The domain is deliberately narrow, and out-of-domain values are REFUSED.[/b]
## RFC 8785 serialises numbers with ECMAScript `Number::toString`, a shortest-
## round-trip algorithm that is genuinely difficult to reproduce and that nothing in
## this repo currently needs: the update manifest carries integers only. Emitting
## plausible-but-unverified bytes for a value we have not conformance-tested is
## precisely the "manifest that lies" [UpdateManifest] exists to refuse — and under
## a signing scheme it would not merely be wrong, it would be wrong in a way that
## only shows up as a rejected update in the field. So a non-integral number is an
## error here, not a best effort. Widening the domain means adding vectors first.
##
## The same bound applies to whole numbers, from BOTH directions — a GDScript `int`
## is 64-bit and holds values ECMAScript cannot represent, so anything past 2^53 is
## refused however it arrived. See [method _write_integer].
##
## Run the conformance suite: godot --headless --path client res://tests/jcs_test.tscn

## Integers are exact in a float only up to 2^53 — the ECMAScript safe-integer
## ceiling. Godot's JSON parser returns every number as a float (`1` parses as
## `1.0`), so an integral float is a normal, expected input here; beyond this
## magnitude it can no longer be trusted to be the integer it appears to be.
const MAX_SAFE_INTEGER := 9007199254740992  # 2^53

## Depth ceiling. JSON cannot express a cycle, but a Dictionary can hold one, and
## an unbounded walk would hang rather than fail. Far above any real manifest.
const MAX_DEPTH := 64


## Canonicalize [param value] to RFC 8785 bytes.
##
## Returns `{"error": String, "text": String}` — the same result shape
## [UpdateManifest.build] uses. `error` is empty on success; when it is non-empty
## `text` is empty and MUST NOT be signed, stored or transmitted.
static func canonicalize(value: Variant) -> Dictionary:
	var parts := PackedStringArray()
	var error := _write(value, parts, 0)
	if error != "":
		return {"error": error, "text": ""}
	return {"error": "", "text": "".join(parts)}


## Append the canonical form of [param value] to [param out], or return an error.
static func _write(value: Variant, out: PackedStringArray, depth: int) -> String:
	if depth > MAX_DEPTH:
		return "nesting exceeds %d levels — refusing to walk a structure that may be cyclic" % MAX_DEPTH

	match typeof(value):
		TYPE_NIL:
			out.append("null")
		TYPE_BOOL:
			out.append("true" if value else "false")
		TYPE_INT:
			return _write_integer(value, out)
		TYPE_FLOAT:
			return _write_number(value, out)
		TYPE_STRING, TYPE_STRING_NAME:
			out.append(quote(String(value)))
		TYPE_ARRAY:
			return _write_array(value, out, depth)
		TYPE_DICTIONARY:
			return _write_object(value, out, depth)
		_:
			return "refusing to canonicalize a value of type '%s' — RFC 8785 covers JSON values only, and a lossy coercion here would be signed as if it were the original" % type_string(typeof(value))
	return ""


## A GDScript `int` is a 64-bit integer, so it can hold values ECMAScript cannot
## represent — and RFC 8785 serialises numbers with ECMAScript `Number::toString`,
## whose number model is IEEE 754 double. Above 2^53 there is no exact double, so a
## conforming implementation reading the same JSON would emit the nearest
## representable value instead: `9007199254740993` canonicalizes to
## `...992` there and would have canonicalized to `...993` here. Two
## implementations, different signing bytes — the exact divergence this module
## exists to prevent, and invisible until a signature fails to verify.
##
## Reachable only from GDScript-constructed values: Godot's JSON parser returns
## every number as a float, so no parsed input takes this path. That is precisely
## why the vector file cannot cover it and the regression test builds the value
## programmatically.
static func _write_integer(value: int, out: PackedStringArray) -> String:
	# Compared without absi(): the magnitude of the most negative int64 has no
	# positive counterpart, so taking its absolute value overflows back to itself.
	if value > MAX_SAFE_INTEGER or value < -MAX_SAFE_INTEGER:
		return "refusing to canonicalize the integer %d — it exceeds 2^53, and RFC 8785 numbers follow ECMAScript Number::toString (IEEE 754 double), so a conforming implementation would emit the nearest representable value rather than this one and the two would never agree on the signing bytes" % value
	out.append(str(value))
	return ""


## Numbers, restricted to the integral domain this module has vectors for.
static func _write_number(value: float, out: PackedStringArray) -> String:
	if is_nan(value) or is_inf(value):
		return "refusing to canonicalize %s — JSON has no representation for it" % str(value)
	if value != floor(value):
		return "refusing to canonicalize the non-integral number %s — RFC 8785 requires ECMAScript Number::toString, which this module does not implement and has no test vectors for (see the class comment); the update manifest carries integers only" % str(value)
	if absf(value) > float(MAX_SAFE_INTEGER):
		return "refusing to canonicalize %s — beyond 2^53 an integral float is no longer exactly the integer it appears to be, so the canonical bytes would not be reproducible" % str(value)
	# ECMAScript renders an integral Number without a fractional part, and has no
	# negative zero in its string form: Number::toString(-0) is "0".
	out.append(str(int(value)))
	return ""


static func _write_array(value: Array, out: PackedStringArray, depth: int) -> String:
	out.append("[")
	for i in value.size():
		if i > 0:
			out.append(",")
		var error := _write(value[i], out, depth + 1)
		if error != "":
			return error
	out.append("]")
	return ""


static func _write_object(value: Dictionary, out: PackedStringArray, depth: int) -> String:
	# Sort on the canonical String form but KEEP the original key to look the value
	# back up: a Dictionary may be keyed by StringName, and re-indexing it with a
	# coerced String is not guaranteed to find the same entry.
	var entries := []
	for key in value.keys():
		if not (key is String or key is StringName):
			return "refusing to canonicalize an object keyed by '%s' — a JSON member name is a string, and inventing one here would sign a name the source never had" % type_string(typeof(key))
		entries.append([String(key), key])

	entries.sort_custom(func(a: Array, b: Array) -> bool: return _utf16_less(a[0], b[0]))

	out.append("{")
	for i in entries.size():
		var name: String = entries[i][0]
		if i > 0:
			if name == entries[i - 1][0]:
				# Only reachable via mixed String/StringName keys; JSON parsing cannot
				# produce it. Two members with one name have no canonical order.
				return "refusing to canonicalize an object with the duplicate member name '%s' — its canonical order is undefined" % name
			out.append(",")
		out.append(quote(name))
		out.append(":")
		var error := _write(value[entries[i][1]], out, depth + 1)
		if error != "":
			return error
	out.append("}")
	return ""


## Quote and escape [param text] per RFC 8785 §3.2.2.2 — the MINIMAL escaping
## ECMAScript `JSON.stringify` performs. Note what is deliberately NOT escaped:
## the solidus `/`, U+007F DEL, and every non-ASCII code point, which are emitted
## literally as UTF-8. Escaping them would be valid JSON and the wrong bytes.
static func quote(text: String) -> String:
	var parts := PackedStringArray()
	parts.append("\"")
	for i in text.length():
		var cp := text.unicode_at(i)
		match cp:
			0x22:
				parts.append("\\\"")
			0x5C:
				parts.append("\\\\")
			0x08:
				parts.append("\\b")
			0x09:
				parts.append("\\t")
			0x0A:
				parts.append("\\n")
			0x0C:
				parts.append("\\f")
			0x0D:
				parts.append("\\r")
			_:
				if cp < 0x20:
					# Lowercase hex, four digits — RFC 8785 is explicit about the case.
					parts.append("\\u%04x" % cp)
				else:
					parts.append(String.chr(cp))
	parts.append("\"")
	return "".join(parts)


## The UTF-16 code units of [param text].
##
## Godot stores strings as UTF-32: `length()` counts code points and `unicode_at`
## returns one. JCS orders member names by UTF-16 code unit, so the surrogate pairs
## have to be reconstructed explicitly — this is the whole reason sorting Godot
## Strings directly produces the wrong order for supplementary-plane names.
static func _utf16_units(text: String) -> PackedInt32Array:
	var units := PackedInt32Array()
	for i in text.length():
		var cp := text.unicode_at(i)
		if cp < 0x10000:
			units.append(cp)
		else:
			var offset := cp - 0x10000
			units.append(0xD800 + (offset >> 10))
			units.append(0xDC00 + (offset & 0x3FF))
	return units


## Lexicographic comparison of two member names by UTF-16 code unit.
static func _utf16_less(a: String, b: String) -> bool:
	var ua := _utf16_units(a)
	var ub := _utf16_units(b)
	var shared: int = mini(ua.size(), ub.size())
	for i in shared:
		if ua[i] != ub[i]:
			return ua[i] < ub[i]
	return ua.size() < ub.size()
