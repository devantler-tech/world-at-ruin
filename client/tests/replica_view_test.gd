extends Node
## Replicated entities reach the SCENE TREE (issue #248).
##
## `replica_store_test.gd` proves the table folds the cross-tier stream
## correctly. This proves the other half of #248: that the folded table is
## actually drawn — appearing on enter, tracking on move, removed on leave —
## because a store that is provably right and a scene that is provably empty
## is exactly the state this issue exists to end.
##
## Every assertion reads the REAL scene tree (`get_child_count()`, the node's
## own `position`), never only the view's bookkeeping: a count that agrees
## with itself while nothing is parented would pass a view that draws nothing,
## which is the precise defect under test.
##
## Laws proven, each isolated to one:
##   * enter          — a replicated entity gets a marker, at its position
##   * units          — millimetres convert to metres exactly, Y stays up
##   * move           — a moved entity's marker follows it
##   * leave          — a departed entity's marker leaves the tree in the SAME
##                      frame (a deferred free would keep drawing it)
##   * identity       — an unchanged table reuses marker nodes rather than
##                      rebuilding them every frame
##   * resize         — a radius that changes while replicated resizes the
##                      capsule
##   * capsule fit    — a radius wider than half the nominal height grows the
##                      height, so the mesh keeps the replicated radius
##                      instead of being silently clamped by the engine
##   * empty          — a store with no base snapshot draws nothing
##   * cleared        — a null store (no zone) removes everything
##   * render boundary — a table exactly at the independent marker budget draws
##                       and survives an over-cap update without rebuilding,
##                       then resumes ordinary reconciliation
##   * render cap     — a first oversized but protocol-valid table allocates no
##                      markers
##
## Pure scene-tree work — no socket, no save, no GPU read-back — so it is
## deterministic headless and safe to run locally.
##
## Run: godot --headless --path client res://tests/replica_view_test.tscn

var _failed := false


func _ready() -> void:
	if not _check_enter_and_units():
		return
	if not _check_move_tracks():
		return
	if not _check_leave_removes_immediately():
		return
	if not _check_unchanged_table_reuses_nodes():
		return
	if not _check_radius_resizes():
		return
	if not _check_capsule_fit():
		return
	if not _check_empty_store_draws_nothing():
		return
	if not _check_null_store_clears():
		return
	if not _check_render_cap_accepts_boundary():
		return
	if not _check_render_cap_skips_first_oversized_table():
		return
	if not _check_placement_is_world_absolute():
		return
	if not _check_capture_marker_contract():
		return
	print("TEST PASS — replicated entities appear, track, resize and leave the scene tree exactly as the store reports them")
	get_tree().quit(0)


## The capture marker is a MACHINE CONTRACT, not a log pleasantry (#325).
##
## CI's frame-capture job parses this line to record, in the evidence artifact,
## whether the published frames contain any replicated entity. If the token or
## the verdict field drifts, the job can no longer tell — and a green capture
## over a world that never populated its replica table goes back to reading as
## evidence for a replication change. Pinned here because the workflow's grep
## cannot defend itself.
func _check_capture_marker_contract() -> bool:
	# An empty table is the only `off` state, so the count alone decides the
	# verdict — including the boundary at one entity, which is what stops a
	# population of exactly one from reading as no population at all.
	for case: Array in [["on", 3], ["on", 1], ["off", 0]]:
		var want: String = case[0]
		var line := ReplicaView.marker(case[1] as int)
		if not line.begins_with(ReplicaView.CAPTURE_MARKER + " "):
			_fail("marker() must start with CAPTURE_MARKER and a space — CI greps for it")
			return false
		# The second whitespace-separated field is what CI reads as the verdict.
		if line.split(" ")[1] != want:
			_fail("marker(%d)'s second field must be exactly '%s' — CI parses it" % [case[1] as int, want])
			return false
		# One line, or the job's exactly-one-distinct-verdict parse sees a
		# second verdict where the prose was meant to be.
		if line.contains("\n"):
			_fail("marker() must be a single line — CI matches it anchored at the start of one")
			return false
	return true


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


