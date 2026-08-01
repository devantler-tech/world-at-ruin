extends Node

const FIXTURE := "res://tests/data/wire_goldens.json"


func _ready() -> void:
	var root := _load_fixture()
	if root.is_empty():
		return
	if not _check_retained_v1(root):
		return
	if not _check_authoritative_cast_stream(root):
		return
	if not _check_malformed_casts(root):
		return
	if not _check_store_atomicity_and_replacement():
		return
	print("TEST PASS — authoritative cast stream decodes and folds atomically with v1 retained and malformed casts refused")
	get_tree().quit(0)


func _load_fixture() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	if parsed is not Dictionary:
		_fail("shared wire fixture is missing or invalid")
		return {}
	var root: Dictionary = parsed
	if root.get("cast_stream") is not Dictionary:
		_fail("shared wire fixture has no cast_stream")
		return {}
	return root


func _check_retained_v1(root: Dictionary) -> bool:
	var legacy: Dictionary = (root["messages"] as Array)[0]
	var decoded := WireCodec.decode((legacy["hex"] as String).hex_decode())
	if decoded.get("ok") != true or int(decoded.get("version", 0)) != WireCodec.LEGACY_VERSION:
		_fail("retained v1 fixture refused or mislabelled: %s" % str(decoded))
		return false
	if not ((decoded["snapshot"] as Dictionary)["casts"] as Array).is_empty():
		_fail("entity-only v1 unexpectedly decoded casts")
		return false
	return true


func _check_authoritative_cast_stream(root: Dictionary) -> bool:
	var stream: Dictionary = root["cast_stream"]
	var frames: Array = stream["frames"]
	if frames.size() != 3:
		_fail("cast stream must carry join + start + end, got %d frames" % frames.size())
		return false
	var store := ReplicaStore.new()
	for i in frames.size():
		var decoded := WireCodec.decode(((frames[i] as Dictionary)["hex"] as String).hex_decode())
		if decoded.get("ok") != true or int(decoded.get("version", 0)) != WireCodec.VERSION:
			_fail("cast frame %d refused or not v%d: %s" % [i, WireCodec.VERSION, str(decoded)])
			return false
		var applied := store.apply(decoded)
		if applied.get("ok") != true:
			_fail("cast frame %d refused by store: %s" % [i, str(applied)])
			return false
		if i == 1:
			if store.cast_count() != 1:
				_fail("cast start left %d active casts, want 1" % store.cast_count())
				return false
			var cast := store.cast(100)
			if int(cast.get("kind", -1)) != WireCodec.SHAPE_CIRCLE or int(cast.get("outer", -1)) != 1_500:
				_fail("decoded cast geometry diverged: %s" % str(cast))
				return false
			if not is_equal_approx(store.cast_progress(100, 1), 1.0 / 3.0) or not is_equal_approx(store.cast_progress(100, 3), 1.0):
				_fail("cast progress is not derived from authoritative start/resolve ticks")
				return false
	if store.tick() != int((stream["end_state"] as Dictionary)["tick"] as float) or store.cast_count() != 0:
		_fail("cast end did not converge to fixture end_state (tick %d casts %d)" % [store.tick(), store.cast_count()])
		return false
	return true


