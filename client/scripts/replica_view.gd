class_name ReplicaView
extends Node3D

## Puts the replicated entity table on screen (issue #248, epic #4).
##
## `ZoneConnection` opens the socket and folds every frame into a
## `ReplicaStore`, but until now nothing drew the result: a player with a zone
## configured saw an ordinary single-player Reach while every other client in
## the world sat in memory, invisible. This node is that last link — it holds
## one marker per replicated entity and reconciles them against the store the
## existing poll already fills.
##
## ## Deliberately plain
##
## A marker is a flat-shaded capsule, not a character. How a remote player
## LOOKS belongs to the character work under #123; drawing anything richer
## here would fork a second, unowned appearance for the same thing. The
## capsule mirrors the server's own actor shape (`server/sim/separation.go`
## resolves vertical capsules), so the stand-in at least occupies the volume
## the simulation reserves for it.
##
## ## Units
##
## The wire speaks integer millimetres on both tiers, and both agree Y is up
## (`server/sim/vec.go`), so the mapping into Godot metres is a scalar divide
## with no axis swap. Height is NOT replicated — the wire carries a radius
## only — so markers use one nominal height, which is why it is a constant
## here rather than a value pretending to come from the server.
##
## ## Where this may be parented
##
## Under `Main`, NEVER under `WorldGen`. `world_gen_determinism_test`
## fingerprints every `Node3D` descendant of `WorldGen`, so markers there
## would move the world golden every time somebody connected; worse, a
## scriptless `Node3D` container under `WorldGen` is misread as a ruin site by
## `_ruin_sites()` / `_foliage_keep_outs()`. Both traps are recorded from
## #211. This class carries a script, but its markers do not — hence the rule
## rather than a reliance on the filter.
##
## Pure scene-tree work with no I/O, no socket and no GPU read-back, so the
## whole contract is testable headlessly (`tests/replica_view_test.tscn`).

## Millimetres per metre — the wire's unit against Godot's.
const MM_PER_M := 1000.0

## Nominal marker height in metres, caps included. The wire replicates no
## height, so this is a stand-in for the character work under #123 and not a
## replicated quantity.
const MARKER_HEIGHT_M := 1.8

## Flat stand-in colour. Deliberately readable against the Reach's ash palette
## without reading as authored art.
const MARKER_COLOR := Color(0.62, 0.78, 0.9)

## id -> MeshInstance3D. The view's own index, never derived from child names:
## duplicate `add_child` names uniquify by native CLASS (`@Node3D@N`), so a
## name-based lookup silently finds one marker out of many (recorded on #282).
var _markers: Dictionary = {}


## Reconcile the drawn markers against `store`, which is the table
## `ZoneConnection` folds frames into. Safe and cheap to call every frame:
## an unchanged table moves existing markers and creates nothing.
##
## A null store — no zone configured — clears the view rather than leaving
## whatever was last drawn on screen, so a dropped link cannot leave ghosts
## standing in the world.
func sync(store: ReplicaStore) -> void:
	if store == null:
		_clear()
		return
	var live: Dictionary = {}
	for id: int in store.ids():
		var e: Dictionary = store.entity(id)
		if e.is_empty():
			continue
		live[id] = true
		var radius_m: float = float(e["radius"]) / MM_PER_M
		var marker: MeshInstance3D = _markers.get(id)
		if marker == null:
			marker = _make_marker(id, radius_m)
			add_child(marker)
			_markers[id] = marker
		else:
			_apply_radius(marker, radius_m)
		marker.position = Vector3(
			float(e["x"]) / MM_PER_M,
			float(e["y"]) / MM_PER_M,
			float(e["z"]) / MM_PER_M,
		)
	for id: Variant in _markers.keys():
		if not live.has(id):
			_free_marker(id as int)


## Number of markers currently drawn.
func count() -> int:
	return _markers.size()


## The marker drawn for `id`, or null when that entity is not replicated.
## Exposed so a test can assert what is actually in the tree rather than a
## bookkeeping number that could agree with itself while the scene stayed
## empty.
func marker_for(id: int) -> MeshInstance3D:
	return _markers.get(id)


func _make_marker(id: int, radius_m: float) -> MeshInstance3D:
	var marker := MeshInstance3D.new()
	# Names uniquify on collision, so this is a debugging aid only — every
	# lookup goes through `_markers`.
	marker.name = "Replica%d" % id
	var mesh := CapsuleMesh.new()
	mesh.height = MARKER_HEIGHT_M
	mesh.radius = radius_m
	_fit_capsule(mesh, radius_m)
	var material := StandardMaterial3D.new()
	material.albedo_color = MARKER_COLOR
	mesh.material = material
	marker.mesh = mesh
	return marker


func _apply_radius(marker: MeshInstance3D, radius_m: float) -> void:
	# The wire carries a radius on every moved entry too, so an entity that
	# changes size while replicated must not keep the size it entered with.
	var mesh: CapsuleMesh = marker.mesh
	if is_equal_approx(mesh.radius, radius_m):
		return
	mesh.radius = radius_m
	_fit_capsule(mesh, radius_m)


## Godot's capsule height INCLUDES both hemispherical caps, so a height below
## 2·radius is geometrically impossible and the engine silently clamps it.
## Growing the height instead keeps a wide entity a capsule rather than
## letting it become a sphere whose radius no longer matches the replicated
## one.
func _fit_capsule(mesh: CapsuleMesh, radius_m: float) -> void:
	mesh.height = maxf(MARKER_HEIGHT_M, 2.0 * radius_m)


func _clear() -> void:
	for id: Variant in _markers.keys():
		_free_marker(id as int)


## Detach before freeing. `queue_free` alone defers removal to the end of the
## frame, so the tree would still hold a marker for an entity that has left
## for the rest of that frame — visible to a caller, and to a test, as a
## departure that did not happen.
func _free_marker(id: int) -> void:
	var marker: MeshInstance3D = _markers[id]
	remove_child(marker)
	marker.queue_free()
	_markers.erase(id)
