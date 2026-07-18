extends Node3D
## Telegraph readability preview harness — an EDITOR SURFACE, deliberately
## unreferenced by the running game (the `recipes.tscn` / `cave.tscn`
## pattern; listed in AGENTS.md ## Maintenance). Retire it only when the
## combat readability work it supports is finished.
##
## "Telegraphs must read against the ground at a glance" is an art
## constraint judged by eye in the REAL lighting, never a headless
## assertion — so this scene rebuilds the shipping overworld light rig
## (sun/sky/environment values mirrored from `main.gd::_build_environment`;
## if that rig changes, re-copy it — a preview under different light judges
## nothing) over a noisy ashen ground, and loops a circle cast and a cone
## cast side by side with a player-height capsule for scale.
##
## Run windowed:  godot --path client res://scenes/telegraph.tscn
##   V — toggle side vantage / into-the-sun vantage (regressions hide in the
##       vantage you did not check; judge BOTH).
##
## Evidence mode: set WAR_PREVIEW_SHOTS to a writable directory and the
## harness saves one mid-cast frame per vantage (telegraph-side.png,
## telegraph-sun.png) and quits — the capture-both-vantages rule from the
## atmosphere work, automated so a judgement always has frames. Needs a real
## renderer (a windowed run); --headless renders nothing to capture.

const GROUND_SIZE := 60.0
const GROUND_STEPS := 48
const GROUND_NOISE_AMP := 1.2
const CIRCLE_CENTRE := Vector3(-5.0, 0.0, 0.0)
const CIRCLE_RADIUS := 3.5
const CIRCLE_TIME := 2.2
const CONE_APEX := Vector3(3.0, 0.0, 2.0)
const CONE_FACING := Vector3(0.6, 0.0, -1.0)
const CONE_RANGE := 9.0
const CONE_HALF_DEG := 35.0
const CONE_TIME := 1.8

# Mirrored from main.gd (the shipping overworld palette).
const SUN_COLOR := Color(1.0, 0.72, 0.5)
const SKY_TOP := Color(0.23, 0.18, 0.22)
const SKY_HORIZON := Color(0.55, 0.35, 0.24)
const GROUND_BOTTOM := Color(0.1, 0.09, 0.09)
const FOG_COLOR := Color(0.35, 0.28, 0.24)

var _circle_runtime: TelegraphRuntime
var _cone_runtime: TelegraphRuntime
var _side_cam: Camera3D
var _sun_cam: Camera3D
var _shots_dir := ""
var _clock := 0.0
var _shot_side_done := false
var _shot_sun_done := false


func _ready() -> void:
	_build_ground()
	_build_lighting()
	_build_cameras()
	_build_scale_marker()
	_shots_dir = OS.get_environment("WAR_PREVIEW_SHOTS")
	# Evidence mode must fail LOUD: a headless run renders nothing, and a
	# silent save failure would let automation report a two-vantage evidence
	# run that produced no usable frames.
	if not _shots_dir.is_empty() and DisplayServer.get_name() == "headless":
		push_error("telegraph_preview: WAR_PREVIEW_SHOTS needs a real renderer — run windowed, not --headless")
		get_tree().quit(1)
		return
	print("telegraph_preview: V toggles side / into-the-sun vantage")


func _process(delta: float) -> void:
	# Loop the casts forever: each runtime frees itself after resolving.
	if not is_instance_valid(_circle_runtime):
		_circle_runtime = _spawn(TelegraphCast.circle(CIRCLE_CENTRE, CIRCLE_RADIUS, CIRCLE_TIME))
	if not is_instance_valid(_cone_runtime):
		_cone_runtime = _spawn(TelegraphCast.cone(CONE_APEX, CONE_FACING, CONE_RANGE,
				Telegraph.cos_half_scaled_from_deg(CONE_HALF_DEG), CONE_TIME))
	if _shots_dir.is_empty():
		return
	# Evidence mode: both mid-cast shots (fills well grown, border up), then quit.
	_clock += delta
	if not _shot_side_done and _clock >= 1.5:
		_shot_side_done = true
		_save_shot("telegraph-side.png")
		_side_cam.current = false
		_sun_cam.current = true
	elif not _shot_sun_done and _clock >= 1.7:
		_shot_sun_done = true
		_save_shot("telegraph-sun.png")
		get_tree().quit(0)


