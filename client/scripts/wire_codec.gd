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
##     this decoder accepts the retained `LEGACY_VERSION` through `VERSION`;
##     a bump is a deliberate, reviewed expansion on both tiers.
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
## Snapshot: {"tick": int, "observer": int, "entities": [entity, ...],
##            "casts": [cast, ...]}
## Delta:    {"tick": int, "entered": [entity, ...], "moved": [entity, ...],
##            "left": [int, ...], "started_casts": [cast, ...],
##            "ended_casts": [caster_id, ...]}
## Entity:   {"id": int, "x": int, "y": int, "z": int, "radius": int}
## (positions/radius are integer millimetres, exactly as the server speaks).
##
## Both tiers assert the SAME committed fixture,
## `client/tests/data/wire_goldens.json` — see `server/wire/crosstier_wire_test.go`
## and `client/tests/wire_codec_test.gd` — so the byte layout cannot drift
## between them without both test suites moving together.

## The inclusive wire-protocol range this build decodes. Outbound negotiation
## requests VERSION; LEGACY_VERSION remains readable during expansion.
const LEGACY_VERSION := 1
const VERSION := 2

## Message kinds. Values are wire contract (mirror `wire.KindSnapshot` /
## `wire.KindSnapshotDelta`) — never renumber one.
const KIND_SNAPSHOT := 1
const KIND_SNAPSHOT_DELTA := 2

## Cap on every entity/ID list in a single frame, enforced BEFORE any
## allocation so a hostile length prefix cannot size a buffer. Mirrors
## `wire.MaxEntities` (1 << 16).
const MAX_ENTITIES := 65536
const MAX_CASTS := MAX_ENTITIES

## Fixed byte width of one encoded entity state: id + x + y + z + radius,
## each 8 bytes. Mirrors the server's `entityStateSize`.
const ENTITY_STATE_SIZE := 40
const ACTIVE_CAST_SIZE := 105

const SHAPE_CIRCLE := 0
const SHAPE_RING := 1
const SHAPE_CONE := 2
const SHAPE_RECT := 3
const COS_SCALE := 1_000_000
const MAX_WORLD_EXTENT_MM := 1_000_000
const MAX_TELEGRAPH_EXTENT_MM := 4_000_000

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
const ERR_CAST_SHAPE := "cast_shape"
const ERR_CAST_TIMING := "cast_timing"
const ERR_CAST_CASTER := "cast_caster"


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
	if version < LEGACY_VERSION or version > VERSION:
		return {
			"ok": false,
			"error": ERR_VERSION,
			"detail": "message speaks %d, this build speaks %d-%d" % [version, LEGACY_VERSION, VERSION],
		}
	var kind := r.u8()
	if not r.error.is_empty():
		return _reader_fail(r)

	if kind == KIND_SNAPSHOT:
		var snapshot := r.read_snapshot(version)
		if not r.error.is_empty():
			return _reader_fail(r)
		var verr := _validate_snapshot(snapshot)
		if not verr.is_empty():
			return {"ok": false, "error": verr["error"], "detail": verr["detail"]}
		var trailing := _check_no_trailing(r)
		if not trailing.is_empty():
			return trailing
		return {"ok": true, "version": version, "kind": KIND_SNAPSHOT, "snapshot": snapshot}

	if kind == KIND_SNAPSHOT_DELTA:
		var delta := r.read_delta(version)
		if not r.error.is_empty():
			return _reader_fail(r)
		var verr := _validate_delta(delta)
		if not verr.is_empty():
			return {"ok": false, "error": verr["error"], "detail": verr["detail"]}
		var trailing := _check_no_trailing(r)
		if not trailing.is_empty():
			return trailing
		return {"ok": true, "version": version, "kind": KIND_SNAPSHOT_DELTA, "delta": delta}

	return {"ok": false, "error": ERR_KIND, "detail": "unknown message kind %d" % kind}


# --- shared validity predicate (one source, mirrored from the server) --------
#
# The server runs validateSnapshot/validateDelta on decode as well as encode;
# this tier runs the same predicate after the structural read, so "well-formed"
# means the same thing on both ends of the wire.


static func _validate_snapshot(snapshot: Dictionary) -> Dictionary:
	var entities: Array = snapshot["entities"]
	var verr := _validate_states("entities", entities)
	if not verr.is_empty():
		return verr
	var casts: Array = snapshot["casts"]
	verr = _validate_casts("casts", int(snapshot["tick"]), casts)
	if not verr.is_empty():
		return verr
	var entity_ids: Dictionary = {}
	for e_var: Variant in entities:
		entity_ids[int((e_var as Dictionary)["id"])] = true
	for cast_var: Variant in casts:
		var caster := int((cast_var as Dictionary)["caster"])
		if not entity_ids.has(caster):
			return {"error": ERR_CAST_CASTER, "detail": "caster %d is not replicated" % caster}
	return {}


static func _validate_delta(delta: Dictionary) -> Dictionary:
	var entered: Array = delta["entered"]
	var moved: Array = delta["moved"]
	var left: Array = delta["left"]
	var started_casts: Array = delta["started_casts"]
	var ended_casts: Array = delta["ended_casts"]
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
	verr = _validate_casts("started casts", int(delta["tick"]), started_casts)
	if not verr.is_empty():
		return verr
	return _validate_ids("ended casts", ended_casts)


