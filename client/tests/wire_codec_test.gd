extends Node
## Client wire decoder vs the cross-tier goldens (issue #178).
##
## The server's wire codec (#166) pins the replication byte layout with
## committed goldens whose stated purpose is to anchor THIS decoder. This test
## reads the SAME committed fixture as `server/wire/crosstier_wire_test.go`
## (`tests/data/wire_goldens.json`): the Go side proves the shipped codec
## produces exactly the fixture's bytes from the fixture's values, and this
## side proves the GDScript decoder reads those bytes back to those values —
## so the two tiers cannot drift apart without both suites moving together.
##
## Beyond the goldens, every refusal class the server enforces is proven here
## with a negative control isolated to ONE law, asserting the EXACT error
## class (a control failing for the wrong reason proves nothing):
##   * truncated  — every strict prefix of both goldens is refused as such
##   * trailing   — one extra byte after a valid frame
##   * version    — versions 0 and 2 refused before any payload read
##   * kind       — kind 3 refused as `kind`, not as truncation (order proof)
##   * count      — a count claiming 65537 refuses as `count` with NO list
##                  bytes present (cap-before-need proof); 65536 is accepted
##                  (the cap is exclusive, boundary proven from both sides)
##   * order      — out-of-order and duplicate ids, in EVERY list surface
##                  (entities / entered / moved / left)
##   * overlap    — one id claimed by two delta lists, all three pairs
##   * range      — the client-only signed-64 domain refusal on tick,
##                  observer and id; positions prove s64 (min int64 accepted)
##
## Crafted frames come from a test-local builder that is asserted to produce
## DECODABLE frames first (a broken builder would fail every control for the
## wrong reason), and the builder never shares code with the decoder — the
## byte layout itself is anchored by the Go-produced goldens.
##
## Pure logic and a res:// read only — no scene, no save, no boot — so it is
## safe to run locally and deterministic in CI.
##
## Run: godot --headless --path client res://tests/wire_codec_test.tscn

const FIXTURE := "res://tests/data/wire_goldens.json"

## Values with the top bit set are unrepresentable as unsigned in GDScript's
## signed-64 ints; `1 << 63` wraps to min-int64, which is exactly the bit
## pattern the range guard must refuse on unsigned fields and the s64 path
## must accept on signed ones.
const TOP_BIT: int = 1 << 63

var _failed := false


func _ready() -> void:
	var fixture := _load_fixture()
	if _failed:
		return
	var snapshot_msg: Dictionary = fixture["snapshot"]
	var delta_msg: Dictionary = fixture["delta"]
	var snapshot_bytes: PackedByteArray = (snapshot_msg["hex"] as String).hex_decode()
	var delta_bytes: PackedByteArray = (delta_msg["hex"] as String).hex_decode()

	if not _check_snapshot_golden(snapshot_msg, snapshot_bytes):
		return
	if not _check_delta_golden(delta_msg, delta_bytes):
		return
	if not _check_builder_baselines():
		return
	if not _check_truncation_sweep("snapshot golden", snapshot_bytes):
		return
	if not _check_truncation_sweep("delta golden", delta_bytes):
		return
	if not _check_trailing(snapshot_bytes) or not _check_trailing(delta_bytes):
		return
	if not _check_version_refused(snapshot_bytes):
		return
	if not _check_kind_refused():
		return
	if not _check_count_cap():
		return
	if not _check_order_refused():
		return
	if not _check_overlap_refused():
		return
	if not _check_unsigned_range():
		return

	print("TEST PASS — wire decoder matches the cross-tier goldens and refuses every malformed-frame class the server refuses (%d + %d golden bytes swept for truncation; count cap proven from both sides at %d)"
		% [snapshot_bytes.size(), delta_bytes.size(), WireCodec.MAX_ENTITIES])
	get_tree().quit(0)


# --- fixture -----------------------------------------------------------------


