class_name Player
extends CharacterBody3D
## The wanderer: a placeholder-body third-person controller.
##
## The body is a capsule on purpose — the real character comes from the
## Phase-0 art pipeline (MPFB2 via headless Blender), which is a maintainer
## taste gate. Movement feel, camera, and respawn plumbing live here and
## survive that swap.

const WALK_SPEED := 6.0
const SPRINT_SPEED := 10.5
const ACCEL := 42.0
const AIR_CONTROL := 0.25
const JUMP_VELOCITY := 7.2
const GRAVITY := 19.6
## Terminal velocity, kept under capsule_radius (0.4 m) × physics rate (60 Hz)
## so a falling capsule can never advance a full radius in one tick and tunnel
## into the terrain trimesh.
const MAX_FALL_SPEED := 20.0
const MOUSE_SENS := 0.0028
const PITCH_MIN := -1.1
const PITCH_MAX := 0.5
const FALL_LIMIT_Y := -40.0

var spawn_point := Vector3.ZERO
## Analytic terrain height lookup (set by main.gd to WorldGen.height_at). The
## terrain is a pure heightfield, so a body below it is always an invalid
## physics state — used to self-heal embedding/tunneling instead of wedging.
var ground_height_provider: Callable
## False while the character creator owns the screen: movement input and
## mouse capture are ignored, but gravity, sliding and the anti-embed
## safety net keep running (the body must stay honest while being reshaped).
var control_enabled := true
## Where being below the heightfield is legitimate (inside cave systems) —
## set by main.gd to WorldGen.cave_protects; the anti-embed net stands down.
var underground_provider: Callable
## Emitted when the world reclaims the wanderer (for HUD flavour text).
signal respawned

var _cam_yaw: Node3D
var _spring: SpringArm3D
var _camera: Camera3D
var _visual: Node3D
var _character_body: Node3D
var _placeholder: Array[Node] = []
var _embedded_ticks := 0

static func ensure_input_actions() -> void:
	var bindings := {
		"move_forward": [KEY_W, KEY_UP],
		"move_back": [KEY_S, KEY_DOWN],
		"move_left": [KEY_A, KEY_LEFT],
		"move_right": [KEY_D, KEY_RIGHT],
		"jump": [KEY_SPACE],
		"sprint": [KEY_SHIFT],
		"toggle_devlog": [KEY_F1, KEY_L],
		"character_editor": [KEY_C],
		"interact": [KEY_E],
	}
	for action: String in bindings:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
			for key: Key in bindings[action]:
				var ev := InputEventKey.new()
				ev.physical_keycode = key
				InputMap.action_add_event(action, ev)
			# The interaction verb is also on a gamepad face button — the
			# controller path Phase 1 needs. Movement on the sticks is a
			# later slice; reserving the one button now is cheap.
			if action == "interact":
				var joy := InputEventJoypadButton.new()
				joy.button_index = JOY_BUTTON_X
				InputMap.action_add_event(action, joy)

func _ready() -> void:
	ensure_input_actions()
	_build_body()
	_build_camera_rig()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _build_body() -> void:
	var col := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	col.shape = capsule
	col.position.y = 0.9
	add_child(col)

	_visual = Node3D.new()
	_visual.name = "Visual"
	add_child(_visual)

	var body_mesh := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.4
	cap.height = 1.8
	body_mesh.mesh = cap
	body_mesh.position.y = 0.9
	var cloth := StandardMaterial3D.new()
	cloth.albedo_color = Color(0.45, 0.38, 0.3)
	cloth.roughness = 0.85
	body_mesh.set_surface_override_material(0, cloth)
	_visual.add_child(body_mesh)
	_placeholder.append(body_mesh)

	# A hood/visor block so facing reads at a glance.
	var visor := MeshInstance3D.new()
	var visor_mesh := BoxMesh.new()
	visor_mesh.size = Vector3(0.28, 0.12, 0.18)
	visor.mesh = visor_mesh
	visor.position = Vector3(0, 1.45, -0.33)
	var visor_mat := StandardMaterial3D.new()
	visor_mat.albedo_color = Color(0.95, 0.6, 0.25)
	visor_mat.emission_enabled = true
	visor_mat.emission = Color(0.95, 0.55, 0.2)
	visor_mat.emission_energy_multiplier = 0.6
	visor.set_surface_override_material(0, visor_mat)
	_visual.add_child(visor)
	_placeholder.append(visor)

## Dress the wanderer in a recipe-built body (the capsule placeholder goes
## away the moment a real character exists). Collision stays the capsule —
## physics never depends on the body's shape (product law: capsules only).
func set_character(recipe: Dictionary) -> void:
	var body := CharacterFactory.build(recipe)
	if body == null:
		return
	for node in _placeholder:
		node.queue_free()
	_placeholder.clear()
	if _character_body != null:
		_character_body.queue_free()
	body.rotation.y = PI  # The kit body faces +Z; the visual's forward is -Z.
	_visual.add_child(body)
	_character_body = body

## The current body's skinned mesh — the character creator drives blend-shape
## weights on it live while sliders move.
func character_mesh() -> MeshInstance3D:
	if _character_body == null:
		return null
	return CharacterFactory.find_skinned_mesh(CharacterFactory.find_skeleton(_character_body))

func _build_camera_rig() -> void:
	_cam_yaw = Node3D.new()
	_cam_yaw.name = "CamYaw"
	_cam_yaw.position.y = 1.55
	add_child(_cam_yaw)

	_spring = SpringArm3D.new()
	_spring.spring_length = 4.6
	_spring.margin = 0.25
	_spring.rotation.x = -0.28
	_spring.add_excluded_object(get_rid())
	_cam_yaw.add_child(_spring)

	_camera = Camera3D.new()
	_camera.fov = 70.0
	_camera.far = 400.0
	_spring.add_child(_camera)
	_camera.make_current()

