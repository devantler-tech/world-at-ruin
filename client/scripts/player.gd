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
## Full-deflection right-stick camera speed, radians per second. Applied per
## rendered frame (not per physics tick) so stick look stays smooth at any
## frame rate; the mouse path stays event-driven and untouched.
const STICK_LOOK_SPEED_YAW := 2.6
const STICK_LOOK_SPEED_PITCH := 1.6
## Deadzone for the actions, pinned explicitly (it equals Godot 4.7's
## add_action default) so stick feel survives an engine-default change: a
## deadzone near the 0.5 digital-press threshold would turn analog walking
## into a switch. Keys and buttons report strength 0 or 1, so the value only
## matters to the sticks.
const STICK_DEADZONE := 0.2

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

## Tallest ledge the body climbs in its stride, metres; 0 (the default) never
## steps. Only the raised exposed-stone preview turns it on (#548, through
## [method enable_step]): its slab lips stand 6–14 cm proud of the ash, and this
## capsule meets anything taller than about 12 cm as a WALL — its rounded base
## touches the lip beyond the 45° floor limit — so without a step 42% of the
## approaches `plate_crossing_sweep` measures stall at the lip. Off by default,
## so the ordinary game moves exactly as it always has (product law 2).
var step_height := 0.0
## A lifted path must rise at least this much, and get at least this much further
## than the plain slide, before it is taken — metres, so float noise on level
## ground can never turn an ordinary stride into a step.
const STEP_MIN_RISE := 0.001
const STEP_MIN_GAIN := 0.001
## How far a lifted path's landing must stand above the ground the body is on,
## carried forward to where it lands, before it counts as a ledge. A full stride
## up a plain slope lands higher than the ramped slide, but on that same slope; a
## lip's top stands clear of it. Small, because a body already riding up a lip's
## rounded edge stands partway up it, and a lip then clears the plane through it
## by only a few centimetres.
const STEP_MIN_LEDGE := 0.01
## Set by a jump and cleared on landing, so a body falling from a jump is never
## mistaken for one walking off a ledge.
var _jumped := false

var _cam_yaw: Node3D
var _spring: SpringArm3D
var _camera: Camera3D
var _visual: Node3D
var _character_body: Node3D
var _walk_locomotion: WalkLocomotion
var _placeholder: Array[Node] = []
var _embedded_ticks := 0

