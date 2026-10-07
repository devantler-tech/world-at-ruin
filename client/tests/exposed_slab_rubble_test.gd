extends Node
## Edge-derived chips and grit: synthetic fixtures make each spatial law visible.

const SCRIPT := "res://scripts/exposed_slab_rubble.gd"
const MAX_APRONS := 192
const MAX_PLACEMENTS := 1152
const MESH_RADIUS := 0.4


func _ready() -> void:
	if not ResourceLoader.exists(SCRIPT):
		_fail("built slab edges have no rubble placement library")
		return
	var library := load(SCRIPT) as GDScript
	var generator: Object = library.new()
	var thin_clear := bool(generator.call(&"_space_clear", Vector2.ZERO, 0.2, _clear, _thin_top))
	var circle_clear := bool(generator.call(&"_space_clear", Vector2.ZERO, 0.2, _small_circle, _no_top))
	if thin_clear or circle_clear:
		_fail("partial footprint overlap accepted: thin intact slab %s, protected circle %s" % [thin_clear, circle_clear])
		return
	if not bool(generator.call(&"_space_clear", Vector2(-0.3, 0.0), 0.2, _small_circle, _thin_top)):
		_fail("exact footprint clearance rejects genuinely separated stone/circles")
		return
	if not _indexed_footprint_clearance():
		return
	var source := [_top(Vector2.ZERO, Vector3i(1409, 0, 0))]
	seed(1024)
	var first: Dictionary = generator.call(&"build", source, _ground, _clear, _no_top, MESH_RADIUS)
	seed(8192)
	var again: Dictionary = generator.call(&"build", source, _ground, _clear, _no_top, MESH_RADIUS)
	if first != again:
		_fail("process random state changed an edge-derived apron")
		return
	if source != [_top(Vector2.ZERO, Vector3i(1409, 0, 0))]:
		_fail("building the apron mutated its source slab records")
		return
	var items: Array = first.get(&"placements", [])
	var aprons: Array = first.get(&"aprons", [])
	if items.size() < 4 or aprons.size() != 1:
		_fail("the one ash-facing edge produced no graded apron: %s" % [first])
		return
	if not FoliageGen.find_forbidden(items).is_empty():
		_fail("edge provenance leaked into the closed cosmetic placement schema")
		return
	var apron: Dictionary = aprons[0]
	if apron.get(&"identity") != Vector3i(1409, 0, 0) or int(apron.get(&"edge_index", -1)) != 0:
		_fail("the apron is not attached to the sole ash-facing source edge")
		return
	var near_scale := 0.0
	var far_scale := INF
	for item: Dictionary in items:
		var pos: Vector3 = item["pos"]
		if int(item["kind"]) != FoliageGen.Kind.RUBBLE or not pos.is_finite() \
				or absf(pos.y - _ground(pos.x, pos.z)) > 0.00001:
			_fail("a cluster instance is not cosmetic rubble on the supplied ground")
			return
		if pos.z >= -1.0 or pos.z < -1.9 or absf(pos.x) > 0.9:
			_fail("a cluster instance left its source-edge apron or fell inside intact stone: %s" % pos)
			return
		if pos.z > -1.55:
			near_scale = maxf(near_scale, float(item["scale"]))
		else:
			far_scale = minf(far_scale, float(item["scale"]))
	if near_scale <= far_scale or not is_finite(far_scale):
		_fail("large lip chips do not grade into smaller grit outward")
		return
	var grit_only: Dictionary = generator.call(&"build", source, _ground, _chip_blocked, _no_top, MESH_RADIUS)
	if not (grit_only[&"placements"] as Array).is_empty():
		_fail("an apron survives with only small grit after every larger lip chip is blocked")
		return
	var intact: Dictionary = generator.call(&"build", [_top(Vector2.ZERO, Vector3i(1409, 0, 0), false)], _ground, _clear, _no_top, MESH_RADIUS)
	if not (intact[&"placements"] as Array).is_empty():
		_fail("intact edges acquired decorative rubble")
		return
	var protected: Dictionary = generator.call(&"build", source, _ground, _blocked, _no_top, MESH_RADIUS)
	if not (protected[&"placements"] as Array).is_empty():
		_fail("a protected approach acquired rubble")
		return
	var shared: Dictionary = generator.call(&"build", source, _ground, _clear, _neighbor_top, MESH_RADIUS)
	if not (shared[&"placements"] as Array).is_empty():
		_fail("a shared intact stone edge acquired rubble")
		return
	var missing: Dictionary = generator.call(&"build", source, _missing_ground, _clear, _no_top, MESH_RADIUS)
	if not (missing[&"placements"] as Array).is_empty():
		_fail("a missing surface acquired rubble")
		return
	var no_sampler: Dictionary = generator.call(&"build", source, Callable(), _clear, _no_top, MESH_RADIUS)
	if not (no_sampler[&"placements"] as Array).is_empty():
		_fail("a missing ground sampler did not fail closed")
		return
	var crowded: Array[Dictionary] = []
	for i in 300:
		crowded.append(_top(Vector2(float(i) * 4.0, 0.0), Vector3i(1409, i, 0)))
	var bounded: Dictionary = generator.call(&"build", crowded, _ground, _clear, _no_top, MESH_RADIUS)
	if (bounded[&"aprons"] as Array).size() != MAX_APRONS \
			or (bounded[&"placements"] as Array).size() > MAX_PLACEMENTS:
		_fail("an abundant source exceeded or vacuously missed the fixed apron/instance bounds")
		return
	crowded.reverse()
	var reordered: Dictionary = generator.call(&"build", crowded, _ground, _clear, _no_top, MESH_RADIUS)
	if bounded != reordered:
		_fail("source enumeration order changed which world edges won the cap")
		return
	var oversized: Array = []
	oversized.resize(36_101)
	oversized.fill(source[0])
	var refused: Dictionary = generator.call(&"build", oversized, _ground, _clear, _no_top, MESH_RADIUS)
	if not (refused[&"placements"] as Array).is_empty():
		_fail("an over-budget source field did not fail closed")
		return
	var shifted: Dictionary = generator.call(&"build", [_top(Vector2(8.0, 5.0), Vector3i(1409, 0, 0))], _ground, _clear, _no_top, MESH_RADIUS)
	var moved: Array = shifted[&"placements"]
	if moved.size() != items.size():
		_fail("moving the actual source polygon changed its apron count")
		return
	for i in moved.size():
		var delta: Vector3 = (moved[i] as Dictionary)["pos"] - (items[i] as Dictionary)["pos"]
		if absf(delta.x - 8.0) > 0.00001 or absf(delta.z - 5.0) > 0.00001:
			_fail("rubble follows an independent world pattern instead of its source edge")
			return
	print("TEST PASS: edge-derived rubble — exact footprint/index clearance, ash-facing source, graded chips/grit, deterministic, %d-apron/%d-cluster-instance bounds" % [MAX_APRONS, MAX_PLACEMENTS])
	get_tree().quit(0)


