class_name ExposedSlabRubble
extends RefCounted
## Cosmetic fracture aprons derived only from actual built slab edge records.
## Larger chips gather at an ash-facing lip; smaller grit falls further out.
## Baseline foliage, solid geometry, gameplay and the process RNG are untouched.

const MAX_SOURCE_SLABS := 36_100
const MAX_EDGES_PER_SLAB := 24
const MAX_APRONS := 192
const PIECES_PER_APRON := 6
const MAX_PLACEMENTS := MAX_APRONS * PIECES_PER_APRON
const MIN_EDGE_LENGTH := 0.36
const MIN_ASH_COVER := 0.5
const NO_GROUND := -1.0e6
## Keeps a placement query inside at most nine of the world's 2 m index cells.
## The actual generated mesh is smaller; its bound is derived, never guessed.
const MAX_FOOTPRINT_RADIUS := 1.0


## `tops` are ExposedSlabGeometry's clipped polygons, stable identities and
## edge_ash samples. Both clearance callbacks accept (x,z,radius) and answer
## whether the whole circle meets stone or a protected approach. on_top
## consumes the world's ORIGINAL nearby-cell index. Placement dictionaries
## retain FoliageGen's closed schema; separate aprons carry source provenance.
func build(tops: Array, ground: Callable, keep_out: Callable, on_top: Callable,
		footprint_radius: float) -> Dictionary:
	var out: Array[Dictionary] = []
	var aprons: Array[Dictionary] = []
	var stats := {&"source_slabs": tops.size(), &"source_edges": 0,
		&"candidates": 0, &"aprons": 0, &"placements": 0}
	var result := {&"placements": out, &"aprons": aprons, &"stats": stats}
	if tops.size() > MAX_SOURCE_SLABS or not ground.is_valid() \
			or not keep_out.is_valid() or not on_top.is_valid() \
			or not is_finite(footprint_radius) or footprint_radius <= 0.0 \
			or footprint_radius > MAX_FOOTPRINT_RADIUS:
		return result
	var candidates: Array[Dictionary] = []
	for raw: Variant in tops:
		if not _valid_top(raw):
			continue
		var top := raw as Dictionary
		var identity: Vector3i = top[&"identity"]
		var polygon: PackedVector2Array = top[&"polygon"]
		var ash: PackedFloat32Array = top[&"edge_ash"]
		stats[&"source_edges"] += polygon.size()
		for edge in polygon.size():
			var a := polygon[edge]
			var b := polygon[(edge + 1) % polygon.size()]
			var direction := b - a
			if ash[edge] < MIN_ASH_COVER or direction.length() < MIN_EDGE_LENGTH:
				continue
			var outward := Vector2(direction.y, -direction.x).normalized()
			var centre := a.lerp(b, 0.5)
			# A joint between two raised slabs is intact stone, even when the
			# drift paints some ash over their shared boundary.
			var outer := centre + outward * 0.08
			if bool(on_top.call(outer.x, outer.y, 0.0)):
				continue
			var key := _edge_key(identity, edge)
			candidates.append({&"identity": identity, &"edge_index": edge,
				&"a": a, &"b": b, &"outward": outward,
				&"ash_cover": ash[edge], &"key": key,
				&"rank": GroundRegions.unit_hash(key)})
	stats[&"candidates"] = candidates.size()
	# Ranking makes the hard cap spatially distributed instead of truncating
	# the row-major world scan to one side. Ties resolve by source identity.
	candidates.sort_custom(_before)
	for candidate: Dictionary in candidates:
		if aprons.size() >= MAX_APRONS:
			break
		var pieces := _pieces(candidate, ground, keep_out, on_top, footprint_radius)
		if pieces.size() < 4:
			continue
		candidate.erase(&"rank")
		candidate.erase(&"key")
		candidate[&"placement_start"] = out.size()
		candidate[&"placement_count"] = pieces.size()
		aprons.append(candidate)
		out.append_array(pieces)
	stats[&"aprons"] = aprons.size()
	stats[&"placements"] = out.size()
	return result


static func _valid_top(raw: Variant) -> bool:
	if raw is not Dictionary:
		return false
	var top := raw as Dictionary
	if top.get(&"identity") is not Vector3i \
			or top.get(&"polygon") is not PackedVector2Array \
			or top.get(&"edge_ash") is not PackedFloat32Array:
		return false
	var polygon: PackedVector2Array = top[&"polygon"]
	var ash: PackedFloat32Array = top[&"edge_ash"]
	if polygon.size() < 3 or polygon.size() > MAX_EDGES_PER_SLAB \
			or ash.size() != polygon.size():
		return false
	var winding := 0.0
	for i in polygon.size():
		if not polygon[i].is_finite() or not is_finite(ash[i]):
			return false
		winding += polygon[i].cross(polygon[(i + 1) % polygon.size()])
	return winding > 0.000001