static func ensure_input_actions() -> void:
	var key_bindings := {
		"move_forward": [KEY_W, KEY_UP],
		"move_back": [KEY_S, KEY_DOWN],
		"move_left": [KEY_A, KEY_LEFT],
		"move_right": [KEY_D, KEY_RIGHT],
		"jump": [KEY_SPACE],
		"sprint": [KEY_SHIFT],
		"toggle_devlog": [KEY_F1, KEY_L],
		"character_editor": [KEY_C],
		"interact": [KEY_E],
		# Brings the full control set back after it has faded, and pins it there
		# (#271). Bound in every build, but only the HUD's contextual-hint mode
		# acts on it — with the hint bar permanent there is nothing to reveal.
		"toggle_hints": [KEY_H],
		# The look_* actions are gamepad-only: the mouse drives the camera
		# directly through InputEventMouseMotion, not through actions.
		"look_left": [],
		"look_right": [],
		"look_up": [],
		"look_down": [],
	}
	# The controller path Phase 1's exit gate requires: every player-facing
	# verb on a pad button…
	var joy_buttons := {
		"jump": JOY_BUTTON_A,
		"sprint": JOY_BUTTON_LEFT_STICK,
		"interact": JOY_BUTTON_X,
		"toggle_devlog": JOY_BUTTON_BACK,
		"character_editor": JOY_BUTTON_Y,
		"toggle_hints": JOY_BUTTON_RIGHT_SHOULDER,
	}
	# …and both sticks live: [axis, full-deflection sign] per direction.
	var joy_axes := {
		"move_left": [JOY_AXIS_LEFT_X, -1.0],
		"move_right": [JOY_AXIS_LEFT_X, 1.0],
		"move_forward": [JOY_AXIS_LEFT_Y, -1.0],
		"move_back": [JOY_AXIS_LEFT_Y, 1.0],
		"look_left": [JOY_AXIS_RIGHT_X, -1.0],
		"look_right": [JOY_AXIS_RIGHT_X, 1.0],
		"look_up": [JOY_AXIS_RIGHT_Y, -1.0],
		"look_down": [JOY_AXIS_RIGHT_Y, 1.0],
	}
	for action: String in key_bindings:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, STICK_DEADZONE)
		for key: Key in key_bindings[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)
		if joy_buttons.has(action):
			var joy := InputEventJoypadButton.new()
			joy.button_index = joy_buttons[action]
			InputMap.action_add_event(action, joy)
		if joy_axes.has(action):
			var spec: Array = joy_axes[action]
			var motion := InputEventJoypadMotion.new()
			motion.axis = spec[0]
			motion.axis_value = spec[1]
			InputMap.action_add_event(action, motion)

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
	var previous_idle_time := 0.0
	var has_previous_idle_time := false
	if _character_body != null:
		var previous_idle := _character_body.get_node_or_null("BreathingIdle") as BreathingIdle
		if previous_idle != null:
			previous_idle_time = previous_idle.current_time()
			has_previous_idle_time = true
	var body := CharacterFactory.build(recipe)
	if body == null:
		return
	# Detach before freeing. `queue_free` alone defers removal to the end of the
	# frame, so until that boundary Visual holds the outgoing body and the
	# placeholder beside the incoming one, and a walk over its children can
	# resolve the body that is on its way out. The delete queue is flushed
	# before the frame draws, so this never reached a rendered frame.
	for node in _placeholder:
		_visual.remove_child(node)
		node.queue_free()
	_placeholder.clear()
	if _character_body != null:
		_visual.remove_child(_character_body)
		_character_body.queue_free()
	body.rotation.y = PI  # The kit body faces +Z; the visual's forward is -Z.
	_visual.add_child(body)
	_character_body = body
	if has_previous_idle_time:
		var replacement_idle := body.get_node_or_null("BreathingIdle") as BreathingIdle
		if replacement_idle == null or not replacement_idle.synchronize_to(previous_idle_time):
			push_error("Player: replacement body could not preserve its live idle clock")
	if _walk_locomotion == null:
		_walk_locomotion = WalkLocomotion.new()
		_walk_locomotion.name = "WalkLocomotion"
		add_child(_walk_locomotion)
	_walk_locomotion.bind(body)

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

## Right-stick camera look, polled per rendered frame (a held stick generates
## no event stream, so the mouse path's event handler cannot serve it). Same
## clamps, same control_enabled gate as the mouse.
func _process(delta: float) -> void:
	if not control_enabled:
		return
	var look := Input.get_vector("look_left", "look_right", "look_up", "look_down")
	if look == Vector2.ZERO:
		return
	_cam_yaw.rotation.y -= look.x * STICK_LOOK_SPEED_YAW * delta
	_spring.rotation.x = clampf(_spring.rotation.x - look.y * STICK_LOOK_SPEED_PITCH * delta, PITCH_MIN, PITCH_MAX)

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
	if is_on_floor() and velocity.y <= 0.0:
		_jumped = false
	if not is_on_floor():
		velocity.y = maxf(velocity.y - GRAVITY * delta, -MAX_FALL_SPEED)
	elif control_enabled and Input.is_action_just_pressed("jump"):
		velocity.y = JUMP_VELOCITY
		_jumped = true

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

	var slide_from := global_transform
	# The stride the player is ASKING for, not the velocity left after the last
	# slide: a lip that stopped the body dead has zeroed that, and a step tried
	# with it would inch forward and never clear the edge.
	var intended := wish * target_speed
	var stepping := step_height > 0.0 and is_on_floor() and velocity.y <= 0.0
	var standing_on := get_floor_normal()
	move_and_slide()
	if stepping:
		_step_up(slide_from, intended, horizontal, standing_on)
	if _walk_locomotion != null:
		_walk_locomotion.advance_motion(
			Vector2(velocity.x, velocity.z).length(),
			is_grounded(),
			sprinting,
			delta,
			velocity.y)

	# Face the direction of travel.
	if horizontal.length() > 0.5:
		var target_yaw := atan2(-horizontal.x, -horizontal.z)
		_visual.rotation.y = lerp_angle(_visual.rotation.y, target_yaw, 10.0 * delta)

	# Sprint widens the view slightly.
	_camera.fov = lerpf(_camera.fov, 78.0 if sprinting else 70.0, 6.0 * delta)

	_unstick_from_ground()

	if global_position.y < FALL_LIMIT_Y:
		respawn()

