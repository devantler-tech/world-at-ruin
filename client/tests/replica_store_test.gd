extends Node
## Replica store vs the cross-tier stream golden (issue #198).
##
## The server side (`server/wire/crosstier_stream_test.go`) proves the shipped
## tracker + encoder emit exactly the fixture's frame sequence — join
## snapshot, per-tick deltas, mid-stream resync — and that the fixture's
## `end_state` is the server's authoritative view after that stream. This side
## proves the client half of the same contract: decoding those frames with
## `WireCodec` and folding them through `ReplicaStore` lands on exactly that
## end state. Stream semantics therefore cannot drift between tiers without
## both suites moving together.
##
## Beyond the fold, every refusal law the store enforces is proven with a
## negative control isolated to ONE law, asserting the EXACT error class (a
## control failing for the wrong reason proves nothing):
##   * input            — a failed decode result, and a bare {}
##   * kind             — an ok result with an unknown kind
##   * no_base          — a delta before any base snapshot
##   * tick             — non-advancing ticks, on BOTH frame kinds
##   * observer         — a resync snapshot for a different observer
##   * self             — the observer appearing in a snapshot and in each
##                        delta list (entered / moved / left)
##   * entered_present  — entering an id the table already holds
##   * moved_absent     — moving an id the table does not hold
##   * left_absent      — removing an id the table does not hold
##   * capacity         — a fold that would exceed WireCodec.MAX_ENTITIES
##                        (boundary proven from both sides: exactly-at-cap is
##                        accepted, one past is refused)
## Atomicity is proven by pairing a valid entered with an invalid left in ONE
## delta: the refusal must leave the table byte-identical (the entered id must
## NOT appear). Tolerances are pinned too: an empty delta advances the tick
## and nothing else; a moved entry with unchanged state is accepted.
##
## Pure logic and a res:// read only — no scene, no save, no boot — so it is
## safe to run locally and deterministic in CI.
##
## Run: godot --headless --path client res://tests/replica_store_test.tscn

const FIXTURE := "res://tests/data/wire_goldens.json"

var _failed := false


func _ready() -> void:
	var stream := _load_stream()
	if _failed:
		return
	if not _check_cross_tier_fold(stream):
		return
	if not _check_input_and_kind_laws():
		return
	if not _check_base_and_tick_laws():
		return
	if not _check_observer_and_self_laws():
		return
	if not _check_membership_laws():
		return
	if not _check_atomicity():
		return
	if not _check_tolerances():
		return
	if not _check_capacity_boundary():
		return
	if not _check_entity_returns_copies():
		return
	print("TEST PASS — replica store folds the cross-tier stream golden to the server's authoritative end state and refuses every divergence class atomically")
	get_tree().quit(0)


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _load_stream() -> Dictionary:
	var text := FileAccess.get_file_as_string(FIXTURE)
	if text.is_empty():
		_fail("fixture %s is missing or empty — the cross-tier contract has no anchor" % FIXTURE)
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if parsed is not Dictionary:
		_fail("fixture %s did not parse as a JSON object" % FIXTURE)
		return {}
	var root: Dictionary = parsed
	if root.get("stream") is not Dictionary:
		_fail("fixture has no 'stream' section — regenerate with WAR_RECORD_STREAM=1 (see server/wire/crosstier_stream_test.go)")
		return {}
	var stream: Dictionary = root["stream"]
	if stream.get("frames") is not Array or (stream["frames"] as Array).is_empty():
		_fail("fixture stream has no frames")
		return {}
	if stream.get("end_state") is not Dictionary:
		_fail("fixture stream has no end_state")
		return {}
	return stream


