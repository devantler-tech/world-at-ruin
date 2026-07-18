class_name WireCodec
extends RefCounted
## The client half of the versioned replication wire protocol (issue #178) —
## the decoder for the snapshot/delta byte stream the server's wire codec
## (`server/wire`, #166) pins with committed hex goldens. Decode-only by
## design: the client RECEIVES replication frames, it never produces them, so
## this library carries no encoder to drift out of step with the server's.
##
## Contract parity with the Go decoder, mirrored WHOLE rather than sampled:
##   * Born versioned. Every frame opens with an explicit protocol version and
##     this decoder refuses anything other than `VERSION` — a bump is a
##     deliberate, reviewed act on both tiers, never a silent re-read of old
##     bytes.
##   * Canonical bytes only. Fixed-width little-endian integers, fixed field
##     order, list lengths up front, strictly ascending EntityID lists, and
##     pairwise-disjoint delta lists — violations are refused, never repaired,
##     exactly as the server refuses them (`ErrOrder` / `ErrOverlap`).
##   * Fail closed on untrusted bytes. Every read is bounds-checked BEFORE it
##     happens (the built-in `decode_*` helpers return 0 on a short buffer,
##     which would decode truncation into silence); list counts are capped at
##     `MAX_ENTITIES` before any allocation; trailing bytes are refused.
##   * No extra strictness beyond one documented divergence: the server accepts
##     any int64 position/radius and this tier does too (a negative radius is
##     the sim's business, not the codec's). The ONE divergence is `ERR_RANGE`:
##     GDScript ints are signed 64-bit, so an unsigned field (tick, observer,
##     id) with the top bit set cannot be represented and is refused loudly
##     rather than wrapped negative. Such values are unreachable from the real
##     sim (a tick above 2^63 is ~10^10 years of play), so refusal is the
##     honest fail-closed reading, not a compatibility gap.
##
## The decode result is a plain Dictionary (no I/O, no scene tree), so the
## contract is unit-testable exactly like `UpdateDecision` and `Telegraph`:
##   ok:    {"ok": true, "kind": KIND_SNAPSHOT, "snapshot": {...}}
##          {"ok": true, "kind": KIND_SNAPSHOT_DELTA, "delta": {...}}
##   fail:  {"ok": false, "error": ERR_*, "detail": String}
## Snapshot: {"tick": int, "observer": int, "entities": [entity, ...]}
## Delta:    {"tick": int, "entered": [entity, ...], "moved": [entity, ...],
##            "left": [int, ...]}
## Entity:   {"id": int, "x": int, "y": int, "z": int, "radius": int}
## (positions/radius are integer millimetres, exactly as the server speaks).
##
## Both tiers assert the SAME committed fixture,
## `client/tests/data/wire_goldens.json` — see `server/wire/crosstier_wire_test.go`
## and `client/tests/wire_codec_test.gd` — so the byte layout cannot drift
## between them without both test suites moving together.

## The wire-protocol version this build speaks, and the decoder's ceiling.
## Mirrors `wire.Version`; forward-only, bumped only as a reviewed act.
const VERSION := 1

## Message kinds. Values are wire contract (mirror `wire.KindSnapshot` /
## `wire.KindSnapshotDelta`) — never renumber one.
const KIND_SNAPSHOT := 1
const KIND_SNAPSHOT_DELTA := 2

## Cap on every entity/ID list in a single frame, enforced BEFORE any
## allocation so a hostile length prefix cannot size a buffer. Mirrors
## `wire.MaxEntities` (1 << 16).
const MAX_ENTITIES := 65536

## Fixed byte width of one encoded entity state: id + x + y + z + radius,
## each 8 bytes. Mirrors the server's `entityStateSize`.
const ENTITY_STATE_SIZE := 40

## Error classes, mirroring the server codec's sentinel errors one-for-one so
## a transport can classify a bad frame without string-matching. `ERR_RANGE`
## is the one client-only class (see the header note on signed-64 domain).
const ERR_TRUNCATED := "truncated"
const ERR_TRAILING := "trailing"
const ERR_VERSION := "version"
const ERR_KIND := "kind"
const ERR_COUNT := "count"
const ERR_ORDER := "order"
const ERR_OVERLAP := "overlap"
const ERR_RANGE := "range"


