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

var _player: Player
var _hud: Hud
var _creator: CharacterCreator
var _interaction: InteractionController

func _ready() -> void:
	_build_environment()
	var world := WorldGen.new()
	world.name = "World"
	add_child(world)

	_player = Player.new()
	_player.name = "Wanderer"
	# Every wanderer wakes in the starter cave — part of the open world, so
	# walking out of the mouth into the Reach is seamless (no loading screen).
	var spawn := world.cave_spawn_point()
	_player.spawn_point = spawn
	_player.position = spawn
	_player.ground_height_provider = world.surface_height_at
	_player.underground_provider = world.cave_protects
	add_child(_player)
	# The mouth faces the shrine, so facing the shrine faces the light.
	_player.face_toward(Vector3.ZERO)

	# The Reach is inhabited: a seeded settlement rings the shrine and lone
	# drifters dot the open land — the same people in the same places every
	# boot (stage 6 of the character system).
	var npcs := NpcSpawner.new()
	npcs.name = "Npcs"
	add_child(npcs)
	npcs.populate(world)

	# The first non-humanoid life: a seeded pack of ash hounds haunts the wild
	# edges of the Reach (creature system pilot). Same seed, same pack, every
	# boot — they cannot hunt yet; today they watch the treeline.
	var hounds := CreatureSpawner.new()
	hounds.name = "Creatures"
	add_child(hounds)
	hounds.populate(world)

	_hud = Hud.new()
	_hud.name = "Hud"
	add_child(_hud)
	_player.respawned.connect(func() -> void:
		_hud.toast("The Reach reclaims you. You wake again in the dark."))

	# The one interaction verb: look at something near, press E, act on it.
	_interaction = InteractionController.new()
	_interaction.name = "Interaction"
	_interaction.player = _player
	_interaction.hud = _hud
	add_child(_interaction)

	# Attuning the shrine makes it the wanderer's respawn point (settled death
	# design: wake at the nearest attuned point). World stays Player-agnostic;
	# the effect is wired here. Session-only until the save vault is sealed (#3).
	world.shrine_interactable().interacted.connect(func(_by: Node) -> void:
		_player.set_respawn_point(world.shrine_respawn_point())
		_hud.toast("The Wardens' flame knows you now. The Reach will return you here."))

	# The people speak: a person's seeded line surfaces as a toast.
	npcs.npc_spoke.connect(func(npc_name: String, line: String) -> void:
		_hud.toast("%s:  “%s”" % [npc_name, line]))

	# One-time migration: an older client's boot test could strand the real save
	# at a .test-backup and die before restoring it. Put it back before loading.
	CharacterStore.recover_legacy_backup()
	var saved = CharacterStore.load_saved()
	if saved is Dictionary:
		_player.set_character(saved)
	else:
		# First time in the world: shape a character before setting out.
		_open_creator.call_deferred(true)

	# The smoke boot's POSITIVE marker: CI greps for this line, not merely
	# for the absence of errors — a boot that never mounted the project must
	# fail the check, not slip past it (the silent-no-op incident, 0.1.12).
	print("BOOT_OK v%s — world built, %d people and %d hounds in the Reach" % [
		DevLog.VERSION, npcs.npc_names.size(), hounds.creature_names.size()])

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("character_editor") and _creator == null:
		_open_creator(false)
		get_viewport().set_input_as_handled()

func _open_creator(first_run: bool) -> void:
	var initial = CharacterStore.load_saved()
	if initial is not Dictionary:
		initial = CharacterFactory.load_recipe("res://recipes/wanderer.json")
		if initial is Dictionary:
			initial.erase("comment")
		else:
			initial = { "version": 1 }
	_creator = CharacterCreator.new()
	add_child(_creator)
	_creator.applied.connect(func(recipe: Dictionary) -> void:
		CharacterStore.save_recipe(recipe)
		_player.set_character(recipe)
		_hud.toast("The body remembers its new shape." if not first_run
			else "You wake in the dark. Embers, and a mouth of light ahead."))
	_creator.closed.connect(func() -> void: _creator = null)
	_creator.open(_player, initial, first_run)

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
	# SDFGI: sky ambient must not reach underground — cave systems get their
	# darkness from occlusion and their light from torches.
	env.sdfgi_enabled = true
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = FOG_COLOR
	env.fog_density = 0.012
	env.fog_sky_affect = 0.4

	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	add_child(world_env)
