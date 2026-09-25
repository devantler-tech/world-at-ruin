extends Node
## How often a walking player fails to get onto raised exposed stone (#548).
##
## `ground_plates_physics_test` proves the representative crossings; this
## measures the rest. It walks a real Player onto many slab lips of the shipped
## seed — every seventh built top at least 10 cm thick, one edge each, with an
## approach of open ash that no ruin, person or other slab stands on — at three
## approach angles, walking and sprinting, once with no step and once with the
## world's own step, and prints how many stalled. The case list is a pure
## function of the seed, so two runs of one build walk the same lips.
##
## Run (headless is fine — physics needs no GPU; it takes a few minutes):
##   godot --headless --path client res://tools/plate_crossing_sweep.tscn
##
## Prints one `CROSSING` line per step setting and a `STALL` line per failed walk.

## Every nth built top is sampled, so the lips spread across the world rather
## than bunching where the builder happens to start.
const SAMPLE_EVERY := 7
const MIN_THICKNESS := 0.10
const MAX_CASES := 60
## Approach angles to the lip, degrees: head-on, diagonal, and glancing.
const ANGLES := [90.0, 45.0, 25.0]
const APPROACH_M := 1.6
const INSIDE_M := 0.6
const ARRIVED_M := 0.3
## A walk gets this multiple of the straight-line time before it counts as a
## stall.
const TIME_FACTOR := 2.0

var _world: WorldGen


func _ready() -> void:
	OS.set_environment("WAR_GROUND_PLATES", "1")
	_world = WorldGen.new()
	add_child(_world)
	OS.unset_environment("WAR_GROUND_PLATES")
	for _i in 3:
		await get_tree().physics_frame
	var cases := _cases()
	if cases.is_empty():
		print("CROSSING FAIL — no lip qualified; is the overlay built?")
		get_tree().quit(1)
		return
	for step: float in [0.0, _world.ground_plates_step_height()]:
		var stalls := {}
		var runs := {}
		for angle: float in ANGLES:
			stalls[angle] = 0
			runs[angle] = 0
		for c: Dictionary in cases:
			for angle: float in ANGLES:
				for sprint: bool in [false, true]:
					var path := _path(c, angle)
					if path.is_empty():
						continue
					runs[angle] += 1
					if not await _walk(path[0], path[1], sprint, step):
						stalls[angle] += 1
						print("STALL step %.2f: %.3f m lip at %s, %.0f deg, %s" % [
							step, c[&"thickness"], c[&"mid"], angle, "sprint" if sprint else "walk"])
		var total_runs := 0
		var total_stalls := 0
		var by_angle: Array[String] = []
		for angle: float in ANGLES:
			total_runs += runs[angle]
			total_stalls += stalls[angle]
			by_angle.append("%.0f deg %d/%d" % [angle, stalls[angle], runs[angle]])
		print("CROSSING step %.2f m: %d of %d walks stalled (%.1f%%) — %s" % [
			step, total_stalls, total_runs, 100.0 * total_stalls / maxf(total_runs, 1.0),
			", ".join(by_angle)])
	get_tree().quit(0)


## The sampled lips: a top, one of its edges, and the outward direction.
func _cases() -> Array[Dictionary]:
	var cases: Array[Dictionary] = []
	var tops := _world.ground_plate_tops()
	for index in range(0, tops.size(), SAMPLE_EVERY):
		var top := tops[index]
		var thickness := float(top[&"thickness"])
		if thickness < MIN_THICKNESS:
			continue
		var polygon := top[&"polygon"] as PackedVector2Array
		var centre := ExposedSlabGeometry.centroid(polygon)
		if absf(centre.x) > 95.0 or absf(centre.y) > 95.0 or _world.cave_protects(centre.x, centre.y):
			continue
		for corner in polygon.size():
			var a := polygon[corner]
			var b := polygon[(corner + 1) % polygon.size()]
			if a.distance_to(b) < 0.6:
				continue
			var mid := (a + b) * 0.5
			var outward := Vector2(b.y - a.y, a.x - b.x).normalized()
			if outward.dot(mid - centre) < 0.0:
				outward = -outward
			var probe := mid + outward * 0.15
			if _world.ground_plate_thickness_at(probe.x, probe.y) != 0.0:
				continue
			cases.append({
				&"thickness": thickness,
				&"mid": mid,
				&"outward": outward,
				&"along": (b - a).normalized(),
			})
			break
		if cases.size() >= MAX_CASES:
			break
	return cases


## Start and end of one approach, or empty when the approach is not open ash.
func _path(c: Dictionary, angle_deg: float) -> Array[Vector2]:
	var inward := -(c[&"outward"] as Vector2)
	var along := c[&"along"] as Vector2
	var dir := (inward * sin(deg_to_rad(angle_deg)) + along * cos(deg_to_rad(angle_deg))).normalized()
	var mid := c[&"mid"] as Vector2
	var from := mid - dir * APPROACH_M
	var to := mid + dir * INSIDE_M
	for k in 15:
		var q := from.lerp(mid - dir * 0.12, float(k) / 14.0)
		if _world.ground_plate_thickness_at(q.x, q.y) != 0.0 \
				or _world.surface_height_at(q.x, q.y) <= WorldGen.NO_GROUND:
			return []
	if not _clear(from, to):
		return []
	return [from, to]


## No ruin, person or other solid thing stands on the path.
func _clear(from: Vector2, to: Vector2) -> bool:
	var exclude: Array[RID] = []
	for body_name: String in ["TerrainBody", WorldGen.GROUND_PLATES_BODY]:
		var body := _world.get_node_or_null(body_name) as CollisionObject3D
		if body != null:
			exclude.append(body.get_rid())
	var shape := CapsuleShape3D.new()
	shape.radius = 0.45
	shape.height = 1.4
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.exclude = exclude
	var space := get_viewport().world_3d.direct_space_state
	for k in 12:
		var p := from.lerp(to, float(k) / 11.0)
		query.transform = Transform3D(Basis(), Vector3(p.x, _world.walkable_height_at(p.x, p.y) + 0.9, p.y))
		if not space.intersect_shape(query, 1).is_empty():
			return false
	return true


func _walk(from: Vector2, to: Vector2, sprint: bool, step: float) -> bool:
	var player := Player.new()
	add_child(player)
	player.ground_height_provider = _world.walkable_height_at
	player.enable_step(step)
	player.global_position = Vector3(from.x, _world.walkable_height_at(from.x, from.y) + 0.02, from.y)
	player.face_toward(Vector3(to.x, player.global_position.y, to.y))
	for _i in 6:
		await get_tree().physics_frame
	Input.action_press("move_forward")
	if sprint:
		Input.action_press("sprint")
	var speed := Player.SPRINT_SPEED if sprint else Player.WALK_SPEED
	var budget := int(ceil(from.distance_to(to) / speed * TIME_FACTOR * Engine.physics_ticks_per_second)) + 12
	var arrived := false
	for _tick in budget:
		await get_tree().physics_frame
		var p := player.global_position
		if Vector2(p.x, p.z).distance_to(to) < ARRIVED_M:
			arrived = true
			break
	Input.action_release("move_forward")
	Input.action_release("sprint")
	player.queue_free()
	await get_tree().physics_frame
	return arrived
