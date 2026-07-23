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
## Stable save-vault ids. Renaming either strands a shipped discovery forever;
## the boot test and immutable v2 golden fixture therefore pin these spellings.
const DISCOVERY_STARTER_CAVE := SaveVault.DISCOVERY_STARTER_CAVE
const DISCOVERY_WARDENS_SHRINE := SaveVault.DISCOVERY_WARDENS_SHRINE
const STARTER_CAVE_DISCOVERY_RADIUS := 10.0

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
## Whether this device's GPU can render froxel volumetrics (#158). Decided in
## [method _build_environment] and read again once the world exists, because
## the ash pools of #211 are only worth building where the volume they thicken
## actually renders.
var _volumetrics_on := false
## The ash pools placed in this world's hollows (#211), in placement order.
## Recorded even where volumetrics are off — a FogVolume contributes no
## readable pixels under `--headless`, so this list is the only headless-
## verifiable record of where the air was thickened (the foliage lesson).
var _hollow_fog: Array[Dictionary] = []
## The built pool nodes, index-aligned with [member _hollow_fog], and empty
## wherever the pools were placed but not built. Held so [method _process] can
## drift them (#233) without searching the tree every frame.
var _hollow_fog_volumes: Array[FogVolume] = []
## Seconds this world's ash has been drifting for. Accumulated from frame deltas
## rather than read off a clock, so drift is a function of how long the world
## has been running and not of when it happened to be launched — which keeps a
## capture taken at a given world-time reproducible.
var _hollow_fog_time := 0.0
## The live replication link, or null when no zone was named (#244).
var _zone: ZoneConnection = null
## Whether a lost connection has already been reported, so a failure that
## persists is not warned about on every frame.
var _zone_failure_reported := false
## Whether the link ever reached LIVE. A clean close is only worth reporting
## once it has: before that, the close IS the failure and is already reported
## under its own error class.
var _zone_was_live := false
## Draws the replicated entity table (#248), or null when no zone was named.
## Parented under THIS node and never under WorldGen: that subtree is
## fingerprinted by `world_gen_determinism_test` and additionally scanned for
## ruin sites, so a marker there would move the world golden whenever somebody
## connected.
var _replicas: ReplicaView = null
## The boot-owned exploration state. Vault-v2 names are restored here even when
## this rollback build does not register or act on a future place yet, and the
## two shipped places are observed into the append-only vault as the wanderer
## reaches them.
var _discovery := Discovery.new()

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

	# Recovery memory FIRST, before any world work: a marker left by the previous
	# launch must be acted on before this launch does anything that could itself
	# fail (#301).
	_reconcile_boot_recovery()

	_build_environment()
	var world := WorldGen.new()
	world.name = "World"
	add_child(world)
	_build_hollow_fog(world)

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
	# Save only stable semantic ids, never generated coordinates: both places
	# can move when world generation evolves without invalidating progression.
	_discovery.add(DISCOVERY_STARTER_CAVE, world.cave_spawn_point(),
		STARTER_CAVE_DISCOVERY_RADIUS)
	_discovery.add(DISCOVERY_WARDENS_SHRINE, world.shrine_interactable().global_position,
		WorldGen.SHRINE_CLEAR_RADIUS)

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
	# the effect is wired here. The attunement now PERSISTS through the save
	# vault (#249): what is stored is the shrine's NAME, never its coordinates
	# — the Reach is generated, so a saved position would strand a returning
	# player underground the moment world generation shifts. The live world
	# re-derives the point below.
	world.shrine_interactable().interacted.connect(func(_by: Node) -> void:
		_player.set_respawn_point(world.shrine_respawn_point())
		# A vault that refuses the write (present but unreadable — typically a
		# newer client's) still leaves the attunement live for THIS session:
		# progression degrading is never allowed to interrupt play.
		var stored := SaveVault.persist_attunement(SaveVault.SHRINE_WARDENS)
		_hud.toast("The Wardens' flame knows you now. The Reach will return you here."
			if stored else
			"The Wardens' flame knows you now — though it may not remember past this waking."))

	# Restore a previously attuned respawn point. A missing, unreadable or
	# newer-versioned vault simply leaves the wanderer waking in the cave, as
	# before the vault existed — progression state may never block a boot, and
	# it never touches the character save (no-resets law).
	#
	# Resolution goes through RespawnPoints rather than naming a shrine here, so
	# every shipped attunement name has ONE place that turns it into a position
	# and a test can walk them all end-to-end. A name this build cannot place
	# (a newer client's) resolves to null and is skipped — never a crash.
	var vault = SaveVault.load_saved()
	if vault is Dictionary:
		# Validation has already proved this is an array of non-empty strings.
		# Restore unknown future names too: they must survive in the live
		# session even when this older build cannot register the place.
		_discovery.restore(vault.get("discoveries", []))
		for name: String in SaveVault.attuned(vault):
			var point = RespawnPoints.resolve(name, world)
			if point != null:
				_player.set_respawn_point(point)
	# Observe only after restore. A persisted place then stays idempotent, while
	# the cave under a new wanderer's feet becomes the first v2 write.
	_observe_discoveries()

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

	# The live replication link, when a zone was named (#244). Default-off, so
	# the shipped single-player boot is unchanged.
	_connect_zone()

	# The smoke boot's POSITIVE marker: CI greps for this line, not merely
	# for the absence of errors — a boot that never mounted the project must
	# fail the check, not slip past it (the silent-no-op incident, 0.1.12).
	print("BOOT_OK v%s — world built, %d people and %d hounds in the Reach" % [
		DevLog.VERSION, npcs.npc_names.size(), hounds.creature_names.size()])


