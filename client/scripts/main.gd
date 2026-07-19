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
## Set when legacy save recovery could not restore a stranded character. While
## true, ALL character-creator entry is locked (auto first-run AND the manual
## editor key): applying a new character would write the default save and orphan
## the stranded backup forever (no-resets law). Cleared only by a boot that
## recovers or needs no recovery.
var _save_blocked := false

func _ready() -> void:
	# Capture-harness entry for the EXPORTED client: the official export
	# template refuses positional scene paths (compiled with
	# disable_path_overrides), so CI's exported-client capture cannot launch
	# res://tools/frame_capture.tscn directly the way the editor run does — it
	# boots the shipped scene and redirects here instead. The current_scene
	# check makes the redirect one-shot: the capture tool instantiates this
	# scene itself under root WITHOUT making it the current scene, so the
	# capture-internal boot can never redirect back even though the variable
	# is still set. Players never take this branch — the variable is absent
	# outside the capture harness — and it runs before any world work begins.
	if OS.get_environment("WAR_CAPTURE") == "1" and get_tree().current_scene == self:
		# Input can arrive during the one deferred frame before the scene
		# swap, and this tree registers its InputMap actions only on the
		# normal boot path below (Player does it) — go inert rather than let
		# _unhandled_input query an action that was never registered.
		set_process_unhandled_input(false)
		get_tree().change_scene_to_file.call_deferred("res://tools/frame_capture.tscn")
		return
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
	# at a .test-backup and die before restoring it. Restore it before loading.
	if not CharacterStore.recover_legacy_backup():
		# A stranded character could not be moved back (e.g. a transient file
		# lock). Lock the creator entirely — opening it (auto OR via the editor
		# key) and applying would write a new default save and orphan the
		# stranded backup forever (no-resets law). Say so; the next launch
		# retries the recovery.
		_save_blocked = true
		_hud.toast("A saved character couldn't be restored — please restart. Your character is safe.")
	else:
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
	# Single chokepoint: while a stranded save is unrecovered, applying a new
	# character would overwrite the default and orphan it forever (no-resets
	# law) — refuse every entry, auto and manual editor-key alike.
	if _save_blocked:
		return
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
	# A low sun through ash is not a point source: give it a real angular size so
	# shadow edges soften with distance from the caster (a razor-sharp edge on
	# every rock is the tell of a default directional light). Parallel splits with
	# blending keep that softness stable as the wanderer walks, instead of popping
	# at each cascade boundary.
	sun.light_angular_distance = 1.6
	sun.shadow_blur = 1.2
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_max_distance = 180.0
	# Grazing light across a noisy heightfield is the classic acne case; bias
	# along the normal rather than raising depth bias, which would detach contact
	# shadows exactly where SSAO is trying to seat props on the ground.
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
	# SDFGI: sky ambient must not reach underground — cave systems get their
	# darkness from occlusion and their light from torches.
	env.sdfgi_enabled = true
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.05
	env.tonemap_white = 6.0

	# Contact occlusion. Without it nothing darkens where geometry meets
	# geometry, so props read as pasted onto the terrain rather than sitting in
	# it — the single biggest reason untextured shapes look flat. Kept tight
	# (small radius, moderate intensity) so it seats objects without painting
	# grey haloes; `light_affect` at 0 keeps direct sunlight clean and lets the
	# occlusion live in the ambient term where it belongs.
	env.ssao_enabled = true
	env.ssao_radius = 1.4
	env.ssao_intensity = 2.4
	env.ssao_power = 1.7
	env.ssao_detail = 0.6
	env.ssao_light_affect = 0.0
	env.ssao_ao_channel_affect = 0.35

	# Emissive bloom. The world is lit by embers — brazier flames and the cave
	# torches — and without glow they are merely orange pixels rather than things
	# giving off light. The HDR threshold is above 1.0 on purpose: only genuinely
	# over-bright emissive surfaces bloom, so the ashen mid-tones stay crisp
	# instead of the whole frame going soft (the usual over-bloom mistake).
	env.glow_enabled = true
	env.glow_normalized = true
	env.glow_intensity = 0.32
	env.glow_strength = 1.0
	env.glow_bloom = 0.05
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.glow_hdr_threshold = 1.45
	env.glow_hdr_scale = 2.0

	# Depth fog, now with a height falloff: ash does not hang at uniform density,
	# it pools in the hollows and thins as you climb. Aerial perspective bleeds
	# the fog colour into distant geometry so far ruins separate from near ones.
	env.fog_enabled = true
	env.fog_light_color = FOG_COLOR
	env.fog_light_energy = 0.9
	env.fog_sun_scatter = 0.06
	env.fog_density = 0.010
	env.fog_aerial_perspective = 0.35
	env.fog_sky_affect = 0.4
	env.fog_height = 6.0
	env.fog_height_density = 0.06

	# Volumetric fog is gated on a GPU capability probe. Godot's froxel
	# volumetrics need an R32_Uint atomic storage image, which some GPUs do not
	# support — the CI runner's virtualised Apple adapter reports "Format
	# 'R32_Uint' does not support usage as atomic storage image" and the frame
	# then fails to render at all. Where the device affirmatively supports the
	# format the Reach gets a real air volume (sun shafts through the ash);
	# everywhere else keeps the height-fog fallback above, which is broadly
	# supported and carries most of the visible gain anyway.
	var volumetrics_on := Volumetrics.probe()
	Volumetrics.apply(env, volumetrics_on)
	print("VOLUMETRICS %s" % (
		"on — R32_Uint atomic storage image supported" if volumetrics_on
		else "off — GPU lacks R32_Uint atomic storage image support"
	))

	# A restrained grading pass so the palette reads as a deliberate choice
	# rather than whatever the tonemapper returned: a little more contrast to
	# keep the ash from going milky, a little less saturation so the ember
	# highlights are the only truly warm thing in frame.
	env.adjustment_enabled = true
	env.adjustment_brightness = 1.0
	env.adjustment_contrast = 1.08
	env.adjustment_saturation = 0.94

	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	add_child(world_env)