## Climb ledges up to `height` metres in stride; 0 turns stepping off.
func enable_step(height: float) -> void:
	step_height = maxf(height, 0.0)


## Try this tick's travel a second way — lifted by [member step_height], moved
## as far as it goes, settled back down onto whatever is there — and keep that
## instead of the plain slide when it ends up HIGHER and FURTHER along the
## intended direction. That is what walking up a ledge looks like, and it holds
## however the body meets the lip: head-on, where the slide stops dead, or at an
## angle, where the slide glides along the edge at full speed and a "was I
## stopped?" trigger would never fire. A landing that is not floor, a lifted path
## that gets no further than the slide, or one that lands on the same slope the
## body is standing on ([constant STEP_MIN_LEDGE]) leaves the slide's result
## alone, so level ground and ordinary slopes move exactly as without a step.
## The last test is why a full stride up a hill is not taken for a ledge: it
## lands higher than the ramped slide, but no higher than the hill.
## [param ramped] is this tick's accelerated velocity from before the slide: an
## accepted step keeps it, so the stride goes on ramping instead of snapping to
## full speed.
func _step_up(from: Transform3D, intended: Vector3, ramped: Vector3, standing_on: Vector3) -> void:
	var motion := intended * get_physics_process_delta_time()
	var along := Vector2(motion.x, motion.z)
	if along.length() <= 0.0001:
		return
	along = along.normalized()
	var slid := global_position - from.origin
	var slid_progress := Vector2(slid.x, slid.z).dot(along)
	var lift := _test_motion(from, Vector3.UP * step_height)
	var raised := from.translated(lift[&"travel"])
	var over := raised.translated(_test_motion(raised, motion)[&"travel"])
	var drop := _test_motion(over, Vector3.DOWN * (step_height * 2.0))
	if not drop[&"hit"] or (drop[&"normal"] as Vector3).angle_to(Vector3.UP) > floor_max_angle:
		return
	var landed := over.translated(drop[&"travel"])
	var rise := landed.origin.y - from.origin.y
	if rise <= STEP_MIN_RISE or rise > step_height:
		return
	var stepped := landed.origin - from.origin
	if Vector2(stepped.x, stepped.z).dot(along) <= slid_progress + STEP_MIN_GAIN:
		return
	# Only a ledge: a full stride up a plain slope lands on the plane the body is
	# standing on, carried forward; a lip's top stands clear of it.
	if standing_on.y <= 0.0:
		return
	if rise + (standing_on.x * stepped.x + standing_on.z * stepped.z) / standing_on.y <= STEP_MIN_LEDGE:
		return
	global_transform = landed
	# The slide spent this tick's speed against the lip; the step carried the
	# body over it, so the stride continues at the speed it had built up.
	velocity.x = ramped.x
	velocity.z = ramped.z
	velocity.y = 0.0


## Whether the body is standing rather than in the air, for the gait. On the
## floor, or — only while stepping is on, and never after a jump — within a step
## of something solid below. Walking OFF a lip, the capsule's rounded base rolls
## over the edge for a few ticks; the engine files that contact as a wall and
## reports the body airborne, which would flip the gait into the jump pose for a
## drop of a few centimetres. With stepping off this is exactly
## `is_on_floor()`, so the ordinary game animates exactly as it always has.
func is_grounded() -> bool:
	if is_on_floor():
		return true
	if step_height <= 0.0 or _jumped or velocity.y > 0.0:
		return false
	return _test_motion(global_transform, Vector3.DOWN * step_height)[&"hit"]


## One sweep of this body's shape from `from` along `motion`: whether it hit,
## how far it got, and the surface it met.
func _test_motion(from: Transform3D, motion: Vector3) -> Dictionary:
	var params := PhysicsTestMotionParameters3D.new()
	params.from = from
	params.motion = motion
	params.margin = safe_margin
	var result := PhysicsTestMotionResult3D.new()
	var hit := PhysicsServer3D.body_test_motion(get_rid(), params, result)
	return {
		&"hit": hit,
		&"travel": result.get_travel() if hit else motion,
		&"normal": result.get_collision_normal() if hit else Vector3.UP,
	}


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
## Wardens' Shrine) calls this. The attunement itself persists in the save vault
## (SaveVault, #249); the Player stays storage-agnostic and is handed the point
## the live world re-derives for the attuned shrine.
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