## A base snapshot puts two entities on screen at their replicated positions,
## converted from millimetres. Y is deliberately non-zero on one of them: both
## tiers agree Y is up (`server/sim/vec.go`), so an axis swap here would be
## invisible in a flat fixture.
func _check_enter_and_units() -> bool:
	var view := _mounted_view()
	var store := ReplicaStore.new()
	if not _apply(store, _snapshot_result(10, 1, [
		_entity(2, 1500, 0, -2500, 300),
		_entity(3, -750, 1250, 0, 400),
	])):
		return false
	view.sync(store)

	if view.get_child_count() != 2:
		_fail("two replicated entities must put two markers in the tree, found %d" % view.get_child_count())
		return false
	var m2 := view.marker_for(2)
	if m2 == null:
		_fail("entity 2 is replicated but has no marker")
		return false
	if m2.get_parent() != view:
		_fail("marker for entity 2 is not parented under the view")
		return false
	if not _positions_match(m2.position, Vector3(1.5, 0.0, -2.5)):
		_fail("entity 2 at (1500, 0, -2500) mm must draw at (1.5, 0, -2.5) m, got %s" % str(m2.position))
		return false
	var m3 := view.marker_for(3)
	if m3 == null:
		_fail("entity 3 is replicated but has no marker")
		return false
	if not _positions_match(m3.position, Vector3(-0.75, 1.25, 0.0)):
		_fail("entity 3 at (-750, 1250, 0) mm must draw at (-0.75, 1.25, 0) m, got %s" % str(m3.position))
		return false
	var mesh: CapsuleMesh = m2.mesh
	if mesh == null:
		_fail("a marker must carry a capsule mesh, entity 2 has none")
		return false
	if not is_equal_approx(mesh.radius, 0.3):
		_fail("a 300 mm replicated radius must draw at 0.3 m, got %f" % mesh.radius)
		return false
	# Markers are identical in colour, so they share one material rather than
	# allocating an equivalent resource each. Pinned so the sharing is not
	# quietly undone — and asserted non-null, since a marker with no material
	# renders as untextured white rather than the intended stand-in.
	var mesh3: CapsuleMesh = m3.mesh
	if mesh.material == null:
		_fail("a marker must carry a material")
		return false
	if mesh.material != mesh3.material:
		_fail("markers must share one material instance, got two distinct ones")
		return false
	view.free()
	return true


## A moved entity's marker follows it rather than staying where it entered.
func _check_move_tracks() -> bool:
	var view := _mounted_view()
	var store := _based_store()
	if _failed:
		return false
	view.sync(store)
	var before := view.marker_for(2).position
	if not _apply(store, _delta_result(11, [], [_entity(2, 9000, 0, 4000, 300)], [])):
		return false
	view.sync(store)

	var marker := view.marker_for(2)
	if marker == null:
		_fail("a moved entity must keep its marker")
		return false
	if not _positions_match(marker.position, Vector3(9.0, 0.0, 4.0)):
		_fail("a marker must follow its entity to (9, 0, 4) m, got %s (was %s)" % [str(marker.position), str(before)])
		return false
	if view.get_child_count() != 2:
		_fail("a move must not change how many markers are drawn, found %d" % view.get_child_count())
		return false
	view.free()
	return true


## A departure leaves the tree in the SAME frame. `queue_free` alone defers to
## the end of the frame, so a caller — and a player — would keep seeing a
## marker for somebody who has already gone.
func _check_leave_removes_immediately() -> bool:
	var view := _mounted_view()
	var store := _based_store()
	if _failed:
		return false
	view.sync(store)
	if not _apply(store, _delta_result(11, [], [], [2])):
		return false
	view.sync(store)

	if view.marker_for(2) != null:
		_fail("a departed entity must have no marker")
		return false
	if view.get_child_count() != 1:
		_fail("a departure must remove the node from the tree in the same frame, tree still holds %d" % view.get_child_count())
		return false
	if view.marker_for(3) == null:
		_fail("a departure must not disturb the entities that stayed")
		return false
	view.free()
	return true


## Syncing an unchanged table must reuse the marker nodes. Rebuilding them
## every frame would be invisible to a count-based assertion while discarding
## and recreating a node per entity per frame.
func _check_unchanged_table_reuses_nodes() -> bool:
	var view := _mounted_view()
	var store := _based_store()
	if _failed:
		return false
	view.sync(store)
	var first := view.marker_for(2)
	var first_id := first.get_instance_id()
	view.sync(store)

	var second := view.marker_for(2)
	if second == null:
		_fail("re-syncing an unchanged table dropped a marker")
		return false
	if second.get_instance_id() != first_id:
		_fail("re-syncing an unchanged table rebuilt the marker instead of reusing it")
		return false
	if view.get_child_count() != 2:
		_fail("re-syncing an unchanged table changed the tree to %d markers" % view.get_child_count())
		return false
	view.free()
	return true


## The wire carries a radius on every moved entry, so an entity that changes
## size while replicated must not keep the size it entered with.
func _check_radius_resizes() -> bool:
	var view := _mounted_view()
	var store := _based_store()
	if _failed:
		return false
	view.sync(store)
	if not _apply(store, _delta_result(11, [], [_entity(2, 100, 0, 0, 550)], [])):
		return false
	view.sync(store)

	var mesh: CapsuleMesh = view.marker_for(2).mesh
	if not is_equal_approx(mesh.radius, 0.55):
		_fail("a radius that changed to 550 mm must resize the capsule to 0.55 m, got %f" % mesh.radius)
		return false
	view.free()
	return true