## Load the shared fixture and hand back {"snapshot": msg, "delta": msg}.
## Fails loud on a missing, unparsable, or non-substantive fixture: a decoder
## test whose fixture silently vanished would pass vacuously.
func _load_fixture() -> Dictionary:
	var text := FileAccess.get_file_as_string(FIXTURE)
	if text.is_empty():
		_fail("fixture %s is missing or empty — the cross-tier contract has no anchor" % FIXTURE)
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if parsed is not Dictionary:
		_fail("fixture %s did not parse as a JSON object" % FIXTURE)
		return {}
	var root: Dictionary = parsed
	if root.get("messages") is not Array:
		_fail("fixture has no 'messages' array")
		return {}
	var messages: Array = root["messages"]
	var out: Dictionary = {}
	for entry: Variant in messages:
		if entry is not Dictionary:
			_fail("fixture message is not an object")
			return {}
		var msg: Dictionary = entry
		var kind := String(msg.get("kind", ""))
		if msg.get("hex") is not String or String(msg["hex"]).is_empty():
			_fail("fixture message '%s' has no hex payload" % kind)
			return {}
		if String(msg["hex"]).length() % 2 != 0:
			_fail("fixture message '%s' hex has odd length" % kind)
			return {}
		out[kind] = msg
	if not out.has("snapshot") or not out.has("delta"):
		_fail("fixture must carry exactly one snapshot and one delta golden (got: %s)" % str(out.keys()))
		return {}
	# Substantive floor: the snapshot golden pins the multi-entry layout and
	# the delta golden pins all three lists — an emptied-out fixture would let
	# most of the layout go unasserted.
	var snapshot_entities: Array = (out["snapshot"]["snapshot"] as Dictionary)["entities"]
	if snapshot_entities.size() < 2:
		_fail("snapshot golden must keep >= 2 entities to pin the multi-entry layout")
		return {}
	var delta_want: Dictionary = out["delta"]["delta"]
	for list_name: String in ["entered", "moved", "left"]:
		if (delta_want[list_name] as Array).is_empty():
			_fail("delta golden must keep a non-empty '%s' list" % list_name)
			return {}
	return out


# --- golden agreement --------------------------------------------------------


func _check_snapshot_golden(msg: Dictionary, bytes: PackedByteArray) -> bool:
	var res := WireCodec.decode(bytes)
	if not _expect_ok(res, "snapshot golden"):
		return false
	if int(res["kind"]) != WireCodec.KIND_SNAPSHOT:
		_fail("snapshot golden decoded to kind %d" % int(res["kind"]))
		return false
	var got: Dictionary = res["snapshot"]
	var want: Dictionary = msg["snapshot"]
	if int(got["tick"]) != int(want["tick"]) or int(got["observer"]) != int(want["observer"]):
		_fail("snapshot golden header mismatch: got tick=%d observer=%d, want tick=%d observer=%d"
			% [int(got["tick"]), int(got["observer"]), int(want["tick"]), int(want["observer"])])
		return false
	return _expect_entities("snapshot entities", got["entities"], want["entities"])


func _check_delta_golden(msg: Dictionary, bytes: PackedByteArray) -> bool:
	var res := WireCodec.decode(bytes)
	if not _expect_ok(res, "delta golden"):
		return false
	if int(res["kind"]) != WireCodec.KIND_SNAPSHOT_DELTA:
		_fail("delta golden decoded to kind %d" % int(res["kind"]))
		return false
	var got: Dictionary = res["delta"]
	var want: Dictionary = msg["delta"]
	if int(got["tick"]) != int(want["tick"]):
		_fail("delta golden tick mismatch: got %d, want %d" % [int(got["tick"]), int(want["tick"])])
		return false
	if not _expect_entities("delta entered", got["entered"], want["entered"]):
		return false
	if not _expect_entities("delta moved", got["moved"], want["moved"]):
		return false
	var got_left: Array = got["left"]
	var want_left: Array = want["left"]
	if got_left.size() != want_left.size():
		_fail("delta left size mismatch: got %d, want %d" % [got_left.size(), want_left.size()])
		return false
	for i in want_left.size():
		if int(got_left[i]) != int(want_left[i]):
			_fail("delta left[%d] mismatch: got %d, want %d" % [i, int(got_left[i]), int(want_left[i])])
			return false
	return true


func _expect_entities(label: String, got_variant: Variant, want_variant: Variant) -> bool:
	var got: Array = got_variant
	var want: Array = want_variant
	if got.size() != want.size():
		_fail("%s size mismatch: got %d, want %d" % [label, got.size(), want.size()])
		return false
	for i in want.size():
		var g: Dictionary = got[i]
		var w: Dictionary = want[i]
		for key: String in ["id", "x", "y", "z", "radius"]:
			if int(g[key]) != int(w[key]):
				_fail("%s[%d].%s mismatch: got %d, want %d" % [label, i, key, int(g[key]), int(w[key])])
				return false
	return true


# --- refusal controls --------------------------------------------------------