func _indexed_footprint_clearance() -> bool:
	# Its centre cell is empty, but the disk intersects a thin raised polygon
	# indexed in the NEXT cell. Centre-only lookup must fail this fixture.
	var tops := [{&"polygon": PackedVector2Array([Vector2(2.06, -0.3),
		Vector2(2.12, -0.3), Vector2(2.12, 0.3), Vector2(2.06, 0.3)])}]
	var index := {Vector2i(1, -1): PackedInt32Array([0]),
		Vector2i(1, 0): PackedInt32Array([0])}
	if not ExposedSlabRubble.intersects_index(Vector2(1.9, 0.0), 0.2, tops, index, 2.0) \
			or ExposedSlabRubble.intersects_index(Vector2(1.6, 0.0), 0.2, tops, index, 2.0):
		_fail("a footprint misses the adjacent index cell or rejects a separated control")
		return false
	# A far-away invalid record is not a local blocker. Looking at it would
	# turn this empty neighbourhood into a full-world scan (or a script error).
	if ExposedSlabRubble.intersects_index(Vector2.ZERO, 0.2, [{}], {}, 2.0) \
			or not ExposedSlabRubble.intersects_index(Vector2.ZERO, 1.01, [], {}, 2.0):
		_fail("footprint lookup scans unrelated tops or accepts an unbounded radius")
		return false
	return true


func _top(at: Vector2, identity: Vector3i, weathered: bool = true) -> Dictionary:
	return {
		&"identity": identity,
		&"polygon": PackedVector2Array([at + Vector2(-1.0, -1.0), at + Vector2(1.0, -1.0), at + Vector2(1.0, 1.0), at + Vector2(-1.0, 1.0)]),
		&"thickness": 0.12,
		&"edge_ash": PackedFloat32Array([0.8 if weathered else 0.0, 0.0, 0.0, 0.0]),
	}


func _ground(x: float, z: float) -> float:
	return x * 0.02 + z * 0.03


func _clear(_x: float, _z: float, _radius: float = 0.0) -> bool:
	return false


func _blocked(_x: float, _z: float, _radius: float = 0.0) -> bool:
	return true


func _chip_blocked(_x: float, _z: float, radius: float = 0.0) -> bool:
	return radius > 0.15


func _no_top(_x: float, _z: float, _radius: float = 0.0) -> bool:
	return false


func _neighbor_top(_x: float, z: float, radius: float = 0.0) -> bool:
	return z - radius <= -1.0


func _thin_top(x: float, z: float, radius: float = 0.0) -> bool:
	return ExposedSlabRubble.circle_hits_polygon(Vector2(x, z), radius,
		PackedVector2Array([Vector2(0.06, -0.3), Vector2(0.12, -0.3),
		Vector2(0.12, 0.3), Vector2(0.06, 0.3)]))


func _small_circle(x: float, z: float, radius: float = 0.0) -> bool:
	return Vector2(x, z).distance_to(Vector2(0.12, 0.0)) <= 0.025 + radius


func _missing_ground(_x: float, _z: float) -> float:
	return -1.0e6


func _fail(message: String) -> void:
	print("TEST FAIL: " + message)
	get_tree().quit(1)
