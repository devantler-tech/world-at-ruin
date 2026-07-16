extends Node3D
## Boots the Ashfall Reach slice: environment, world, wanderer, HUD.
##
## Everything is constructed in code from engine primitives — the "as code"
## premise means an agent can author any part of this world in a text diff.

const SUN_COLOR := Color(1.0, 0.72, 0.5)
const SKY_TOP := Color(0.23, 0.18, 0.22)
const SKY_HORIZON := Color(0.55, 0.35, 0.24)
const GROUND_BOTTOM := Color(0.1, 0.09, 0.09)
const FOG_COLOR := Color(0.35, 0.28, 0.24)

func _ready() -> void:
	_build_environment()
	var world := WorldGen.new()
	world.name = "World"
	add_child(world)

	var player := Player.new()
	player.name = "Wanderer"
	# Spawn outside the monolith ring, facing the shrine, so the first frame
	# frames the landmark instead of collapsing the camera against a stone.
	var spawn := Vector3(11.0, world.surface_height_at(11.0, 14.0) + 1.2, 14.0)
	player.spawn_point = spawn
	player.position = spawn
	player.ground_height_provider = world.surface_height_at
	add_child(player)
	player.face_toward(Vector3.ZERO)

	var hud := Hud.new()
	hud.name = "Hud"
	add_child(hud)
	player.respawned.connect(func() -> void:
		hud.toast("The Reach reclaims you. The shrine calls you back."))

func _build_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = SUN_COLOR
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	sun.rotation_degrees = Vector3(-19.0, 38.0, 0.0)
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
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = FOG_COLOR
	env.fog_density = 0.012
	env.fog_sky_affect = 0.4

	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	add_child(world_env)