static func _validate_casts(list_name: String, tick: int, casts: Array) -> Dictionary:
	if casts.size() > MAX_CASTS:
		return {"error": ERR_COUNT, "detail": "%s has %d entries" % [list_name, casts.size()]}
	for i in casts.size():
		var cast: Dictionary = casts[i]
		if i > 0 and int(cast["caster"]) <= int((casts[i - 1] as Dictionary)["caster"]):
			return {"error": ERR_ORDER, "detail": "%s at index %d" % [list_name, i]}
		var start_tick := int(cast["start_tick"])
		var resolve_tick := int(cast["resolve_tick"])
		if start_tick >= resolve_tick or start_tick >= tick or resolve_tick < tick:
			return {"error": ERR_CAST_TIMING, "detail": "%s at index %d has invalid timing" % [list_name, i]}
		var shape_error := _validate_cast_shape(cast)
		if not shape_error.is_empty():
			return shape_error
	return {}


static func _validate_cast_shape(cast: Dictionary) -> Dictionary:
	var origin_x := int(cast["origin_x"])
	var origin_z := int(cast["origin_z"])
	if not _within_symmetric_limit(origin_x, MAX_WORLD_EXTENT_MM) or not _within_symmetric_limit(origin_z, MAX_WORLD_EXTENT_MM):
		return {"error": ERR_CAST_SHAPE, "detail": "cast origin is outside world bounds"}
	if int(cast["facing_y"]) != 0:
		return {"error": ERR_CAST_SHAPE, "detail": "cast facing is not planar"}
	var kind := int(cast["kind"])
	var facing_zero := int(cast["facing_x"]) == 0 and int(cast["facing_z"]) == 0
	var outer := int(cast["outer"])
	var inner := int(cast["inner"])
	var half_width := int(cast["half_width"])
	var cos_half := int(cast["cos_half"])
	var outer_valid := _within_symmetric_limit(outer, MAX_TELEGRAPH_EXTENT_MM)
	match kind:
		SHAPE_CIRCLE:
			if not facing_zero or not outer_valid or inner != 0 or half_width != 0 or cos_half != 0:
				return {"error": ERR_CAST_SHAPE, "detail": "non-canonical circle"}
		SHAPE_RING:
			var inverted_positive_ring := outer >= 0 and inner > outer
			var noncanonical_degenerate_ring := outer < 0 and inner != 0
			if not facing_zero or not outer_valid or inner < 0 or inner > MAX_TELEGRAPH_EXTENT_MM or inverted_positive_ring or noncanonical_degenerate_ring or half_width != 0 or cos_half != 0:
				return {"error": ERR_CAST_SHAPE, "detail": "non-canonical ring"}
		SHAPE_CONE:
			if not outer_valid or inner != 0 or half_width != 0 or not _within_symmetric_limit(cos_half, COS_SCALE):
				return {"error": ERR_CAST_SHAPE, "detail": "non-canonical cone"}
		SHAPE_RECT:
			if not outer_valid or inner != 0 or not _within_symmetric_limit(half_width, MAX_TELEGRAPH_EXTENT_MM) or cos_half != 0:
				return {"error": ERR_CAST_SHAPE, "detail": "non-canonical rect"}
		_:
			return {"error": ERR_CAST_SHAPE, "detail": "unknown cast kind %d" % kind}
	return {}


static func _within_symmetric_limit(value: int, limit: int) -> bool:
	# Avoid abs(INT64_MIN), which remains negative in GDScript and could make a
	# hostile minimum-int extent appear to be inside a positive bound.
	return value >= -limit and value <= limit


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

	func read_snapshot(version: int) -> Dictionary:
		var tick := u64()
		var observer := u64()
		var entities := read_states("entities")
		var casts: Array = read_casts("casts") if version >= 2 else []
		return {"tick": tick, "observer": observer, "entities": entities, "casts": casts}

	func read_delta(version: int) -> Dictionary:
		var tick := u64()
		var entered := read_states("entered")
		var moved := read_states("moved")
		var left := read_ids("left")
		var started_casts: Array = read_casts("started casts") if version >= 2 else []
		var ended_casts: Array = read_ids("ended casts") if version >= 2 else []
		return {"tick": tick, "entered": entered, "moved": moved, "left": left, "started_casts": started_casts, "ended_casts": ended_casts}

	func read_casts(list_name: String) -> Array:
		var n := u32()
		if not error.is_empty():
			return []
		if n > WireCodec.MAX_CASTS:
			record_fail(WireCodec.ERR_COUNT, "%s claims %d entries" % [list_name, n])
			return []
		if not need(n * WireCodec.ACTIVE_CAST_SIZE):
			return []
		var out: Array = []
		for _i in n:
			# Keep cursor advancement explicit. Dictionary literal evaluation order
			# is not part of the wire contract and must not define field offsets.
			var caster := u64()
			var kind := u8()
			var origin_x := s64()
			var origin_y := s64()
			var origin_z := s64()
			var facing_x := s64()
			var facing_y := s64()
			var facing_z := s64()
			var outer := s64()
			var inner := s64()
			var half_width := s64()
			var cos_half := s64()
			var start_tick := u64()
			var resolve_tick := u64()
			out.append({
				"caster": caster,
				"kind": kind,
				"origin_x": origin_x, "origin_y": origin_y, "origin_z": origin_z,
				"facing_x": facing_x, "facing_y": facing_y, "facing_z": facing_z,
				"outer": outer, "inner": inner, "half_width": half_width, "cos_half": cos_half,
				"start_tick": start_tick, "resolve_tick": resolve_tick,
			})
		if not error.is_empty():
			return []
		return out

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
