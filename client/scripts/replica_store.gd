class_name ReplicaStore

## The client's replicated world state (issue #198) — the table the zone
## socket's frame stream folds into, and the one surface every later
## client-networking child (socket consumption, remote-entity rendering,
## interpolation) reads. Sits directly downstream of `WireCodec.decode`: a
## decoded snapshot resyncs the table wholesale, a decoded delta applies
## entered/moved/left — and nothing else ever mutates it.
##
## Contract, mirroring the server's replication semantics
## (`server/sim/snapshot.go` tracker + `server/zonesock` lifecycle) WHOLE:
##   * A snapshot is the join/resync payload: it REPLACES the table, pins the
##     observer, and sets the tick. The first applied frame must be one — a
##     delta has nothing to be relative to before a base snapshot exists
##     (zonesock sends the join snapshot before any delta, and re-snapshots
##     on overflow resync).
##   * A delta is relative to exactly the previous applied frame: `entered`
##     ids must be absent, `moved`/`left` ids must be present. The tracker
##     guarantees this over an ordered reliable transport, so a violation is
##     state divergence — refused, never repaired (an entry silently invented
##     or dropped here would desync every later frame).
##   * Ticks strictly ascend across ALL applied frames. The server emits at
##     most one frame per tick per observer and a resync snapshot is always
##     taken at a tick later than any frame that reached the peer, so a
##     stale, duplicated or reordered frame is a transport bug — refused.
##   * The observer never appears in any list (Interest excludes self), and a
##     resync snapshot carries the SAME observer the join did.
##   * Application is ATOMIC: the whole frame is validated against the table
##     before any mutation, so a refused frame leaves the table byte-for-byte
##     untouched — a half-applied delta is a desync with no error to show
##     for it.
##   * The folded table stays within `WireCodec.MAX_ENTITIES`: the per-frame
##     list caps bound one frame, not the accumulation, and a table the
##     server could never re-snapshot (its encoder enforces the same cap per
##     message) is divergence by construction.
##
## Deliberately tolerated, matching server behaviour rather than tightening
## past it: an EMPTY delta (zonesock skips them as a bandwidth choice, not a
## contract; one that arrives merely advances the tick) and a `moved` entry
## whose state equals the stored one (the tracker's change-detection is an
## optimisation, not a promise this side may rely on).
##
## Pure logic — no I/O, no scene tree, no signals — so the contract is
## unit-testable exactly like `WireCodec`: `apply` takes the decoder's result
## Dictionary and returns `{"ok": true, "kind": …, "tick": …}` or
## `{"ok": false, "error": ERR_*, "detail": String}`, and the fold of the
## shared cross-tier stream fixture must land on the fixture's committed end
## state (see `server/wire/crosstier_stream_test.go`, the other half of that
## contract).

## Error classes. String constants like `WireCodec.ERR_*`, so a consumer can
## classify a refusal without string-matching details.
const ERR_INPUT := "input"        # not an ok decode result
const ERR_KIND := "kind"          # ok result with an unknown kind
const ERR_NO_BASE := "no_base"    # delta before any base snapshot
const ERR_TICK := "tick"          # tick did not strictly advance
const ERR_OBSERVER := "observer"  # resync snapshot for a different observer
const ERR_SELF := "self"          # a list names the observer itself
const ERR_ENTERED_PRESENT := "entered_present"  # entered id already in table
const ERR_MOVED_ABSENT := "moved_absent"        # moved id not in table
const ERR_LEFT_ABSENT := "left_absent"          # left id not in table
const ERR_CAPACITY := "capacity"  # fold would exceed WireCodec.MAX_ENTITIES

var _has_base := false
var _observer: int = 0
var _tick: int = 0
var _entities: Dictionary = {}  # id -> {"x": int, "y": int, "z": int, "radius": int}


## Fold one decoded frame into the table. `result` is exactly what
## `WireCodec.decode` returned; a failed decode is refused here too, so a
## caller cannot accidentally launder a bad frame into state.
func apply(result: Dictionary) -> Dictionary:
	if result.get("ok") != true:
		return _refuse(ERR_INPUT, "not an ok decode result")
	var kind: Variant = result.get("kind")
	if kind == WireCodec.KIND_SNAPSHOT:
		return _apply_snapshot(result["snapshot"])
	if kind == WireCodec.KIND_SNAPSHOT_DELTA:
		return _apply_delta(result["delta"])
	return _refuse(ERR_KIND, "unknown kind %s" % str(kind))


## Whether a base snapshot has been applied (before it, the table is empty
## and only a snapshot is applicable).
func has_base() -> bool:
	return _has_base


