extends Node3D
## Motion evidence for #1639: the walk preview's terrain plant through the
## transitions that change, photographed side-on at ankle height, tick by tick.
##
## - `lip`: the walk crosses an 8 cm stone lip, so a swinging foot's ground
##   target steps by the lip's height.
## - `loss`: the walk leaves a slope that runs across the body for ground that
##   cannot be sampled (a cave floor), so the feet and pelvis fade back onto the
##   body's own plane.
## - `rock`: the body stands 0.2 m up on a flat rock over level terrain; the
##   tolerance now follows the floor under the body, so the feet stay on the
##   rock instead of planting on the terrain inside it.
##
## The body is driven by `WalkLocomotion` directly, moved along +X at the walk's
## own speed; the stage is bare boxes and planes. Evidence only: nothing ships.
##
## Run windowed: WAR_SHOT_DIR=<dir> godot --path client --resolution 1280x720
##   res://tools/plant_transition_capture.tscn

const RECIPE_PATH := "res://recipes/wanderer.json"
const DT := 1.0 / 60.0
const SPEED := 2.0
const LIP_HEIGHT := 0.08
const SLOPE := 0.27
const ROCK_HEIGHT := 0.2
const SETTLE_FRAMES := 3

var _camera: Camera3D
var _body: Node3D
var _holder: Node3D
var _animator: WalkLocomotion
var _props: Array[Node3D] = []


func _ready() -> void:
	var dir := OS.get_environment("WAR_SHOT_DIR")
	if dir.is_empty() or not DirAccess.dir_exists_absolute(dir):
		_fail("WAR_SHOT_DIR must name an existing directory")
		return
	OS.set_environment(WalkLocomotion.FLAG_ENV, "1")
	if not _stage():
		return
	for scenario: String in ["lip", "loss", "rock"]:
		if not await _run(scenario, dir):
			return
	print("CAPTURE PASS plant transitions")
	get_tree().quit(0)


func _run(scenario: String, dir: String) -> bool:
	for prop: Node3D in _props:
		prop.free()
	_props.clear()
	var start_x := -0.9
	var ticks := 54
	var moving := true
	var floor_y := 0.0
	match scenario:
		"lip":
			_add_box(Vector3(1.5, LIP_HEIGHT * 0.5, 0.0), Vector3(3.0, LIP_HEIGHT, 3.0))
			_animator.ground_height = func(x: float, _z: float) -> float:
				return LIP_HEIGHT if x >= 0.0 else 0.0
		"loss":
			var slope := MeshInstance3D.new()
			var plane := PlaneMesh.new()
			plane.size = Vector2(3.0, 3.0)
			slope.mesh = plane
			slope.position = Vector3(-1.5, 0.0, 0.0)
			slope.rotation.x = -atan(SLOPE)
			slope.material_override = _sand()
			add_child(slope)
			_props.append(slope)
			_add_box(Vector3(1.5, -0.01, 0.0), Vector3(3.0, 0.02, 3.0))
			_animator.ground_height = func(x: float, z: float) -> float:
				return SLOPE * z if x < 0.0 else NAN
		"rock":
			start_x = 0.0
			ticks = 30
			moving = false
			floor_y = ROCK_HEIGHT
			_add_box(Vector3(0.0, ROCK_HEIGHT * 0.5, 0.0), Vector3(1.2, ROCK_HEIGHT, 1.2))
			_animator.ground_height = func(_x: float, _z: float) -> float:
				return 0.0
	_animator.body_ground_tolerance = _tolerance()
	_holder.position = Vector3(start_x, floor_y, 0.0)
	_animator.bind(_body)
	var lines: Array[String] = []
	for tick in ticks:
		if moving:
			_holder.position.x += SPEED * DT
		_animator.advance_motion(SPEED if moving else 0.0, true, false, DT)
		if tick % 3 != 2:
			continue
		_camera.position = Vector3(_holder.position.x, floor_y + 0.35, 1.6)
		_camera.look_at(Vector3(_holder.position.x, floor_y + 0.25, 0.0), Vector3.UP)
		for _s in SETTLE_FRAMES:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var frame_name := "plant_%s_%02d" % [scenario, tick + 1]
		if get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, frame_name]) != OK:
			return _fail("could not write %s" % frame_name)
		lines.append("%s x=%.3f" % [frame_name, _holder.position.x])
	print("PLANT %s\n%s" % [scenario, "\n".join(lines)])
	return true


## The player's tolerance on level ground where the build has it, else the old
## steepest-floor ride the player used before #1639.
func _tolerance() -> float:
	var player := Player.new()
	var tolerance: float = (player.call("body_ground_tolerance_for", Vector3.UP)
		if player.has_method("body_ground_tolerance_for")
		else CaveSystemGen.BODY_RADIUS * (1.0 / cos(player.floor_max_angle) - 1.0) + Player.BODY_GROUND_MARGIN_M)
	player.free()
	return tolerance


func _stage() -> bool:
	var built := LocomotionTestSupport.recipe_body(RECIPE_PATH)
	if not built["problem"].is_empty():
		return _fail(built["problem"])
	_body = built["body"]
	# Walk along +X, side-on to the camera.
	_holder = Node3D.new()
	add_child(_holder)
	_holder.add_child(_body)
	_body.rotation.y = PI / 2.0
	_animator = WalkLocomotion.new()
	add_child(_animator)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40.0, 40.0)
	ground.mesh = plane
	ground.position.y = -0.002
	ground.material_override = _sand()
	add_child(ground)
	_light_stage()
	return true


## A low key light and a flat warm ambient: enough to read the feet against
## the stone and sand, nothing more.
func _light_stage() -> void:
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-45.0, 40.0, 0.0)
	add_child(key)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.45, 0.4, 0.38)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.55, 0.5)
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)
	_camera = Camera3D.new()
	add_child(_camera)
	_camera.current = true


func _add_box(at: Vector3, size: Vector3) -> void:
	var box := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	box.mesh = mesh
	box.position = at
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color(0.42, 0.4, 0.38)
	box.material_override = stone
	add_child(box)
	_props.append(box)


func _sand() -> StandardMaterial3D:
	var sand := StandardMaterial3D.new()
	sand.albedo_color = Color(0.55, 0.42, 0.3)
	return sand


func _fail(message: String) -> bool:
	print("CAPTURE FAIL — " + message)
	get_tree().quit(1)
	return false