## Decode every fixture frame and fold it into one store; the result must be
## exactly the committed authoritative end state, and the stream must exercise
## every delta surface (else this fold under-pins the contract).
func _check_cross_tier_fold(stream: Dictionary) -> bool:
	var store := ReplicaStore.new()
	var frames: Array = stream["frames"]
	var entered_seen := 0
	var moved_seen := 0
	var left_seen := 0
	var resyncs_seen := 0
	for i in frames.size():
		var frame: Dictionary = frames[i]
		var bytes: PackedByteArray = (frame["hex"] as String).hex_decode()
		var decoded := WireCodec.decode(bytes)
		if decoded.get("ok") != true:
			_fail("fixture frame %d failed to decode: %s" % [i, str(decoded)])
			return false
		if decoded["kind"] == WireCodec.KIND_SNAPSHOT_DELTA:
			var d: Dictionary = decoded["delta"]
			entered_seen += (d["entered"] as Array).size()
			moved_seen += (d["moved"] as Array).size()
			left_seen += (d["left"] as Array).size()
		elif i > 0:
			resyncs_seen += 1
		var applied := store.apply(decoded)
		if applied.get("ok") != true:
			_fail("fixture frame %d refused by the store: %s — the server-emitted stream must always fold" % [i, str(applied)])
			return false
	if entered_seen == 0 or moved_seen == 0 or left_seen == 0 or resyncs_seen == 0:
		_fail("fixture stream under-pins the contract (entered=%d moved=%d left=%d resyncs=%d) — every surface must appear" % [entered_seen, moved_seen, left_seen, resyncs_seen])
		return false

	var end_state: Dictionary = stream["end_state"]
	var want_tick := int(end_state["tick"] as float)
	var want_observer := int(end_state["observer"] as float)
	if store.tick() != want_tick:
		_fail("folded tick = %d, fixture end_state says %d" % [store.tick(), want_tick])
		return false
	if store.observer() != want_observer:
		_fail("folded observer = %d, fixture end_state says %d" % [store.observer(), want_observer])
		return false
	var want_entities: Array = end_state["entities"]
	if store.count() != want_entities.size():
		_fail("folded table holds %d entities, fixture end_state says %d (ids: %s)" % [store.count(), want_entities.size(), str(store.ids())])
		return false
	for e_var: Variant in want_entities:
		var want: Dictionary = e_var
		var id := int(want["id"] as float)
		var got := store.entity(id)
		if got.is_empty():
			_fail("fixture end_state entity %d is missing from the folded table" % id)
			return false
		for field: String in ["x", "y", "z", "radius"]:
			if int(got[field]) != int(want[field] as float):
				_fail("entity %d field %s = %d, fixture end_state says %d" % [id, field, int(got[field]), int(want[field] as float)])
				return false
	return true


## Hand-crafted decode results in exactly the decoder's output shape — the
## store's input contract. The fold above proves real decoder output takes the
## same path; these isolate one law each.
func _snapshot_result(tick: int, observer: int, entities: Array) -> Dictionary:
	return {"ok": true, "kind": WireCodec.KIND_SNAPSHOT, "snapshot": {"tick": tick, "observer": observer, "entities": entities}}


func _delta_result(tick: int, entered: Array, moved: Array, left: Array) -> Dictionary:
	return {"ok": true, "kind": WireCodec.KIND_SNAPSHOT_DELTA, "delta": {"tick": tick, "entered": entered, "moved": moved, "left": left}}


func _entity(id: int, x: int, y: int, z: int, radius: int) -> Dictionary:
	return {"id": id, "x": x, "y": y, "z": z, "radius": radius}


## A store with a known base: observer 1 at tick 10, entities 2 and 3.
func _based_store() -> ReplicaStore:
	var store := ReplicaStore.new()
	var applied := store.apply(_snapshot_result(10, 1, [_entity(2, 100, 0, 0, 300), _entity(3, 200, 0, 0, 400)]))
	if applied.get("ok") != true:
		_fail("base snapshot refused: %s — every later control would fail for the wrong reason" % str(applied))
	return store


func _expect_refusal(store: ReplicaStore, result: Dictionary, want_error: String, label: String) -> bool:
	var tick_before := store.tick()
	var count_before := store.count()
	var applied := store.apply(result)
	if applied.get("ok") == true:
		_fail("%s was accepted — must refuse as %s" % [label, want_error])
		return false
	if applied.get("error") != want_error:
		_fail("%s refused as %s, want %s (a control failing for the wrong reason proves nothing): %s" % [label, str(applied.get("error")), want_error, str(applied.get("detail"))])
		return false
	if store.tick() != tick_before or store.count() != count_before:
		_fail("%s mutated the table it refused (tick %d->%d, count %d->%d)" % [label, tick_before, store.tick(), count_before, store.count()])
		return false
	return true