## The RECONCILE half of the boot-recovery lifecycle (#301), and the call that
## makes [BootRecovery] part of the running game rather than a library only its
## own test can reach: the core, the persistence and their tests were all
## complete and correct, and NOTHING called them — so the crash-loop guard was
## real in the suite and absent in the product.
##
## Read the ledger, act on a marker the LAST launch left behind — that launch
## mounted a build and never reached its checkpoint, so the build is quarantined
## and the marker cleared — and persist the result.
##
## MARKING is deliberately NOT done here, and that is the whole design of this
## slice. The only thing this scene could honestly mark is the RUNNING build,
## and doing so is unrecoverable: a power cut or a kill during startup leaves a
## marker, the next launch quarantines the installed build, and because
## [method BootRecovery.begin_attempt] refuses a quarantined version, no later
## successful boot can ever clear it. The ledger would be permanently poisoned
## by an event that was never a real boot failure.
##
## So marking waits for its real subject — a staged pack, marked by the
## pack-mount path in the in-client updater child. That leaves this half fully
## live and useful today: any marker that path writes is reconciled by the very
## next launch, and the behaviour is proven now rather than first exercised on
## the day an update goes wrong.
##
## EVERY failure here degrades to a normal boot and never blocks one — the same
## law the vault follows. Recovery memory exists to stop a player being trapped
## in a boot loop; a version of it that could itself refuse a launch would be the
## very thing it guards against.
##
## KNOWN LIMIT, by construction: this runs INSIDE the scene it guards, so a fault
## that stops `main.tscn` loading at all is beyond its reach. The ADR is explicit
## that recovery belongs in the immutable shell rather than the replaceable
## overlay — that shell does not exist yet, and building it is the bootstrap
## child's work, not this caller's.
func _reconcile_boot_recovery() -> void:
	var path := BootRecovery.recovery_path()
	var loaded := BootRecovery.load_state(path)
	# An unreadable or newer document loads with ok false and a read-only,
	# rollback-safe degraded state. It is carried forward rather than replaced:
	# save_state and new update attempts refuse to launder it, while its readable
	# quarantine view cannot turn damaged recovery metadata into a total rollback
	# veto. The original bytes remain on disk for a newer shell or reinstall.
	var state: Variant = loaded["state"]

	var settled := BootRecovery.reconcile(state)
	if not (settled["ok"] as bool):
		push_warning("boot recovery: ledger not reconciled — %s" % str(settled["reason"]))
		return

	# Whether to persist is decided by what reconcile CHANGED, never by whether
	# it could NAME the failed build. Those differ in exactly one case and it is
	# the wedging one: an unreadable marker (say `42`) is cleared without a
	# version to quarantine, so `quarantined_version` comes back empty while the
	# state on disk is now stale. Keying the write on that field alone left the
	# bad marker on the ledger forever — every later launch repeated the
	# condition, and the pack-mount path would keep refusing new attempts because
	# a marker was still pending.
	#
	# A pending marker is the whole test: every ok-true path of reconcile clears
	# a non-null marker, and the only path that leaves the state untouched is the
	# one where nothing was pending. Then writing back would be a pointless
	# rewrite of the player's file on every single launch.
	var pending: Variant = (state as Dictionary).get("marker") if state is Dictionary else null
	if pending == null:
		return

	var failed := str(settled["quarantined_version"])
	if failed.is_empty():
		push_warning("boot recovery: a boot-attempt marker was pending but unreadable — the failed build cannot be identified, so nothing was quarantined; clearing it so launches are not wedged forever")
	else:
		push_warning("boot recovery: the previous launch of %s never reached its checkpoint — quarantined" % failed)
	var written := BootRecovery.save_state(path, settled["state"])
	if not (written["ok"] as bool):
		push_warning("boot recovery: the reconciled ledger was not persisted — %s" % str(written["reason"]))