static func _pieces(edge: Dictionary, ground: Callable,
		keep_out: Callable, on_top: Callable, footprint_radius: float) -> Array[Dictionary]:
	var items: Array[Dictionary] = []
	var a: Vector2 = edge[&"a"]
	var b: Vector2 = edge[&"b"]
	var outward: Vector2 = edge[&"outward"]
	var tangent := (b - a).normalized()
	var key: int = edge[&"key"]
	var centre := a.lerp(b, 0.45 + _unit(key, 1) * 0.1)
	var spread := minf(a.distance_to(b) * 0.28, 0.25)
	var chips := 0
	var grains := 0
	for index in PIECES_PER_APRON:
		var grit := index >= 2
		# Leave room for the real cluster's full footprint beside the lip.
		# Keep the grit band outside every chip centre, even after filtering.
		var distance := lerpf(0.60, 0.85, _unit(key, 10 + index)) if grit \
			else lerpf(0.38, 0.48, _unit(key, 10 + index))
		var sideways := lerpf(-spread, spread, _unit(key, 20 + index))
		var scale := lerpf(0.16, 0.28, _unit(key, 30 + index)) if grit \
			else lerpf(0.58, 0.82, _unit(key, 30 + index))
		var at := centre + outward * distance + tangent * sideways
		if not _space_clear(at, footprint_radius * scale, keep_out, on_top):
			continue
		var y := float(ground.call(at.x, at.y))
		if not is_finite(y) or y <= NO_GROUND:
			continue
		items.append({"kind": FoliageGen.Kind.RUBBLE,
			"pos": Vector3(at.x, y, at.y),
			"yaw": _unit(key, 40 + index) * TAU, "scale": scale})
		if grit:
			grains += 1
		else:
			chips += 1
	# A blocked lip must not leave an unrelated sprinkling of grit behind.
	if chips < 1 or grains < 2:
		return []
	return items


static func _space_clear(at: Vector2, radius: float,
		keep_out: Callable, on_top: Callable) -> bool:
	return not bool(keep_out.call(at.x, at.y, radius)) \
		and not bool(on_top.call(at.x, at.y, radius))


## A yaw-independent circle enclosing every horizontal mesh vertex, including
## the baked chunk tilts and off-centre pieces. Uniform instance scale applies
## afterwards. The AABB corners enclose the mesh at EVERY yaw, not four probes.
static func mesh_radius(mesh: Mesh) -> float:
	if mesh == null:
		return INF
	var bounds := mesh.get_aabb()
	var end := bounds.end
	var x := maxf(absf(bounds.position.x), absf(end.x))
	var z := maxf(absf(bounds.position.z), absf(end.z))
	return Vector2(x, z).length()


## Exact circle/polygon intersection: interior containment or distance to ANY
## segment at most the circle radius. Thin sides cannot hide between probes.
static func circle_hits_polygon(at: Vector2, radius: float,
		polygon: PackedVector2Array) -> bool:
	if not at.is_finite() or not is_finite(radius) or radius < 0.0 \
			or polygon.size() < 3 or polygon.size() > MAX_EDGES_PER_SLAB:
		return true
	if Geometry2D.is_point_in_polygon(at, polygon):
		return true
	var radius_sq := (radius + 0.000001) * (radius + 0.000001)
	for i in polygon.size():
		var a := polygon[i]
		var b := polygon[(i + 1) % polygon.size()]
		var delta := b - a
		var length_sq := delta.length_squared()
		var t := clampf((at - a).dot(delta) / length_sq, 0.0, 1.0) \
			if length_sq > 0.0000000001 else 0.0
		if at.distance_squared_to(a + delta * t) <= radius_sq:
			return true
	return false


## Reuse the walkable top index. A radius at most half a 2 m cell checks at
## most nine nearby buckets; it neither builds a grid nor scans all world tops.
static func intersects_index(at: Vector2, radius: float, tops: Array,
		index: Dictionary, cell_size: float) -> bool:
	if not at.is_finite() or not is_finite(radius) or radius < 0.0 \
			or radius > MAX_FOOTPRINT_RADIUS or not is_finite(cell_size) \
			or cell_size < MAX_FOOTPRINT_RADIUS * 2.0:
		return true
	var seen := {}
	var lo := Vector2i(floori((at.x - radius) / cell_size),
		floori((at.y - radius) / cell_size))
	var hi := Vector2i(floori((at.x + radius) / cell_size),
		floori((at.y + radius) / cell_size))
	for z in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			for slab: int in index.get(Vector2i(x, z), PackedInt32Array()):
				if seen.has(slab):
					continue
				seen[slab] = true
				if slab < 0 or slab >= tops.size():
					return true
				if circle_hits_polygon(at, radius, (tops[slab] as Dictionary)[&"polygon"]):
					return true
	return false


static func _edge_key(identity: Vector3i, edge: int) -> int:
	return (identity.x * 83492791) ^ (identity.y * 73856093) \
		^ (identity.z * 19349663) ^ (edge * 104729)


static func _unit(key: int, channel: int) -> float:
	return GroundRegions.unit_hash(key ^ (channel * 15485863))


static func _before(a: Dictionary, b: Dictionary) -> bool:
	if a[&"rank"] != b[&"rank"]:
		return float(a[&"rank"]) < float(b[&"rank"])
	var ai: Vector3i = a[&"identity"]
	var bi: Vector3i = b[&"identity"]
	if ai != bi:
		if ai.x != bi.x:
			return ai.x < bi.x
		if ai.y != bi.y:
			return ai.y < bi.y
		return ai.z < bi.z
	return int(a[&"edge_index"]) < int(b[&"edge_index"])