func _check_input_and_kind_laws() -> bool:
	var store := _based_store()
	if _failed:
		return false
	if not _expect_refusal(store, {"ok": false, "error": WireCodec.ERR_TRUNCATED, "detail": "x"}, ReplicaStore.ERR_INPUT, "a failed decode result"):
		return false
	if not _expect_refusal(store, {}, ReplicaStore.ERR_INPUT, "an empty dictionary"):
		return false
	if not _expect_refusal(store, {"ok": true, "kind": 3}, ReplicaStore.ERR_KIND, "an ok result with unknown kind 3"):
		return false
	return true


func _check_base_and_tick_laws() -> bool:
	var empty := ReplicaStore.new()
	if not _expect_refusal(empty, _delta_result(1, [], [_entity(2, 1, 0, 0, 300)], []), ReplicaStore.ERR_NO_BASE, "a delta before any snapshot"):
		return false
	if empty.has_base():
		_fail("a refused first delta left has_base() true")
		return false

	var store := _based_store()
	if _failed:
		return false
	if not _expect_refusal(store, _delta_result(10, [], [_entity(2, 101, 0, 0, 300)], []), ReplicaStore.ERR_TICK, "a delta at the base tick"):
		return false
	if not _expect_refusal(store, _delta_result(9, [], [_entity(2, 101, 0, 0, 300)], []), ReplicaStore.ERR_TICK, "a delta behind the base tick"):
		return false
	if not _expect_refusal(store, _snapshot_result(10, 1, []), ReplicaStore.ERR_TICK, "a resync snapshot at the current tick"):
		return false
	return true


func _check_observer_and_self_laws() -> bool:
	var store := _based_store()
	if _failed:
		return false
	if not _expect_refusal(store, _snapshot_result(11, 2, []), ReplicaStore.ERR_OBSERVER, "a resync snapshot for another observer"):
		return false
	if not _expect_refusal(store, _snapshot_result(11, 1, [_entity(1, 0, 0, 0, 400)]), ReplicaStore.ERR_SELF, "a snapshot listing the observer"):
		return false
	if not _expect_refusal(store, _delta_result(11, [_entity(1, 0, 0, 0, 400)], [], []), ReplicaStore.ERR_SELF, "a delta entering the observer"):
		return false
	if not _expect_refusal(store, _delta_result(11, [], [_entity(1, 0, 0, 0, 400)], []), ReplicaStore.ERR_SELF, "a delta moving the observer"):
		return false
	if not _expect_refusal(store, _delta_result(11, [], [], [1]), ReplicaStore.ERR_SELF, "a delta removing the observer"):
		return false
	# A FIRST snapshot may carry any observer — only continuity is law.
	var fresh := ReplicaStore.new()
	var applied := fresh.apply(_snapshot_result(5, 7, []))
	if applied.get("ok") != true or fresh.observer() != 7:
		_fail("a first snapshot for observer 7 was not accepted as the base: %s" % str(applied))
		return false
	# A resync REPLACES the table wholesale: an id the new snapshot lacks must
	# vanish (merging would leave a ghost entity the server no longer vouches
	# for — the fixture's resync cannot pin this, its table happens to match).
	var store2 := _based_store()
	if _failed:
		return false
	applied = store2.apply(_snapshot_result(11, 1, [_entity(2, 100, 0, 0, 300)]))
	if applied.get("ok") != true:
		_fail("resync snapshot refused: %s" % str(applied))
		return false
	if store2.count() != 1 or not store2.entity(3).is_empty():
		_fail("WHOLESALE REPLACE BROKEN — resync left ghost entity 3 in the table (count %d)" % store2.count())
		return false
	return true