func _unhandled_input(event: InputEvent) -> void:
	if not control_enabled:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		_cam_yaw.rotation.y -= motion.relative.x * MOUSE_SENS
		_spring.rotation.x = clampf(_spring.rotation.x - motion.relative.y * MOUSE_SENS, PITCH_MIN, PITCH_MAX)
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.is_pressed() and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y = maxf(velocity.y - GRAVITY * delta, -MAX_FALL_SPEED)
	elif control_enabled and Input.is_action_just_pressed("jump"):
		velocity.y = JUMP_VELOCITY

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back") \
		if control_enabled else Vector2.ZERO
	var basis := _cam_yaw.global_transform.basis
	var wish := (basis.x * input_dir.x + basis.z * input_dir.y)
	wish.y = 0.0
	wish = wish.normalized() * input_dir.length()

	# No floor check: sprint momentum carries through jumps instead of the
	# target speed braking to walk mid-air.
	var sprinting := Input.is_action_pressed("sprint") and wish.length() > 0.1
	var target_speed := SPRINT_SPEED if sprinting else WALK_SPEED
	var control := 1.0 if is_on_floor() else AIR_CONTROL
	var horizontal := Vector3(velocity.x, 0, velocity.z)
	horizontal = horizontal.move_toward(wish * target_speed, ACCEL * control * delta)
	velocity.x = horizontal.x
	velocity.z = horizontal.z

	move_and_slide()

	# Face the direction of travel.
	if horizontal.length() > 0.5:
		var target_yaw := atan2(-horizontal.x, -horizontal.z)
		_visual.rotation.y = lerp_angle(_visual.rotation.y, target_yaw, 10.0 * delta)

	# Sprint widens the view slightly.
	_camera.fov = lerpf(_camera.fov, 78.0 if sprinting else 70.0, 6.0 * delta)

	_unstick_from_ground()

	if global_position.y < FALL_LIMIT_Y:
		respawn()

## How far below the vertical surface height the origin must sit before we
## call it embedded. On a slope of angle θ the capsule's bottom tip
## legitimately sits r·(1 − cos2θ/cosθ) below the surface measured at its
## (x, z) — ≈ 0.4 m at 45° for r = 0.4 — so anything under that is normal
## contact, not embedding. A genuinely wedged/tunneled capsule is far deeper.
const EMBED_THRESHOLD := 0.55
## Sentinel from WorldGen.surface_height_at: no terrain at this (x, z).
const NO_GROUND_BELOW := -1.0e5
## Embedding must persist this many consecutive physics ticks before the
## clamp fires (~0.17 s at 60 Hz). Real wedging is a steady state; legitimate
## contact depth fluctuates tick to tick (ridge overhangs, crease crossings),
## so a persistence gate removes false positives no fixed threshold can.
const EMBED_TICKS_TO_FIRE := 10

## Self-heal terrain embedding: the terrain is a pure heightfield, so an
## origin deeper than EMBED_THRESHOLD below the walkable mesh surface is
## always an invalid state (tunneled or wedged) — pop back onto the surface.
## Must compare against the MESH surface (piecewise-linear), never the smooth
## noise height: mid-triangle they diverge enough to false-positive.
func _unstick_from_ground() -> void:
	if not ground_height_provider.is_valid():
		return
	if underground_provider.is_valid() and underground_provider.call(global_position.x, global_position.z):
		_embedded_ticks = 0
		return  # Inside a cave system: below-the-heightfield is the point.
	var ground: float = ground_height_provider.call(global_position.x, global_position.z)
	if ground < NO_GROUND_BELOW:
		_embedded_ticks = 0
		return  # Off the terrain edge — the fall-limit respawn handles this.
	if global_position.y < ground - EMBED_THRESHOLD:
		_embedded_ticks += 1
	else:
		_embedded_ticks = 0
		return
	if _embedded_ticks < EMBED_TICKS_TO_FIRE:
		return
	print("[unstick] recovered wanderer from y=%.2f to surface %.2f at (%.1f, %.1f)" %
		[global_position.y, ground, global_position.x, global_position.z])
	global_position.y = ground + 0.1
	velocity.y = 0.0
	_embedded_ticks = 0

func respawn() -> void:
	global_position = spawn_point
	velocity = Vector3.ZERO
	face_toward(Vector3.ZERO)
	respawned.emit()

## Move where the wanderer wakes after a fall — attuning a respawn point (the
## Wardens' Shrine) calls this. Until the save vault is sealed this lasts the
## session; persistence rides on the forward-only save guard (#3).
func set_respawn_point(point: Vector3) -> void:
	spawn_point = point

## The direction the wanderer is aiming, flattened to the ground plane — the
## camera's look direction. The interaction controller uses it to decide what
## the wanderer is facing.
func aim_forward() -> Vector3:
	var source := _cam_yaw if _cam_yaw != null else self
	var f := -source.global_transform.basis.z
	f.y = 0.0
	return f.normalized() if f.length() > 0.0001 else Vector3(0, 0, -1)

## Point the camera (and body) toward a world position — used at spawn so the
## opening frame shows the shrine.
func face_toward(target: Vector3) -> void:
	var dir := target - global_position
	dir.y = 0.0
	if dir.length() < 0.01:
		return
	dir = dir.normalized()
	var yaw := atan2(-dir.x, -dir.z)
	_cam_yaw.rotation.y = yaw
	_visual.rotation.y = yaw