func _check_malformed_casts(root: Dictionary) -> bool:
	var start_hex: String = (((root["cast_stream"] as Dictionary)["frames"] as Array)[1] as Dictionary)["hex"]
	var valid := start_hex.hex_decode()
	const DELTA_HEADER_SIZE := 2 + 1 + 8
	const EMPTY_ENTITY_LIST_SIZE := 4
	const EMPTY_ID_LIST_SIZE := 4
	const STARTED_COUNT_OFFSET := DELTA_HEADER_SIZE + 2 * EMPTY_ENTITY_LIST_SIZE + EMPTY_ID_LIST_SIZE
	const CAST_OFFSET := STARTED_COUNT_OFFSET + 4
	const CASTER_SIZE := 8
	const KIND_OFFSET := CAST_OFFSET + CASTER_SIZE
	const ORIGIN_SIZE := 3 * 8
	const FACING_SIZE := 3 * 8
	const OUTER_OFFSET := KIND_OFFSET + 1 + ORIGIN_SIZE + FACING_SIZE
	const INNER_OFFSET := OUTER_OFFSET + 8
	const CAST_END_OFFSET := CAST_OFFSET + WireCodec.ACTIVE_CAST_SIZE
	const RESOLVE_TICK_OFFSET := CAST_END_OFFSET - 8
	const START_TICK_OFFSET := RESOLVE_TICK_OFFSET - 8

	var bad_shape: PackedByteArray = valid.duplicate()
	bad_shape.encode_u8(KIND_OFFSET, 99)
	if not _expect_decode_error(bad_shape, WireCodec.ERR_CAST_SHAPE, "unknown cast kind"):
		return false

	var bad_count: PackedByteArray = valid.duplicate()
	bad_count.encode_u32(STARTED_COUNT_OFFSET, WireCodec.MAX_CASTS + 1)
	if not _expect_decode_error(bad_count, WireCodec.ERR_COUNT, "hostile started-cast count"):
		return false

	var bad_extent: PackedByteArray = valid.duplicate()
	bad_extent.encode_s64(OUTER_OFFSET, -9223372036854775808)
	if not _expect_decode_error(bad_extent, WireCodec.ERR_CAST_SHAPE, "minimum-int cast extent"):
		return false

	var inverted_ring: PackedByteArray = valid.duplicate()
	inverted_ring.encode_u8(KIND_OFFSET, WireCodec.SHAPE_RING)
	inverted_ring.encode_s64(INNER_OFFSET, inverted_ring.decode_s64(OUTER_OFFSET) + 1)
	if not _expect_decode_error(inverted_ring, WireCodec.ERR_CAST_SHAPE, "positive ring with inner radius beyond outer"):
		return false

	var bad_timing: PackedByteArray = valid.duplicate()
	bad_timing.encode_u64(RESOLVE_TICK_OFFSET, bad_timing.decode_u64(START_TICK_OFFSET))
	if not _expect_decode_error(bad_timing, WireCodec.ERR_CAST_TIMING, "zero-duration cast"):
		return false
	return true


func _check_store_atomicity_and_replacement() -> bool:
	var hostile_store := ReplicaStore.new()
	var hostile := hostile_store.apply(_snapshot(1, [_entity(2)], [_cast(2, 0, 0, 500)]))
	if hostile.get("ok") != true or not is_equal_approx(hostile_store.cast_progress(2, 1), 1.0):
		_fail("cast_progress did not contain a zero-duration direct-input cast: %s" % str(hostile))
		return false

	var store := ReplicaStore.new()
	var base := _snapshot(1, [_entity(2)], [_cast(2, 0, 5, 500)])
	if store.apply(base).get("ok") != true:
		_fail("store control base refused")
		return false

	var invalid := _delta(2, [_entity(3)], [], [], [_cast(99, 1, 6, 700)], [])
	var refused := store.apply(invalid)
	if refused.get("error") != ReplicaStore.ERR_CAST_CASTER or not store.entity(3).is_empty() or store.cast_count() != 1:
		_fail("invalid cast caster was not refused atomically: %s" % str(refused))
		return false

	var replaced := store.apply(_delta(2, [], [], [], [_cast(2, 1, 6, 900)], [2]))
	if replaced.get("ok") != true or int(store.cast(2).get("outer", 0)) != 900:
		_fail("same-frame cast replacement failed: %s" % str(replaced))
		return false

	var copy := store.cast(2)
	copy["outer"] = 123
	if int(store.cast(2)["outer"]) != 900:
		_fail("cast() returned a live reference")
		return false
	return true


func _snapshot(tick: int, entities: Array, casts: Array) -> Dictionary:
	return {"ok": true, "kind": WireCodec.KIND_SNAPSHOT, "snapshot": {"tick": tick, "observer": 1, "entities": entities, "casts": casts}}


func _delta(tick: int, entered: Array, moved: Array, left: Array, started: Array, ended: Array) -> Dictionary:
	return {"ok": true, "kind": WireCodec.KIND_SNAPSHOT_DELTA, "delta": {"tick": tick, "entered": entered, "moved": moved, "left": left, "started_casts": started, "ended_casts": ended}}


func _entity(id: int) -> Dictionary:
	return {"id": id, "x": 0, "y": 0, "z": 0, "radius": 300}


func _cast(caster: int, start_tick: int, resolve_tick: int, outer: int) -> Dictionary:
	return {
		"caster": caster, "kind": WireCodec.SHAPE_CIRCLE,
		"origin_x": 0, "origin_y": 0, "origin_z": 0,
		"facing_x": 0, "facing_y": 0, "facing_z": 0,
		"outer": outer, "inner": 0, "half_width": 0, "cos_half": 0,
		"start_tick": start_tick, "resolve_tick": resolve_tick,
	}


func _expect_decode_error(bytes: PackedByteArray, want: String, label: String) -> bool:
	var decoded := WireCodec.decode(bytes)
	if decoded.get("ok") == true or decoded.get("error") != want:
		_fail("%s decoded as %s, want %s" % [label, str(decoded), want])
		return false
	return true


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