func _save_shot(file_name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var path := _shots_dir.path_join(file_name)
	if img == null or img.is_empty():
		push_error("telegraph_preview: viewport gave no image for %s — evidence run failed" % file_name)
		get_tree().quit(1)
		return
	var err := img.save_png(path)
	if err != OK:
		push_error("telegraph_preview: could not save %s (error %d) — evidence run failed" % [path, err])
		get_tree().quit(1)
		return
	print("telegraph_preview: shot %s -> %s" % [file_name, path])


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_V:
		var to_sun := _side_cam.current
		_sun_cam.current = to_sun
		_side_cam.current = not to_sun
		print("telegraph_preview: vantage = %s" % ("into-the-sun" if to_sun else "side"))


func _spawn(cast: TelegraphCast) -> TelegraphRuntime:
	var runtime := TelegraphRuntime.new()
	add_child(runtime)
	if not runtime.begin(cast):
		push_error("telegraph_preview: a preview cast was refused")
	return runtime


## Gently rolling ashen ground, deterministic (fixed seed), so the decals
## demonstrate slope projection rather than a flat-quad best case.
func _build_ground() -> void:
	var noise := FastNoiseLite.new()
	noise.seed = 7
	noise.frequency = 0.045
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var step := GROUND_SIZE / float(GROUND_STEPS)
	var half := GROUND_SIZE * 0.5
	for j in GROUND_STEPS:
		for i in GROUND_STEPS:
			var x0 := -half + float(i) * step
			var z0 := -half + float(j) * step
			var quad: Array[Vector3] = []
			for off: Vector2 in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1),
					Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)]:
				var x := x0 + off.x * step
				var z := z0 + off.y * step
				quad.append(Vector3(x, noise.get_noise_2d(x, z) * GROUND_NOISE_AMP, z))
			for v in quad:
				st.add_vertex(v)
	st.generate_normals()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.23, 0.20, 0.18)
	mat.roughness = 1.0
	var mesh := st.commit()
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = "Ground"
	mi.mesh = mesh
	add_child(mi)


## The shipping overworld light rig, mirrored from main.gd so the judgement
## happens under the light the player actually gets.
func _build_lighting() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = SUN_COLOR
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	sun.rotation_degrees = Vector3(-19.0, 38.0, 0.0)
	sun.light_angular_distance = 1.6
	sun.shadow_blur = 1.2
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_max_distance = 180.0
	sun.shadow_normal_bias = 1.5
	add_child(sun)

	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = SKY_TOP
	sky_mat.sky_horizon_color = SKY_HORIZON
	sky_mat.ground_bottom_color = GROUND_BOTTOM
	sky_mat.ground_horizon_color = SKY_HORIZON
	sky_mat.sun_angle_max = 40.0
	var sky := Sky.new()
	sky.sky_material = sky_mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.sdfgi_enabled = true
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.05
	env.tonemap_white = 6.0
	env.ssao_enabled = true
	env.ssao_radius = 1.4
	env.ssao_intensity = 2.4
	env.ssao_power = 1.7
	env.ssao_detail = 0.6
	env.ssao_light_affect = 0.0
	env.ssao_ao_channel_affect = 0.35
	env.glow_enabled = true
	env.glow_normalized = true
	env.glow_intensity = 0.32
	env.glow_strength = 1.0
	env.glow_bloom = 0.05
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.glow_hdr_threshold = 1.45
	env.glow_hdr_scale = 2.0
	env.fog_enabled = true
	env.fog_light_color = FOG_COLOR
	env.fog_light_energy = 0.9
	env.fog_sun_scatter = 0.06
	env.fog_density = 0.010
	env.fog_aerial_perspective = 0.35
	env.fog_sky_affect = 0.4
	env.fog_height = 6.0
	env.fog_height_density = 0.06
	# The grading pass is part of the shipping look too — judging telegraph
	# contrast without it grades under a different image than players get
	# (its omission here was a real review catch).
	env.adjustment_enabled = true
	env.adjustment_brightness = 1.0
	env.adjustment_contrast = 1.08
	env.adjustment_saturation = 0.94
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)


func _build_cameras() -> void:
	# Side vantage: the third-person gameplay read — over-shoulder height,
	# looking across both casts.
	_side_cam = Camera3D.new()
	_side_cam.name = "SideCam"
	add_child(_side_cam)
	_side_cam.global_position = Vector3(11.0, 7.0, 13.0)
	_side_cam.look_at(Vector3(-1.0, 0.0, 0.0))
	_side_cam.current = true

	# Into-the-sun vantage: the hard case — the sun sits at yaw 38°, so look
	# from the opposite azimuth THROUGH the casts toward it. Single-angle
	# judgement ships regressions; always check this one too.
	_sun_cam = Camera3D.new()
	_sun_cam.name = "SunCam"
	add_child(_sun_cam)
	_sun_cam.global_position = Vector3(8.0, 4.5, -14.0)
	_sun_cam.look_at(Vector3(-2.0, 0.5, 4.0))
	_sun_cam.current = false


## A wanderer-height capsule beside the casts: readability is judged at the
## scale a player occupies, not in the abstract.
func _build_scale_marker() -> void:
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.33, 0.30)
	capsule.material = mat
	var mi := MeshInstance3D.new()
	mi.name = "ScaleMarker"
	mi.mesh = capsule
	add_child(mi)
	mi.global_position = Vector3(-1.0, 0.9, -2.0)