## Godot clamps a capsule height below 2·radius, which would silently discard
## the replicated radius. The view grows the height instead. The control is
## a radius WIDER than half the nominal height: at the default height the
## clamp does not engage, so a fixture inside it would pass either way.
func _check_capsule_fit() -> bool:
	var view := _mounted_view()
	var store := ReplicaStore.new()
	var wide_mm := int(ReplicaView.MARKER_HEIGHT_M * ReplicaView.MM_PER_M)  # radius = full nominal height
	if not _apply(store, _snapshot_result(10, 1, [_entity(2, 0, 0, 0, wide_mm)])):
		return false
	view.sync(store)

	var mesh: CapsuleMesh = view.marker_for(2).mesh
	if not is_equal_approx(mesh.radius, ReplicaView.MARKER_HEIGHT_M):
		_fail("a %d mm radius must survive as %f m, got %f — the engine clamped it" % [wide_mm, ReplicaView.MARKER_HEIGHT_M, mesh.radius])
		return false
	if mesh.height < 2.0 * mesh.radius:
		_fail("capsule height %f is below 2·radius %f — geometrically impossible, the engine will clamp one of them" % [mesh.height, 2.0 * mesh.radius])
		return false
	view.free()
	return true


## Before any base snapshot the table is empty, so nothing is drawn. This is
## the state a client sits in between opening a socket and receiving its join
## snapshot, and the state an unreachable zone stays in forever.
func _check_empty_store_draws_nothing() -> bool:
	var view := _mounted_view()
	view.sync(ReplicaStore.new())

	if view.get_child_count() != 0:
		_fail("a store with no base snapshot must draw nothing, found %d markers" % view.get_child_count())
		return false
	view.free()
	return true


## No zone configured — the view holds nothing rather than leaving the last
## drawn table standing in the world as ghosts.
func _check_null_store_clears() -> bool:
	var view := _mounted_view()
	var store := _based_store()
	if _failed:
		return false
	view.sync(store)
	if view.get_child_count() != 2:
		_fail("fixture did not draw, so the clear below would prove nothing")
		return false
	view.sync(null)

	if view.get_child_count() != 0:
		_fail("a null store must clear the view, tree still holds %d" % view.get_child_count())
		return false
	if view.count() != 0:
		_fail("a null store must clear the view's index too, it still reports %d" % view.count())
		return false
	view.free()
	return true


## The budget is inclusive. A `>=` guard would look equivalent under every
## small fixture and the first-oversized refusal below, but would hide the final
## protocol-valid marker the renderer explicitly budgets for. Once that bounded
## population exists, a one-over-cap update must retain those exact nodes: a
## clear/rebuild cycle at the boundary is the allocation spike this cap prevents.
func _check_render_cap_accepts_boundary() -> bool:
	var view := _mounted_view()
	var store := ReplicaStore.new()
	var entities: Array = []
	for id: int in range(2, ReplicaView.MAX_VISIBLE_ENTITIES + 2):
		entities.append(_entity(id, id, 0, 0, 300))
	if not _apply(store, _snapshot_result(10, 1, entities)):
		return false
	view.sync(store)

	var tree_count := view.get_child_count()
	var index_count := view.count()
	if tree_count != ReplicaView.MAX_VISIBLE_ENTITIES or index_count != ReplicaView.MAX_VISIBLE_ENTITIES:
		_fail("a table at the %d-marker render cap must draw every marker, found %d in the tree and %d in the index" % [ReplicaView.MAX_VISIBLE_ENTITIES, tree_count, index_count])
		return false
	var marker_ids: Dictionary = {}
	for id: int in range(2, ReplicaView.MAX_VISIBLE_ENTITIES + 2):
		marker_ids[id] = view.marker_for(id).get_instance_id()

	entities.append(_entity(ReplicaView.MAX_VISIBLE_ENTITIES + 2, 0, 0, 0, 300))
	store = ReplicaStore.new()
	if not _apply(store, _snapshot_result(11, 1, entities)):
		return false
	view.sync(store)

	if view.get_child_count() != ReplicaView.MAX_VISIBLE_ENTITIES or view.count() != ReplicaView.MAX_VISIBLE_ENTITIES:
		_fail("a one-over-cap update must retain the last %d-marker population, found %d markers" % [ReplicaView.MAX_VISIBLE_ENTITIES, view.count()])
		return false
	for id: int in range(2, ReplicaView.MAX_VISIBLE_ENTITIES + 2):
		var marker := view.marker_for(id)
		if marker == null or marker.get_instance_id() != marker_ids[id]:
			_fail("a one-over-cap update rebuilt or removed marker %d" % id)
			return false

	var recovered_entities: Array = entities.slice(0, ReplicaView.MAX_VISIBLE_ENTITIES)
	recovered_entities[0] = _entity(2, 9000, 0, 0, 300)
	store = ReplicaStore.new()
	if not _apply(store, _snapshot_result(12, 1, recovered_entities)):
		return false
	view.sync(store)
	if not _positions_match(view.marker_for(2).position, Vector3(9.0, 0.0, 0.0)):
		_fail("returning within the render cap must resume position reconciliation")
		return false
	for id: int in range(2, ReplicaView.MAX_VISIBLE_ENTITIES + 2):
		var marker := view.marker_for(id)
		if marker == null or marker.get_instance_id() != marker_ids[id]:
			_fail("returning within the render cap rebuilt or removed marker %d" % id)
			return false
	view.free()
	return true