## Parse one wire frame. Fails closed: unknown version or kind, truncation at
## any offset, an over-cap count, out-of-order or overlapping lists, trailing
## bytes, and an unrepresentable unsigned value are all refusals — a decoded
## frame satisfies exactly the validity predicate the server enforces on both
## of its own directions.
static func decode(bytes: PackedByteArray) -> Dictionary:
	var r := _Reader.new(bytes)
	var version := r.u16()
	if not r.error.is_empty():
		return _reader_fail(r)
	if version != VERSION:
		return {
			"ok": false,
			"error": ERR_VERSION,
			"detail": "message speaks %d, this build speaks %d" % [version, VERSION],
		}
	var kind := r.u8()
	if not r.error.is_empty():
		return _reader_fail(r)

	if kind == KIND_SNAPSHOT:
		var snapshot := r.read_snapshot()
		if not r.error.is_empty():
			return _reader_fail(r)
		var verr := _validate_snapshot(snapshot)
		if not verr.is_empty():
			return {"ok": false, "error": verr["error"], "detail": verr["detail"]}
		var trailing := _check_no_trailing(r)
		if not trailing.is_empty():
			return trailing
		return {"ok": true, "kind": KIND_SNAPSHOT, "snapshot": snapshot}

	if kind == KIND_SNAPSHOT_DELTA:
		var delta := r.read_delta()
		if not r.error.is_empty():
			return _reader_fail(r)
		var verr := _validate_delta(delta)
		if not verr.is_empty():
			return {"ok": false, "error": verr["error"], "detail": verr["detail"]}
		var trailing := _check_no_trailing(r)
		if not trailing.is_empty():
			return trailing
		return {"ok": true, "kind": KIND_SNAPSHOT_DELTA, "delta": delta}

	return {"ok": false, "error": ERR_KIND, "detail": "unknown message kind %d" % kind}


# --- shared validity predicate (one source, mirrored from the server) --------
#
# The server runs validateSnapshot/validateDelta on decode as well as encode;
# this tier runs the same predicate after the structural read, so "well-formed"
# means the same thing on both ends of the wire.


static func _validate_snapshot(snapshot: Dictionary) -> Dictionary:
	var entities: Array = snapshot["entities"]
	return _validate_states("entities", entities)


static func _validate_delta(delta: Dictionary) -> Dictionary:
	var entered: Array = delta["entered"]
	var moved: Array = delta["moved"]
	var left: Array = delta["left"]
	var verr := _validate_states("entered", entered)
	if not verr.is_empty():
		return verr
	verr = _validate_states("moved", moved)
	if not verr.is_empty():
		return verr
	verr = _validate_ids("left", left)
	if not verr.is_empty():
		return verr
	# The server's tracker makes entered/moved/left pairwise disjoint; a frame
	# violating that would make spawn/update/despawn apply ambiguous, so it is
	# invalid — refused here exactly as the server refuses it.
	var seen: Dictionary = {}
	verr = _claim_ids(seen, "entered", entered, true)
	if not verr.is_empty():
		return verr
	verr = _claim_ids(seen, "moved", moved, true)
	if not verr.is_empty():
		return verr
	verr = _claim_ids(seen, "left", left, false)
	if not verr.is_empty():
		return verr
	return {}


## Enforce the list contract on an entity-state list: at most MAX_ENTITIES
## entries, strictly ascending by id (which also forbids duplicates).
static func _validate_states(list_name: String, states: Array) -> Dictionary:
	if states.size() > MAX_ENTITIES:
		return {"error": ERR_COUNT, "detail": "%s has %d entries" % [list_name, states.size()]}
	for i in range(1, states.size()):
		var prev: Dictionary = states[i - 1]
		var curr: Dictionary = states[i]
		if int(curr["id"]) <= int(prev["id"]):
			return {"error": ERR_ORDER, "detail": "%s at index %d" % [list_name, i]}
	return {}


## _validate_states for a bare ID list.
static func _validate_ids(list_name: String, ids: Array) -> Dictionary:
	if ids.size() > MAX_ENTITIES:
		return {"error": ERR_COUNT, "detail": "%s has %d entries" % [list_name, ids.size()]}
	for i in range(1, ids.size()):
		if int(ids[i]) <= int(ids[i - 1]):
			return {"error": ERR_ORDER, "detail": "%s at index %d" % [list_name, i]}
	return {}


## Claim every id in `entries` into `seen`, refusing one already claimed by an
## earlier list. `entries` holds entity Dictionaries when `states` is true,
## bare ids otherwise.
static func _claim_ids(seen: Dictionary, list_name: String, entries: Array, states: bool) -> Dictionary:
	for entry: Variant in entries:
		var id: int = int((entry as Dictionary)["id"]) if states else int(entry)
		if seen.has(id):
			return {
				"error": ERR_OVERLAP,
				"detail": "entity %d in both %s and %s" % [id, seen[id], list_name],
			}
		seen[id] = list_name
	return {}