## Open the live zone connection when one was configured. This call is what
## makes `ZoneConnection` part of the running game rather than a library only
## its own test can reach: without it, setting WAR_ZONE_URL does nothing and
## the replication tier stays dead code from the player's point of view.
##
## A refusal is reported and then left alone. The Reach is playable
## single-player, so failing to reach a zone must never cost a player their
## session.
func _connect_zone() -> void:
	if not ZoneConnection.is_enabled():
		return
	_zone = ZoneConnection.new()
	# The view is built for any named zone, including one whose connection is
	# refused below: it draws whatever the store holds, and a store that never
	# received a frame is empty, so an unreachable zone shows nothing rather
	# than needing a second code path to stay blank.
	_replicas = ReplicaView.new()
	_replicas.name = "Replicas"
	add_child(_replicas)
	if not _zone.connect_to(ZoneConnection.zone_url()):
		# error_detail() names a misconfigured variable, never its value.
		push_warning("zone connection refused (%s): %s" % [_zone.error(), _zone.error_detail()])
		# This failure is now reported. Without claiming it, _process() sees
		# the same FAILED state a frame later and reports it a second time as
		# "lost" — and a connection that never opened cannot be lost. Observed
		# on a real boot with a missing token and with a ws:// url.
		_zone_failure_reported = true


## Per-frame world upkeep: drift the ash, then drive the connection.
##
## The ash comes FIRST and outside the zone guard on purpose. Drift belongs to
## every session, and the common case by far is a single-player boot with no
## zone at all — putting it after the `_zone == null` return would have left the
## air frozen for exactly the players who see it most.
##
## Driving the connection is cheap and safe every frame: poll() is a no-op
## unless the socket is connecting, live, or finishing a close handshake.
##
## A connection can also die well after `connect_to()` returned true — a
## handshake the zone refuses, or a frame the decoder or the store rejects.
## Those surface only here, so without this check replication would stop
## permanently and in total silence while the world went on looking fine.
## Reported once, not once per frame.
##
## Reconnecting automatically is deliberately NOT done here: recovery policy
## (when to retry, how often, and what to tell the player) belongs with the
## child that puts remote entities on screen, and guessing at it now would
## bake in a policy nothing yet exercises.
func _process(delta: float) -> void:
	_drift_hollow_fog(delta)
	_observe_discoveries()
	if _zone == null:
		return
	_zone.poll()
	# Draw whatever the poll just folded. Done before the failure reporting
	# below so a stream that dies mid-frame still shows the last consistent
	# table it delivered — the fold is atomic, so that table is never a
	# half-applied one.
	_replicas.sync(_zone.store())
	if _zone.is_live():
		_zone_was_live = true
	if _zone_failure_reported:
		return
	if _zone.state() == ZoneConnection.State.FAILED:
		_zone_failure_reported = true
		push_warning("zone connection lost (%s): %s" % [_zone.error(), _zone.error_detail()])
	elif _zone.state() == ZoneConnection.State.CLOSED and _zone_was_live:
		# A close is not an error, so the connection records none — but for a
		# link that WAS carrying the world, an orderly server shutdown or a
		# dropped network is indistinguishable to the player from a zone that
		# simply stopped updating. Since reconnect is deliberately not
		# attempted yet, silence here would strand an opted-in session offline
		# with nothing anywhere to say why.
		_zone_failure_reported = true
		push_warning("zone connection closed by the zone — replication has stopped for this session")


