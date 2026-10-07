extends Node
## Raised stone stays bare; live preview toggles restore the exact original cover.


func _ready() -> void:
	OS.unset_environment("WAR_GROUND_PLATES")
	var world := WorldGen.new()
	add_child(world)
	var original := world.foliage_placements()
	if original.is_empty():
		_fail("the baseline world must contain cover")
		return
	var batches: Array[Node] = []
	for kind in FoliageGen.KIND_COUNT:
		batches.append(world.get_node("Foliage_%d" % kind))
	world.set_ground_plates_enabled(true)
	var tops := world.ground_plate_tops()
	var overlaps := _overlaps(original, tops)
	if overlaps < 1:
		_fail("the shipped seed must exercise cover on a built slab")
		return
	var exposed := world.visible_foliage_placements
	if world.foliage_placements() != original:
		_fail("the preview changed the baseline scatter")
		return
	for placement in exposed:
		if not original.has(placement):
			_fail("visible ash cover changed its original lifted pose or traits")
			return
	if _overlaps(exposed, tops) != 0:
		_fail("foliage grows through raised exposed stone (%d overlaps among %d props)" % [_overlaps(exposed, tops), exposed.size()])
		return
	if exposed.size() != original.size() - overlaps or not _render_count_matches(world, exposed.size()):
		_fail("the visible batches do not match the remaining ash cover")
		return
	world.set_ground_plates_enabled(false)
	if world.visible_foliage_placements != original or not _render_count_matches(world, original.size()):
		_fail("turning slabs off did not restore the exact original scatter")
		return
	OS.set_environment("WAR_GROUND_PLATES", "1")
	var fresh := WorldGen.new()
	add_child(fresh)
	OS.unset_environment("WAR_GROUND_PLATES")
	if fresh.visible_foliage_placements != exposed or fresh.foliage_placements() != original \
			or not _render_count_matches(fresh, exposed.size()):
		_fail("a fresh opted-in boot differs from the live preview")
		return
	for _toggle in 3:
		world.set_ground_plates_enabled(true)
		if world.visible_foliage_placements != exposed:
			_fail("repeated preview accumulated a pose offset")
			return
		world.set_ground_plates_enabled(false)
		if world.visible_foliage_placements != original:
			_fail("repeated opt-out changed the baseline poses")
			return
	for kind in FoliageGen.KIND_COUNT:
		if world.get_node("Foliage_%d" % kind) != batches[kind]:
			_fail("the preview replaced a baseline foliage node")
			return
	var copy := fresh.visible_foliage_placements
	copy[0]["pos"] = Vector3.INF
	if fresh.visible_foliage_placements != exposed:
		_fail("a caller changed the world's visible cover through its copy")
		return
	print("TEST PASS: %d slab overlaps removed; %d ash props retained; opt-out restores all %d placements and visible instances" % [overlaps, exposed.size(), original.size()])
	get_tree().quit(0)


func _overlaps(placements: Array[Dictionary], tops: Array[Dictionary]) -> int:
	var count := 0
	for placement in placements:
		var pos: Vector3 = placement["pos"]
		for top in tops:
			if _inside_convex(Vector2(pos.x, pos.z), top[&"polygon"]):
				count += 1
				break
	return count


## Independent convex half-plane test; does not reuse the world's lookup.
func _inside_convex(point: Vector2, polygon: PackedVector2Array) -> bool:
	var positive := false
	var negative := false
	for i in polygon.size():
		var side := (polygon[(i + 1) % polygon.size()] - polygon[i]).cross(point - polygon[i])
		positive = positive or side > 0.00001
		negative = negative or side < -0.00001
		if positive and negative:
			return false
	return polygon.size() >= 3


func _render_count_matches(world: WorldGen, count: int) -> bool:
	var visible := 0
	for kind in FoliageGen.KIND_COUNT:
		var batch := world.get_node_or_null("Foliage_%d" % kind) as MultiMeshInstance3D
		if batch != null:
			visible += batch.multimesh.instance_count
	return visible == count


func _fail(message: String) -> void:
	print("TEST FAIL: " + message)
	get_tree().quit(1)