func _check_membership_laws() -> bool:
	var store := _based_store()
	if _failed:
		return false
	if not _expect_refusal(store, _delta_result(11, [_entity(2, 5, 0, 0, 300)], [], []), ReplicaStore.ERR_ENTERED_PRESENT, "entering an already-replicated id"):
		return false
	if not _expect_refusal(store, _delta_result(11, [], [_entity(9, 5, 0, 0, 300)], []), ReplicaStore.ERR_MOVED_ABSENT, "moving an unknown id"):
		return false
	if not _expect_refusal(store, _delta_result(11, [], [], [9]), ReplicaStore.ERR_LEFT_ABSENT, "removing an unknown id"):
		return false
	return true


## One delta carrying a valid entered AND an invalid left: the refusal must
## leave the table untouched — the entered id must not have been committed.
func _check_atomicity() -> bool:
	var store := _based_store()
	if _failed:
		return false
	var applied := store.apply(_delta_result(11, [_entity(5, 1, 2, 3, 100)], [], [9]))
	if applied.get("ok") == true or applied.get("error") != ReplicaStore.ERR_LEFT_ABSENT:
		_fail("mixed valid/invalid delta must refuse as left_absent, got: %s" % str(applied))
		return false
	if not store.entity(5).is_empty():
		_fail("ATOMICITY BROKEN — the refused delta's entered id 5 reached the table")
		return false
	if store.tick() != 10 or store.count() != 2:
		_fail("the refused delta moved the store (tick %d, count %d)" % [store.tick(), store.count()])
		return false
	return true


func _check_tolerances() -> bool:
	var store := _based_store()
	if _failed:
		return false
	# An empty delta advances the tick and nothing else (zonesock skips them
	# as bandwidth, not contract — one that arrives is harmless).
	var applied := store.apply(_delta_result(11, [], [], []))
	if applied.get("ok") != true or store.tick() != 11 or store.count() != 2:
		_fail("an empty delta must advance the tick and nothing else: %s (tick %d count %d)" % [str(applied), store.tick(), store.count()])
		return false
	# A moved entry with unchanged state is accepted (the tracker's
	# change-detection is an optimisation, not a promise).
	applied = store.apply(_delta_result(12, [], [_entity(2, 100, 0, 0, 300)], []))
	if applied.get("ok") != true or store.entity(2)["x"] != 100:
		_fail("a moved entry with unchanged state must be accepted: %s" % str(applied))
		return false
	return true


## The accumulation cap, boundary from both sides: a table at exactly
## MAX_ENTITIES is legal (the server can still snapshot it — its per-message
## cap is inclusive), one past is divergence.
func _check_capacity_boundary() -> bool:
	var at_cap: Array = []
	at_cap.resize(WireCodec.MAX_ENTITIES)
	for i in WireCodec.MAX_ENTITIES:
		at_cap[i] = _entity(i + 2, i, 0, 0, 100)
	var store := ReplicaStore.new()
	var applied := store.apply(_snapshot_result(1, 1, at_cap))
	if applied.get("ok") != true or store.count() != WireCodec.MAX_ENTITIES:
		_fail("a snapshot at exactly MAX_ENTITIES must be accepted (got %s, count %d)" % [str(applied), store.count()])
		return false
	var overflow_id := WireCodec.MAX_ENTITIES + 2
	if not _expect_refusal(store, _delta_result(2, [_entity(overflow_id, 0, 0, 0, 100)], [], []), ReplicaStore.ERR_CAPACITY, "a fold one past MAX_ENTITIES"):
		return false
	# With one id leaving, the same entered fits — the cap is on the FOLDED
	# size, not the entered count.
	applied = store.apply(_delta_result(2, [_entity(overflow_id, 0, 0, 0, 100)], [], [2]))
	if applied.get("ok") != true or store.count() != WireCodec.MAX_ENTITIES:
		_fail("an at-cap fold with matching leave must be accepted: %s (count %d)" % [str(applied), store.count()])
		return false
	return true


func _check_entity_returns_copies() -> bool:
	var store := _based_store()
	if _failed:
		return false
	var copy := store.entity(2)
	copy["x"] = 999_999
	if store.entity(2)["x"] != 100:
		_fail("entity() returned a live reference — mutating it reached the table")
		return false
	return true