## The observer this table replicates for (0 before the base snapshot).
func observer() -> int:
	return _observer


## The tick of the newest applied frame (0 before the base snapshot).
func tick() -> int:
	return _tick


## Number of replicated entities currently in the table.
func count() -> int:
	return _entities.size()


## The replicated state of one entity, or {} if it is not in the table. The
## returned Dictionary is a copy — mutating it never touches the table.
func entity(id: int) -> Dictionary:
	var e: Variant = _entities.get(id)
	if e == null:
		return {}
	return (e as Dictionary).duplicate()


## Ascending ids of every replicated entity.
func ids() -> Array[int]:
	var out: Array[int] = []
	for id: Variant in _entities.keys():
		out.append(id as int)
	out.sort()
	return out


func _apply_snapshot(snapshot: Dictionary) -> Dictionary:
	var s_tick: int = snapshot["tick"]
	var s_observer: int = snapshot["observer"]
	if _has_base and s_observer != _observer:
		return _refuse(ERR_OBSERVER, "resync for observer %d, table replicates %d" % [s_observer, _observer])
	if _has_base and s_tick <= _tick:
		return _refuse(ERR_TICK, "snapshot tick %d does not advance past %d" % [s_tick, _tick])
	var entities: Array = snapshot["entities"]
	var next: Dictionary = {}
	for e_var: Variant in entities:
		var e: Dictionary = e_var
		var id: int = e["id"]
		if id == s_observer:
			return _refuse(ERR_SELF, "snapshot lists the observer %d" % id)
		next[id] = {"x": e["x"], "y": e["y"], "z": e["z"], "radius": e["radius"]}
	# Commit — wholesale replacement is the resync semantics.
	_entities = next
	_observer = s_observer
	_tick = s_tick
	_has_base = true
	return {"ok": true, "kind": WireCodec.KIND_SNAPSHOT, "tick": _tick}


func _apply_delta(delta: Dictionary) -> Dictionary:
	if not _has_base:
		return _refuse(ERR_NO_BASE, "delta before any base snapshot")
	var d_tick: int = delta["tick"]
	if d_tick <= _tick:
		return _refuse(ERR_TICK, "delta tick %d does not advance past %d" % [d_tick, _tick])
	var entered: Array = delta["entered"]
	var moved: Array = delta["moved"]
	var left: Array = delta["left"]

	# Validate the WHOLE frame against the table before touching it — a
	# refusal after a partial commit would be a silent desync.
	for e_var: Variant in entered:
		var e: Dictionary = e_var
		var id: int = e["id"]
		if id == _observer:
			return _refuse(ERR_SELF, "entered lists the observer %d" % id)
		if _entities.has(id):
			return _refuse(ERR_ENTERED_PRESENT, "entered id %d is already replicated" % id)
	for e_var: Variant in moved:
		var e: Dictionary = e_var
		var id: int = e["id"]
		if id == _observer:
			return _refuse(ERR_SELF, "moved lists the observer %d" % id)
		if not _entities.has(id):
			return _refuse(ERR_MOVED_ABSENT, "moved id %d is not replicated" % id)
	for id_var: Variant in left:
		var id: int = id_var
		if id == _observer:
			return _refuse(ERR_SELF, "left lists the observer %d" % id)
		if not _entities.has(id):
			return _refuse(ERR_LEFT_ABSENT, "left id %d is not replicated" % id)
	# entered/left are disjoint (the codec refuses overlap), so the folded
	# size is exact, not an estimate.
	var folded_size: int = _entities.size() + entered.size() - left.size()
	if folded_size > WireCodec.MAX_ENTITIES:
		return _refuse(ERR_CAPACITY, "fold would hold %d entities, cap is %d" % [folded_size, WireCodec.MAX_ENTITIES])

	# Commit.
	for e_var: Variant in entered:
		var e: Dictionary = e_var
		_entities[e["id"] as int] = {"x": e["x"], "y": e["y"], "z": e["z"], "radius": e["radius"]}
	for e_var: Variant in moved:
		var e: Dictionary = e_var
		_entities[e["id"] as int] = {"x": e["x"], "y": e["y"], "z": e["z"], "radius": e["radius"]}
	for id_var: Variant in left:
		_entities.erase(id_var as int)
	_tick = d_tick
	return {"ok": true, "kind": WireCodec.KIND_SNAPSHOT_DELTA, "tick": _tick}


func _refuse(error: String, detail: String) -> Dictionary:
	return {"ok": false, "error": error, "detail": detail}