## Fold this frame's player position into the append-only discovery set. A
## refused vault write (unreadable/newer file) leaves the discovery live for
## this session and is not retried every frame: observe() returns each id once.
func _observe_discoveries() -> void:
	if _player == null:
		return
	var newly_found := _discovery.observe(_player.global_position)
	if newly_found.is_empty():
		return
	if not SaveVault.persist_discoveries(_discovery.discovered()):
		_hud.toast("This place is known for now — though the Reach may not remember next waking.")


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
	_volumetrics_on = Volumetrics.probe()
	Volumetrics.apply(env, _volumetrics_on)
	# The line itself is built by Volumetrics so that CI's frame-capture job and
	# the game agree on one string (#232): the capture job records this verdict
	# in the evidence artifact, because a frame captured with the probe OFF
	# depicts the height-fog fallback and cannot evidence the volumetric path.
	print(Volumetrics.marker(_volumetrics_on))

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


## Thickens the air in the terrain's hollows (#211), so ash gathers on low
## ground instead of hanging at one density everywhere.
##
## The pools live under Main beside the Sun and the WorldEnvironment — the rest
## of the atmosphere rig — rather than under World. That is deliberate on two
## counts: they are atmosphere, not terrain; and the world golden fingerprints
## every Node3D descendant of World, so parenting them there would move a hash
## that has nothing to do with what generated the ground.
##
## Placement is recorded unconditionally but the nodes are built only where the
## #158 probe passed. A device that cannot render volumetrics would only pay a
## per-frame cost for invisible nodes.
##
## The player opt-in that used to gate this as well is gone with #233: it was
## there because the ash had no drift and so sat below the quality bar, and now
## it drifts. The volumes are kept in [member _hollow_fog_volumes] so that
## [method _process] can move them.
func _build_hollow_fog(world: WorldGen) -> void:
	_hollow_fog = HollowFog.place(
		world.surface_height_at, WorldGen.SIZE, WorldGen.NO_GROUND, world.cave_protects
	)
	if not HollowFog.should_build(_volumetrics_on):
		print(HollowFog.marker(false, _volumetrics_on, _hollow_fog.size()))
		return
	var root := Node3D.new()
	root.name = "HollowFog"
	add_child(root)
	for placement: Dictionary in _hollow_fog:
		var volume := HollowFog.build_volume(placement)
		_hollow_fog_volumes.append(volume)
		root.add_child(volume)
	print(HollowFog.marker(true, _volumetrics_on, _hollow_fog.size()))


## Drifts the built ash pools for this frame (#233), so the air moves on the
## same wind the scrub already answers.
##
## A no-op wherever the pools were placed but not built — on a device without
## froxel volumetrics there is nothing to move, and the placement record is
## deliberately left untouched so it keeps reporting the RESTING world that the
## goldens and the headless tests pin.
func _drift_hollow_fog(delta: float) -> void:
	if _hollow_fog_volumes.is_empty():
		return
	_hollow_fog_time += delta
	for i in _hollow_fog_volumes.size():
		HollowFog.apply_drift(_hollow_fog_volumes[i], _hollow_fog[i], _hollow_fog_time)


## Where this boot pooled ash, deepest hollow first — a copy, so a caller can
## never disturb the built world. Each entry is a [HollowFog] placement
## (`pos`, `extents`, `density`, `relief`).
func hollow_fog_placements() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for placement: Dictionary in _hollow_fog:
		out.append(placement.duplicate(true))
	return out
