extends "res://tools/plate_crossing_sweep.gd"
## Regressions from the shipped sweep: actual uphill crossings, not arrival
## tolerance beside an edge. The literal midpoints name previously stalled lips.


func _ready() -> void:
	OS.set_environment("WAR_GROUND_PLATES", "1")
	_world = WorldGen.new()
	add_child(_world)
	OS.unset_environment("WAR_GROUND_PLATES")
	for _i in 3:
		await get_tree().physics_frame
	var cases := _cases()
	var crossed := 0
	for target in [Vector2(51.09569, -73.95025), Vector2(48.04568, -67.80566), Vector2(2.851202, -76.22473)]:
		var found := false
		for c in cases:
			if (c[&"mid"] as Vector2).distance_to(target) > 0.001:
				continue
			found = true
			for angle in ANGLES:
				var path := _path(c, angle)
				if path.is_empty():
					continue
				for sprint in [false, true]:
					if not await _cross_lip(c, path, angle, sprint):
						get_tree().quit(1)
						return
					crossed += 1
		if not found:
			print("TEST FAIL: regression lip disappeared from the shipped census: ", target)
			get_tree().quit(1)
			return
	if crossed < 12:
		print("TEST FAIL: fewer than twelve regression paths were exercised: ", crossed)
		get_tree().quit(1)
		return
	print("TEST PASS: %d shipped uphill lip paths crossed head-on and glancing at walk and sprint, with real raised-side support" % crossed)
	get_tree().quit(0)


func _cross_lip(c: Dictionary, path: Array[Vector2], angle: float, sprint: bool) -> bool:
	var player := Player.new()
	add_child(player)
	player.ground_height_provider = _world.walkable_height_at
	player.enable_step(_world.ground_plates_step_height())
	player.global_position = Vector3(path[0].x, _world.walkable_height_at(path[0].x, path[0].y) + 0.02, path[0].y)
	player.face_toward(Vector3(path[1].x, player.global_position.y, path[1].y))
	for _i in 6:
		await get_tree().physics_frame
	Input.action_press("move_forward")
	if sprint:
		Input.action_press("sprint")
	var speed := Player.SPRINT_SPEED if sprint else Player.WALK_SPEED
	var budget := int(ceil(path[0].distance_to(path[1]) / speed * TIME_FACTOR * Engine.physics_ticks_per_second)) + 12
	var arrived := false
	for _tick in budget:
		await get_tree().physics_frame
		var pos := Vector2(player.global_position.x, player.global_position.z)
		# The capsule centre must actually cross onto stone, not just approach
		# within the sweep's 30 cm endpoint tolerance from the ash side.
		if pos.distance_to(path[1]) < ARRIVED_M and _world.ground_plate_at(pos.x, pos.y) >= 0 \
				and (pos - (c[&"mid"] as Vector2)).dot(-(c[&"outward"] as Vector2)) > 0.02:
			arrived = true
			break
	Input.action_release("move_forward")
	Input.action_release("sprint")
	for _i in 20:
		await get_tree().physics_frame
	var settled := player.is_on_floor()
	player.queue_free()
	await get_tree().physics_frame
	if not arrived or not settled:
		print("TEST FAIL: uphill lip %s, %.0f degrees, %s: crossed=%s settled=%s" % [c[&"mid"], angle, "sprint" if sprint else "walk", arrived, settled])
		return false
	return true
