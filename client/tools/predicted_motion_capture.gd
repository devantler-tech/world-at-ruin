extends Node3D
## Motion evidence for #1461: the predicted wanderer stopping under the scripted
## zone of `predicted_body_test`, once with a three-tick round trip and once
## after a one-second zone stall, photographed side-on around the stop.
##
## The drawn position is the predicted body's own `display_position()`, frame by
## frame, exactly as `Player.apply_predicted` places the wanderer; the stage is
## a bare sand plane with a post where the zone finally stops the body, so the
## slide back after a stop reads against it. Evidence only: nothing here ships.
##
## Run windowed: WAR_SHOT_DIR=<dir> godot --path client --resolution 1280x720
##   res://tools/predicted_motion_capture.tscn

const Sim = preload("res://tests/predicted_body_test.gd")
const RECIPE_PATH := "res://recipes/wanderer.json"
const SETTLE_FRAMES := 4
const RUNS := [
	{"label": "delay", "args": [1, 2, 90, 60], "first": 56, "last": 84},
	{"label": "stall", "args": [1, 2, 150, 120, 50, 30], "first": 116, "last": 144},
]

var _camera: Camera3D
var _post: MeshInstance3D
var _body: Node3D


func _ready() -> void:
	var dir := OS.get_environment("WAR_SHOT_DIR")
	if dir.is_empty() or not DirAccess.dir_exists_absolute(dir):
		_fail("WAR_SHOT_DIR must name an existing directory")
		return
	if not _stage():
		return
	for run: Dictionary in RUNS:
		var drawn: Array[Vector3] = []
		var sim: Node = Sim.new()
		var args: Array = run["args"].duplicate()
		while args.size() < 8:
			args.append(-1 if args.size() % 2 == 0 else 0)
		args.append(func(_frame: int, body: PredictedBody) -> void:
			drawn.append(body.display_position() if body.is_active() else Vector3.ZERO))
		sim.callv("_simulate", args)
		sim.free()
		var stop: Vector3 = drawn[-1]
		_post.position = Vector3(stop.x, 0.6, -0.35)
		_camera.position = Vector3(stop.x - 0.6, 0.9, 4.2)
		_camera.look_at(Vector3(stop.x - 0.6, 0.8, 0.0), Vector3.UP)
		var lines: Array[String] = []
		for frame in range(int(run["first"]), int(run["last"]) + 1, 2):
			_body.position = Vector3(drawn[frame].x, 0.0, drawn[frame].z)
			for _s in SETTLE_FRAMES:
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var frame_name := "predicted_%s_%03d" % [run["label"], frame]
			if img.save_png("%s/%s.png" % [dir, frame_name]) != OK:
				_fail("could not write %s" % frame_name)
				return
			lines.append("%s x=%.3f m (stop %.3f m)" % [frame_name, drawn[frame].x, stop.x])
		print("PREDICTED MOTION %s\n%s" % [run["label"], "\n".join(lines)])
	print("CAPTURE PASS predicted motion")
	get_tree().quit(0)


func _stage() -> bool:
	var built := LocomotionTestSupport.recipe_body(RECIPE_PATH)
	if not built["problem"].is_empty():
		return _fail(built["problem"])
	_body = built["body"]
	add_child(_body)
	# Turned toward the camera so the whole body reads against the post.
	_body.rotation.y = -PI / 2.0
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(60.0, 60.0)
	ground.mesh = plane
	var sand := StandardMaterial3D.new()
	sand.albedo_color = Color(0.55, 0.42, 0.3)
	ground.material_override = sand
	add_child(ground)
	_post = MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.03
	cylinder.bottom_radius = 0.03
	cylinder.height = 1.2
	_post.mesh = cylinder
	add_child(_post)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	add_child(sun)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.45, 0.4, 0.38)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(0.6, 0.55, 0.5)
	add_child(environment)
	_camera = Camera3D.new()
	add_child(_camera)
	_camera.current = true
	return true


func _fail(message: String) -> bool:
	print("CAPTURE FAIL — " + message)
	get_tree().quit(1)
	return false
