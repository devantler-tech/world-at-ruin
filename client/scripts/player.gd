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
## Emitted when the world reclaims the wanderer (for HUD flavour text).
signal respawned

var _cam_yaw: Node3D
var _spring: SpringArm3D
var _camera: Camera3D
var _visual: Node3D

static func ensure_input_actions() -> void:
	var bindings := {
		"move_forward": [KEY_W, KEY_UP],
		"move_back": [KEY_S, KEY_DOWN],
		"move_left": [KEY_A, KEY_LEFT],
		"move_right": [KEY_D, KEY_RIGHT],
		"jump": [KEY_SPACE],
		"sprint": [KEY_SHIFT],
		"toggle_devlog": [KEY_F1, KEY_L],
	}
	for action: String in bindings:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
			for key: Key in bindings[action]:
				var ev := InputEventKey.new()
				ev.physical_keycode = key
				InputMap.action_add_event(action, ev)

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
	elif Input.is_action_just_pressed("jump"):
		velocity.y = JUMP_VELOCITY

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var basis := _cam_yaw.global_transform.basis
	var wish := (basis.x * input_dir.x + basis.z * input_dir.y)
	wish.y = 0.0
	wish = wish.normalized() * input_dir.length()

	var sprinting := Input.is_action_pressed("sprint") and is_on_floor() and wish.length() > 0.1
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

## Self-heal terrain embedding: the body origin sits at the capsule's base, so
## an origin meaningfully below the analytic terrain height means the capsule
## is inside the ground (tunneled or wedged) — pop it back onto the surface.
func _unstick_from_ground() -> void:
	if not ground_height_provider.is_valid():
		return
	var ground: float = ground_height_provider.call(global_position.x, global_position.z)
	if global_position.y < ground - 0.2:
		global_position.y = ground + 0.3
		velocity.y = 0.0

func respawn() -> void:
	global_position = spawn_point
	velocity = Vector3.ZERO
	face_toward(Vector3.ZERO)
	respawned.emit()

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
