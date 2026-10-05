extends Node
## A lifted stride must not spend more horizontal travel than its acceleration.


func _ready() -> void:
	_floor(Vector3(0.0, 399.5, 0.0), Vector3(20.0, 1.0, 20.0))
	_floor(Vector3(2.0, 400.07, 0.0), Vector3(4.0, 0.14, 8.0))
	var player := Player.new()
	add_child(player)
	player.enable_step(0.24)
	player.global_position = Vector3(-0.42, 400.02, 0.0)
	player.face_toward(Vector3(2.0, 400.0, 0.0))
	for _i in 6:
		await get_tree().physics_frame
	Input.action_press("move_forward")
	var previous := player.global_position
	var greatest_excess := 0.0
	for tick in 30:
		await get_tree().physics_frame
		var travel := player.global_position - previous
		var dt := get_physics_process_delta_time()
		var speed := Vector2(travel.x, travel.z).length() / dt
		# The from-rest input has had at most tick+1 acceleration intervals.
		# Collision can consume this budget; it cannot add to it. Allow 1.7 mm
		# of capsule recovery at 60 Hz, far below a target-speed teleport.
		var allowed := minf(Player.WALK_SPEED, Player.ACCEL * (tick + 1) / Engine.physics_ticks_per_second)
		greatest_excess = maxf(greatest_excess, speed - allowed)
		previous = player.global_position
	Input.action_release("move_forward")
	if greatest_excess > 0.1:
		print("TEST FAIL: step travel exceeds the accelerated stride by %.3f m/s" % greatest_excess)
		get_tree().quit(1)
		return
	if player.global_position.x < 0.8 or player.global_position.y < 400.13:
		print("TEST FAIL: a bounded stride never crossed the 14 cm lip")
		get_tree().quit(1)
		return
	player.queue_free()
	await get_tree().physics_frame
	if not await _turn_at_wall() or not await _low_ceiling() or not await _turn_after_release():
		get_tree().quit(1)
		return
	print("TEST PASS: a from-rest lip crossing spends its accelerated stride (largest travel excess %.3f m/s)" % greatest_excess)
	get_tree().quit(0)


func _floor(at: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	var collider := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collider.shape = shape
	body.add_child(collider)
	add_child(body)
	body.global_position = at


func _turn_at_wall() -> bool:
	_floor(Vector3(0.0, 499.5, 0.0), Vector3(20.0, 1.0, 20.0))
	_floor(Vector3(2.0, 500.5, 0.0), Vector3(4.0, 1.0, 8.0))
	_floor(Vector3(-2.0, 500.07, 2.0), Vector3(4.0, 0.14, 4.0))
	var player := Player.new()
	add_child(player)
	player.enable_step(0.24)
	player.global_position = Vector3(-0.42, 500.02, -0.42)
	player.face_toward(Vector3(2.0, 500.0, -0.42))
	for _i in 6:
		await get_tree().physics_frame
	Input.action_press("move_forward")
	for _i in 37:
		await get_tree().physics_frame
	Input.action_release("move_forward")
	if player.global_position.x > -0.39 or player.global_position.y > 500.03:
		print("TEST FAIL: the step crossed or climbed a one-metre wall")
		return false
	Input.action_press("move_right")
	var previous := player.global_position
	for tick in 15:
		await get_tree().physics_frame
		var travel := player.global_position - previous
		var speed := Vector2(travel.x, travel.z).length() / get_physics_process_delta_time()
		var allowed := minf(Player.WALK_SPEED, Player.ACCEL * (tick + 1) / Engine.physics_ticks_per_second)
		if speed > allowed + 0.1:
			Input.action_release("move_right")
			print("TEST FAIL: turning beside a wall spent the previous heading's stride budget")
			return false
		previous = player.global_position
	Input.action_release("move_right")
	player.queue_free()
	await get_tree().physics_frame
	return true


func _low_ceiling() -> bool:
	_floor(Vector3(0.0, 599.5, 0.0), Vector3(20.0, 1.0, 20.0))
	_floor(Vector3(2.0, 600.07, 0.0), Vector3(4.0, 0.14, 8.0))
	_floor(Vector3(0.0, 601.93, 0.0), Vector3(12.0, 0.1, 12.0))
	var player := Player.new()
	add_child(player)
	player.enable_step(0.24)
	player.global_position = Vector3(-1.6, 600.02, 0.0)
	player.face_toward(Vector3(2.0, 600.0, 0.0))
	for _i in 6:
		await get_tree().physics_frame
	Input.action_press("move_forward")
	for _i in 37:
		await get_tree().physics_frame
	Input.action_release("move_forward")
	if player.global_position.x > -0.01 or player.global_position.y > 600.09:
		print("TEST FAIL: a step squeezed through insufficient headroom")
		return false
	player.queue_free()
	await get_tree().physics_frame
	return true


func _turn_after_release() -> bool:
	_floor(Vector3(0.0, 699.5, 0.0), Vector3(20.0, 1.0, 20.0))
	_floor(Vector3(2.0, 700.07, 0.0), Vector3(4.0, 0.14, 20.0))
	var player := Player.new()
	add_child(player)
	player.enable_step(0.24)
	player.global_position = Vector3(-0.32, 700.02, 3.0)
	player.face_toward(Vector3(-0.32, 700.0, -3.0))
	for _i in 6:
		await get_tree().physics_frame
	Input.action_press("move_forward")
	for _i in 24:
		await get_tree().physics_frame
	Input.action_release("move_forward")
	await get_tree().physics_frame
	var before := player.global_position
	Input.action_press("move_right")
	await get_tree().physics_frame
	var sideways := player.global_position.x - before.x
	Input.action_release("move_right")
	var dt := get_physics_process_delta_time()
	if sideways > Player.ACCEL * dt * dt + 0.002:
		print("TEST FAIL: a released-input interval transferred forward momentum into a sideways step")
		return false
	player.queue_free()
	await get_tree().physics_frame
	return true