func _check_builder_baselines() -> bool:
	# Precondition for every crafted control below: the builder produces frames
	# the decoder accepts, including empty lists — otherwise a control could
	# "pass" because the builder is broken, not because the law under test held.
	var snapshot := _snapshot_frame(5, 1, [[2, -1, 0, 1, 30]])
	if not _expect_ok(WireCodec.decode(snapshot), "builder snapshot baseline"):
		return false
	var empty_snapshot := _snapshot_frame(0, 9, [])
	var empty_res := WireCodec.decode(empty_snapshot)
	if not _expect_ok(empty_res, "builder empty snapshot"):
		return false
	if not ((empty_res["snapshot"] as Dictionary)["entities"] as Array).is_empty():
		_fail("empty snapshot decoded with phantom entities")
		return false
	var empty_delta := _delta_frame(7, [], [], [])
	var delta_res := WireCodec.decode(empty_delta)
	if not _expect_ok(delta_res, "builder empty delta"):
		return false
	var d: Dictionary = delta_res["delta"]
	if not (d["entered"] as Array).is_empty() or not (d["moved"] as Array).is_empty() or not (d["left"] as Array).is_empty():
		_fail("empty delta decoded with phantom entries")
		return false
	# s64 proof: min int64 is a VALID position (signed path), while the same
	# bit pattern on an unsigned field is refused below in _check_unsigned_range.
	var min_pos := _snapshot_frame(5, 1, [[2, TOP_BIT, 0, 0, 5]])
	var min_res := WireCodec.decode(min_pos)
	if not _expect_ok(min_res, "min-int64 position"):
		return false
	var min_entity: Dictionary = ((min_res["snapshot"] as Dictionary)["entities"] as Array)[0]
	if int(min_entity["x"]) != TOP_BIT:
		_fail("min-int64 x decoded to %d, expected %d — positions must be two's-complement signed" % [int(min_entity["x"]), TOP_BIT])
		return false
	return true


func _check_truncation_sweep(name: String, bytes: PackedByteArray) -> bool:
	for cut in bytes.size():
		var res := WireCodec.decode(bytes.slice(0, cut))
		if not _expect_error(res, WireCodec.ERR_TRUNCATED, "%s cut to %d byte(s)" % [name, cut]):
			return false
	return true


func _check_trailing(bytes: PackedByteArray) -> bool:
	var padded := bytes.duplicate()
	padded.append(0)
	return _expect_error(WireCodec.decode(padded), WireCodec.ERR_TRAILING, "frame with one trailing byte")


func _check_version_refused(snapshot_bytes: PackedByteArray) -> bool:
	for bad_version in [0, 2]:
		var b := snapshot_bytes.duplicate()
		b.encode_u16(0, bad_version)
		if not _expect_error(WireCodec.decode(b), WireCodec.ERR_VERSION, "version %d frame" % bad_version):
			return false
	return true


func _check_kind_refused() -> bool:
	# Header only, kind 3: must refuse as `kind` (not truncation) — proving the
	# kind gate runs before any payload read, as it does on the server.
	return _expect_error(WireCodec.decode("010003".hex_decode()), WireCodec.ERR_KIND, "kind-3 frame")


func _check_count_cap() -> bool:
	# A snapshot claiming 65537 entities with ZERO list bytes: must refuse as
	# `count`, not `truncated` — proving the cap is checked before the byte
	# availability check (and so before any allocation).
	var lie := PackedByteArray()
	_u16(lie, WireCodec.VERSION)
	_u8(lie, WireCodec.KIND_SNAPSHOT)
	_u64(lie, 1)
	_u64(lie, 1)
	_u32(lie, WireCodec.MAX_ENTITIES + 1)
	if not _expect_error(WireCodec.decode(lie), WireCodec.ERR_COUNT, "count claiming %d" % (WireCodec.MAX_ENTITIES + 1)):
		return false
	# The boundary from the other side: exactly MAX_ENTITIES ids is accepted
	# (the cap is exclusive). Preallocate once — 64Ki incremental resizes are
	# quadratic in copied bytes.
	var full := PackedByteArray()
	_u16(full, WireCodec.VERSION)
	_u8(full, WireCodec.KIND_SNAPSHOT_DELTA)
	_u64(full, 1)
	_u32(full, 0)
	_u32(full, 0)
	_u32(full, WireCodec.MAX_ENTITIES)
	var base := full.size()
	full.resize(base + WireCodec.MAX_ENTITIES * 8)
	for i in WireCodec.MAX_ENTITIES:
		full.encode_u64(base + i * 8, i)
	var res := WireCodec.decode(full)
	if not _expect_ok(res, "delta with exactly MAX_ENTITIES left ids"):
		return false
	if ((res["delta"] as Dictionary)["left"] as Array).size() != WireCodec.MAX_ENTITIES:
		_fail("MAX_ENTITIES boundary frame decoded to %d ids" % ((res["delta"] as Dictionary)["left"] as Array).size())
		return false
	return true