## The wire cap is a serialization bound, not permission to allocate that many
## scene nodes. Exercise one past the independent render budget (but still far
## below WireCodec.MAX_ENTITIES) before any valid population exists. The view
## must not allocate even one marker from an oversized authoritative table.
func _check_render_cap_skips_first_oversized_table() -> bool:
	var view := _mounted_view()
	var store := ReplicaStore.new()
	var entities: Array = []
	# Observer 1 is intentionally absent: the store correctly refuses snapshots
	# that list the observing player among remote replicas.
	for id: int in range(2, ReplicaView.MAX_VISIBLE_ENTITIES + 3):
		entities.append(_entity(id, id, 0, 0, 300))
	if not _apply(store, _snapshot_result(10, 1, entities)):
		return false
	view.sync(store)

	if view.get_child_count() != 0 or view.count() != 0:
		_fail("a first %d-entity table above the %d-marker render cap must allocate nothing, found %d markers" % [store.count(), ReplicaView.MAX_VISIBLE_ENTITIES, view.count()])
		return false
	view.free()
	return true


## The wire carries ABSOLUTE world coordinates, so a marker must land at that
## world point regardless of where its view sits. Placing them as a local
## offset happens to be right today (the view hangs off Main at the origin),
## which is what would keep the bug invisible — so the control gives the view
## a non-identity transform, where local and global placement disagree.
func _check_placement_is_world_absolute() -> bool:
	var view := _mounted_view()
	view.position = Vector3(10.0, 5.0, -3.0)
	var store := ReplicaStore.new()
	if not _apply(store, _snapshot_result(10, 1, [_entity(2, 1500, 0, -2500, 300)])):
		return false
	view.sync(store)

	var marker := view.marker_for(2)
	if marker == null:
		_fail("an offset view drew no marker")
		return false
	if not _positions_match(marker.global_position, Vector3(1.5, 0.0, -2.5)):
		_fail("a replicated world position must be absolute: expected global (1.5, 0, -2.5), got %s (view offset by %s)" % [str(marker.global_position), str(view.position)])
		return false
	view.free()
	return true


## A view mounted in the tree, so `get_child_count()` reflects real parenting
## rather than a detached node's bookkeeping.
func _mounted_view() -> ReplicaView:
	var view := ReplicaView.new()
	add_child(view)
	return view


func _apply(store: ReplicaStore, result: Dictionary) -> bool:
	var applied := store.apply(result)
	if applied.get("ok") != true:
		_fail("fixture frame refused by the store (%s) — the assertion under test would fail for the wrong reason" % str(applied))
		return false
	return true


## Positions are exact scalar divides of integers, so an approximate compare
## here is float hygiene, not a tolerance hiding a wrong value.
func _positions_match(got: Vector3, want: Vector3) -> bool:
	return is_equal_approx(got.x, want.x) and is_equal_approx(got.y, want.y) and is_equal_approx(got.z, want.z)


func _snapshot_result(tick: int, observer: int, entities: Array) -> Dictionary:
	return {"ok": true, "kind": WireCodec.KIND_SNAPSHOT, "snapshot": {"tick": tick, "observer": observer, "entities": entities}}


func _delta_result(tick: int, entered: Array, moved: Array, left: Array) -> Dictionary:
	return {"ok": true, "kind": WireCodec.KIND_SNAPSHOT_DELTA, "delta": {"tick": tick, "entered": entered, "moved": moved, "left": left}}


func _entity(id: int, x: int, y: int, z: int, radius: int) -> Dictionary:
	return {"id": id, "x": x, "y": y, "z": z, "radius": radius}


## A store with a known base: observer 1 at tick 10, entities 2 and 3.
func _based_store() -> ReplicaStore:
	var store := ReplicaStore.new()
	if not _apply(store, _snapshot_result(10, 1, [_entity(2, 100, 0, 0, 300), _entity(3, 200, 0, 0, 400)])):
		return null
	return store
