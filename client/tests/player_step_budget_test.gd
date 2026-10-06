extends Node
## A lifted stride must not spend more horizontal travel than its acceleration.

class AirBudgetPlayer extends Player:
	var measuring := false
	var earned := 0.0
	var unsupported_ticks := 0
	var accepted_steps := 0
	var greatest_excess := 0.0

	func _physics_process(delta: float) -> void:
		if measuring:
			var supported := is_grounded()
			if not supported:
				unsupported_ticks += 1
			earned = minf(WALK_SPEED, earned + ACCEL * (1.0 if supported else AIR_CONTROL) * delta)
		super._physics_process(delta)

	func _step_up(from: Transform3D, intended: Vector3, ramped: Vector3, standing_on: Vector3) -> void:
		var plain := global_position
		super._step_up(from, intended, ramped, standing_on)
		if measuring and global_position.y > plain.y + 0.001:
			accepted_steps += 1
			var travel := (global_position - from.origin).dot(intended.normalized())
			greatest_excess = maxf(greatest_excess, travel - earned * get_physics_process_delta_time())


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
	if not await _turn_at_wall() or not await _low_ceiling() or not await _turn_after_release() \
			or not await _gentle_turning_lip() or not await _airborne_turn() or not await _respawn_stride():
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


func _gentle_turning_lip() -> bool:
	_floor(Vector3(0.0, 799.5, 0.0), Vector3(20.0, 1.0, 20.0))
	_floor(Vector3(2.0, 800.07, 0.0), Vector3(4.0, 0.14, 20.0))
	var player := Player.new()
	add_child(player)
	player.enable_step(0.24)
	player.global_position = Vector3(-0.42, 800.02, 0.0)
	player.face_toward(player.global_position + Vector3.RIGHT)
	for _i in 6:
		await get_tree().physics_frame
	Input.action_press("move_forward")
	for tick in 30:
		# Small camera corrections keep forward input held. Each four-degree
		# change must retain its projected momentum rather than restart at rest.
		var heading := Vector3.RIGHT.rotated(Vector3.UP, deg_to_rad(2.0 if tick % 2 == 0 else -2.0))
		player.face_toward(player.global_position + heading)
		await get_tree().physics_frame
	Input.action_release("move_forward")
	var crossed := player.global_position.x > 0.8 and player.global_position.y >= 800.13
	player.queue_free()
	await get_tree().physics_frame
	if not crossed:
		print("TEST FAIL: small held-input heading corrections repeatedly erased the lip-crossing stride")
	return crossed


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


func _airborne_turn() -> bool:
	_floor(Vector3(0.0, 899.5, 0.0), Vector3(20.0, 1.0, 20.0))
	_floor(Vector3(2.0, 900.07, 0.0), Vector3(4.0, 0.14, 20.0))
	_floor(Vector3(-0.7, 900.2, 3.0), Vector3(4.0, 0.4, 2.0))
	var player := AirBudgetPlayer.new()
	add_child(player)
	player.enable_step(0.24)
	player.global_position = Vector3(-0.45, 900.42, 2.7)
	player.face_toward(Vector3(-0.45, 900.4, 0.0))
	for _i in 6:
		await get_tree().physics_frame
	Input.action_press("move_forward")
	var walked_off := false
	for _i in 40:
		await get_tree().physics_frame
		if not player.is_on_floor() and not player.is_grounded():
			walked_off = true
			break
	Input.action_release("move_forward")
	if not walked_off:
		print("TEST FAIL: the air-budget fixture never walked off its platform")
		player.queue_free()
		return false
	# Fresh perpendicular input starts after actual support has been lost.
	# Count physical step travel, allowing full acceleration on every later
	# supported tick, including rounded-lip contacts the engine calls a wall.
	player.measuring = true
	Input.action_press("move_right")
	for _i in 35:
		await get_tree().physics_frame
	Input.action_release("move_right")
	var valid := player.unsupported_ticks > 0 and player.accepted_steps > 0
	valid = valid and player.greatest_excess <= 0.003
	print("AIR BUDGET: unsupported=%d accepted=%d excess=%.6f m" % [player.unsupported_ticks, player.accepted_steps, player.greatest_excess])
	player.queue_free()
	await get_tree().physics_frame
	if not valid:
		print("TEST FAIL: airborne acceleration became unearned grounded step travel")
	return valid


func _respawn_stride() -> bool:
	_floor(Vector3(0.0, 999.5, 0.0), Vector3(20.0, 1.0, 20.0))
	_floor(Vector3(2.0, 1000.07, 0.0), Vector3(4.0, 0.14, 20.0))
	var player := Player.new()
	add_child(player)
	player.enable_step(0.24)
	player.global_position = Vector3(-3.0, 1000.02, 0.0)
	player.face_toward(Vector3(2.0, 1000.0, 0.0))
	for _i in 6:
		await get_tree().physics_frame
	Input.action_press("move_forward")
	for _i in 18:
		await get_tree().physics_frame
	player.set_respawn_point(Vector3(-0.42, 1000.02, 0.0))
	player.respawn()
	var previous := player.global_position
	var greatest_excess := 0.0
	for tick in 12:
		await get_tree().physics_frame
		var travel := player.global_position - previous
		var speed := Vector2(travel.x, travel.z).length() / get_physics_process_delta_time()
		var allowed := minf(Player.WALK_SPEED, Player.ACCEL * (tick + 1) / Engine.physics_ticks_per_second)
		greatest_excess = maxf(greatest_excess, speed - allowed)
		previous = player.global_position
	Input.action_release("move_forward")
	player.queue_free()
	await get_tree().physics_frame
	if greatest_excess > 0.1:
		print("TEST FAIL: respawn spent stride history after resetting physical velocity")
		return false
	return true