static func _check_no_trailing(r: _Reader) -> Dictionary:
	if r.off != r.buf.size():
		return {
			"ok": false,
			"error": ERR_TRAILING,
			"detail": "%d byte(s) after message" % (r.buf.size() - r.off),
		}
	return {}


static func _reader_fail(r: _Reader) -> Dictionary:
	return {"ok": false, "error": r.error, "detail": r.detail}


# --- bounds-checked frame reader ---------------------------------------------


## A bounds-checked cursor over one frame, mirroring the server's `reader`.
## Every read either yields a value or records the FIRST failure in
## `error`/`detail`; after a failure every further read is a no-op returning 0,
## so callers check once per structural stage. Nothing reads the buffer
## unchecked — the built-in `decode_*` helpers silently return 0 past the end,
## which is exactly the truncation-into-silence this guard exists to prevent.
class _Reader:
	var buf: PackedByteArray
	var off: int = 0
	var error: String = ""
	var detail: String = ""

	func _init(bytes: PackedByteArray) -> void:
		buf = bytes

	func record_fail(err: String, why: String) -> void:
		if error.is_empty():
			error = err
			detail = why

	func need(n: int) -> bool:
		if not error.is_empty():
			return false
		if buf.size() - off < n:
			record_fail(
				WireCodec.ERR_TRUNCATED,
				"need %d byte(s) at offset %d, have %d" % [n, off, buf.size() - off]
			)
			return false
		return true

	func u8() -> int:
		if not need(1):
			return 0
		var v := buf.decode_u8(off)
		off += 1
		return v

	func u16() -> int:
		if not need(2):
			return 0
		var v := buf.decode_u16(off)
		off += 2
		return v

	func u32() -> int:
		if not need(4):
			return 0
		var v := buf.decode_u32(off)
		off += 4
		return v

	## Read an unsigned 64-bit field. GDScript ints are signed 64-bit, so a
	## value with the top bit set has no faithful representation — it is
	## refused (`ERR_RANGE`) rather than silently wrapped negative. See the
	## header note: unreachable from the real sim, refusal is the fail-closed
	## reading.
	func u64() -> int:
		if not need(8):
			return 0
		var v := buf.decode_u64(off)
		off += 8
		if v < 0:
			record_fail(
				WireCodec.ERR_RANGE,
				"unsigned field at offset %d has the top bit set — outside the client's signed-64 domain" % (off - 8)
			)
			return 0
		return v

	## Read a signed 64-bit field (positions, radius): plain two's complement,
	## full int64 domain, no range restriction — parity with the server.
	func s64() -> int:
		if not need(8):
			return 0
		var v := buf.decode_s64(off)
		off += 8
		return v

	func read_snapshot() -> Dictionary:
		var tick := u64()
		var observer := u64()
		var entities := read_states("entities")
		return {"tick": tick, "observer": observer, "entities": entities}

	func read_delta() -> Dictionary:
		var tick := u64()
		var entered := read_states("entered")
		var moved := read_states("moved")
		var left := read_ids("left")
		return {"tick": tick, "entered": entered, "moved": moved, "left": left}

	## Read a count-prefixed entity-state list. The cap check runs BEFORE the
	## byte-availability check and BEFORE any allocation, so a hostile count is
	## reported as ERR_COUNT and can never size a buffer — the same order the
	## server enforces.
	func read_states(list_name: String) -> Array:
		var n := u32()
		if not error.is_empty():
			return []
		if n > WireCodec.MAX_ENTITIES:
			record_fail(WireCodec.ERR_COUNT, "%s claims %d entries" % [list_name, n])
			return []
		if not need(n * WireCodec.ENTITY_STATE_SIZE):
			return []
		var out: Array = []
		for _i in n:
			var id := u64()
			var x := s64()
			var y := s64()
			var z := s64()
			var radius := s64()
			out.append({"id": id, "x": x, "y": y, "z": z, "radius": radius})
		if not error.is_empty():
			return []
		return out

	## Read a count-prefixed ID list, under the same cap-first rule.
	func read_ids(list_name: String) -> Array:
		var n := u32()
		if not error.is_empty():
			return []
		if n > WireCodec.MAX_ENTITIES:
			record_fail(WireCodec.ERR_COUNT, "%s claims %d entries" % [list_name, n])
			return []
		if not need(n * 8):
			return []
		var out: Array = []
		for _i in n:
			out.append(u64())
		if not error.is_empty():
			return []
		return out