func _check_order_refused() -> bool:
	var e_low: Array = [2, 0, 0, 0, 1]
	var e_high: Array = [3, 0, 0, 0, 1]
	var cases: Array = [
		["snapshot entities out of order", _snapshot_frame(1, 1, [e_high, e_low])],
		["snapshot entities duplicate id", _snapshot_frame(1, 1, [e_low, e_low])],
		["delta entered out of order", _delta_frame(1, [e_high, e_low], [], [])],
		["delta moved out of order", _delta_frame(1, [], [e_high, e_low], [])],
		["delta left out of order", _delta_frame(1, [], [], [7, 3])],
		["delta left duplicate id", _delta_frame(1, [], [], [3, 3])],
	]
	for c: Array in cases:
		if not _expect_error(WireCodec.decode(c[1]), WireCodec.ERR_ORDER, c[0]):
			return false
	return true


func _check_overlap_refused() -> bool:
	var e2: Array = [2, 0, 0, 0, 1]
	var cases: Array = [
		["id in entered and moved", _delta_frame(1, [e2], [e2], [])],
		["id in entered and left", _delta_frame(1, [e2], [], [2])],
		["id in moved and left", _delta_frame(1, [], [e2], [2])],
	]
	for c: Array in cases:
		if not _expect_error(WireCodec.decode(c[1]), WireCodec.ERR_OVERLAP, c[0]):
			return false
	return true


func _check_unsigned_range() -> bool:
	var cases: Array = [
		["top-bit tick", _snapshot_frame(TOP_BIT, 1, [])],
		["top-bit observer", _snapshot_frame(1, TOP_BIT, [])],
		["top-bit entity id", _snapshot_frame(1, 1, [[TOP_BIT, 0, 0, 0, 1]])],
	]
	for c: Array in cases:
		if not _expect_error(WireCodec.decode(c[1]), WireCodec.ERR_RANGE, c[0]):
			return false
	return true


# --- crafted-frame builder (test-local; layout anchored by the Go goldens) ---


func _u8(arr: PackedByteArray, v: int) -> void:
	var at := arr.size()
	arr.resize(at + 1)
	arr.encode_u8(at, v)


func _u16(arr: PackedByteArray, v: int) -> void:
	var at := arr.size()
	arr.resize(at + 2)
	arr.encode_u16(at, v)


func _u32(arr: PackedByteArray, v: int) -> void:
	var at := arr.size()
	arr.resize(at + 4)
	arr.encode_u32(at, v)


func _u64(arr: PackedByteArray, v: int) -> void:
	var at := arr.size()
	arr.resize(at + 8)
	arr.encode_u64(at, v)


func _s64(arr: PackedByteArray, v: int) -> void:
	var at := arr.size()
	arr.resize(at + 8)
	arr.encode_s64(at, v)


## An entity is a 5-int array: [id, x, y, z, radius].
func _states(arr: PackedByteArray, entities: Array) -> void:
	_u32(arr, entities.size())
	for e: Array in entities:
		_u64(arr, e[0])
		_s64(arr, e[1])
		_s64(arr, e[2])
		_s64(arr, e[3])
		_s64(arr, e[4])


func _snapshot_frame(tick: int, observer: int, entities: Array) -> PackedByteArray:
	var b := PackedByteArray()
	_u16(b, WireCodec.VERSION)
	_u8(b, WireCodec.KIND_SNAPSHOT)
	_u64(b, tick)
	_u64(b, observer)
	_states(b, entities)
	return b


func _delta_frame(tick: int, entered: Array, moved: Array, left: Array) -> PackedByteArray:
	var b := PackedByteArray()
	_u16(b, WireCodec.VERSION)
	_u8(b, WireCodec.KIND_SNAPSHOT_DELTA)
	_u64(b, tick)
	_states(b, entered)
	_states(b, moved)
	_u32(b, left.size())
	for id: int in left:
		_u64(b, id)
	return b


# --- assertion helpers -------------------------------------------------------


func _expect_ok(res: Dictionary, label: String) -> bool:
	if not bool(res.get("ok", false)):
		_fail("%s refused: %s (%s)" % [label, res.get("error", "?"), res.get("detail", "?")])
		return false
	return true


func _expect_error(res: Dictionary, want_error: String, label: String) -> bool:
	if bool(res.get("ok", false)):
		_fail("%s decoded OK — expected refusal '%s'" % [label, want_error])
		return false
	if String(res.get("error", "")) != want_error:
		_fail("%s refused as '%s' (%s) — expected '%s'; a control failing for the wrong reason proves nothing"
			% [label, res.get("error", "?"), res.get("detail", "?"), want_error])
		return false
	return true


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
