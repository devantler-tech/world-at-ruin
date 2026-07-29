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
## Shown when a character exists on disk that this build cannot accept. Says the
## one thing the player needs and nothing it cannot know: their character is
## still there. It deliberately does not advise updating — a recipe from a newer
## build and a damaged one are indistinguishable to the player, and only the
## first is fixed that way.
const REFUSED_SAVE_NOTICE := \
	"This version of the game can't read your saved character. " \
	+ "It has been left untouched and nothing new will replace it."

## Shown when a save did not happen for a reason that is not a refusal.
##
## Deliberately RETRYABLE in tone, and it never latches [member _save_blocked].
## It also names no CAUSE, because this branch cannot know one: a false here is
## contention (another copy of the game held the write lock, or this attempt
## freed an abandoned one and refused that pass) OR a transient persistence
## failure (the save directory missing or unwritable, a staging file that could
## not be created or renamed, ownership lost mid-write). Blaming a second copy
## of the game would be a confident lie on every one of the second set, and
## would send a player hunting a program that is not running. What the player
## needs is true of all of them: their edit did not land, and trying again is the
## right next move.
##
## It says the EDIT was not saved, never that the character "has not changed" —
## the two are not the same, and the stronger claim can be false on screen. This
## same failure path reloads the recipe from disk, and when the reason was
## contention that recipe may be another copy's newly committed character. The
## body would then visibly change at the very moment a notice claimed it had not.
const UNSAVED_NOTICE := \
	"Your changes could not be saved just now — " \
	+ "try again."
const DISCOVERY_PERSIST_RETRY_INITIAL_SECONDS := 1.0
const DISCOVERY_PERSIST_RETRY_MAX_SECONDS := 30.0
const REWARD_PERSIST_RETRY_INITIAL_SECONDS := 1.0
const REWARD_PERSIST_RETRY_MAX_SECONDS := 30.0

var _player: Player
var _hud: Hud
var _creator: CharacterCreator
var _interaction: InteractionController
## Set when a character exists that this boot must not replace: legacy recovery
## could not restore a stranded save, or the saved recipe was refused (newer than
## this build understands, or damaged). While true, ALL character-creator entry is
## locked — auto first-run AND the manual editor key — because applying would
## write over player state this build cannot read back (no-resets law). Decided
## fresh each boot: the next launch re-examines the file.
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
## The live environment, held so [method _track_cave_atmosphere] can retune the
## ash's height pooling as the view moves under rock and back out.
var _env: Environment = null
## Last sky-cover reading written to [member _env]. Negative until the first
## frame, so the opening reading is always written whatever it turns out to be.
var _sky_blocked := -1.0
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
## The boot-owned exploration-reward state. Vault-v3 claims are restored even
## when this rollback build does not register the newer place yet, so a reward
## already granted by a newer client can never be granted twice.
var _exploration_rewards := ExplorationRewards.new()
## Boot-owned quest progress. The v4 reader restores this state, while the
## retained v3 writer deliberately cannot originate quest data yet.
var _quest_log := QuestLog.new()
## A discovery enters the live tracker before persistence is attempted. Keep
## the locally observed IDs themselves so a transient filesystem failure can
## retry them without also re-originating rollback-only names restored into the
## tracker. SaveVault preserves unknown names from the on-disk document; Main
## submits only discoveries this build actually observed.
var _discovery_persistence_pending: Array[String] = []
var _discovery_persistence_retry_in := 0.0
var _discovery_persistence_retry_delay := DISCOVERY_PERSIST_RETRY_INITIAL_SECONDS
var _discovery_persistence_warning_shown := false
## Successfully applied reward place ids waiting for their append-only v3
## claim write. The live tracker marks them before they enter this queue, so a
## transient filesystem retry never applies the same outcome twice in-session.
var _reward_persistence_pending: Array[String] = []
var _reward_persistence_retry_in := 0.0
var _reward_persistence_retry_delay := REWARD_PERSIST_RETRY_INITIAL_SECONDS
var _reward_persistence_warning_shown := false
## Notices raised while _ready() is still running, delivered together at the end
## of it. The HUD has ONE toast label and a later toast replaces an earlier one
## before a frame renders, so a boot that has several things to say would
## otherwise show only whichever spoke last — see [method _notify].
var _boot_notices: Array[String] = []
## True until _ready() has delivered its notices. While set, [method _notify]
## collects instead of showing.
var _booting := true


## Say something to the player, surviving a boot that raises more than one notice.
##
## During _ready() the message is collected; afterwards it is shown immediately.
## Every startup path that speaks to the player goes through here, because the
## overwrite is invisible in testing — nothing renders during _ready(), so the
## lost notice leaves no trace at all.
func _notify(message: String) -> void:
	if _booting:
		_boot_notices.append(message)
		return
	_hud.toast(message)


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
	# The first production exploration reward: reaching the Wardens' Shrine
	# unlocks its return point. The reward carries only the stable semantic id;
	# the generated world's live coordinate is resolved when the outcome applies.
	_exploration_rewards.add(DISCOVERY_WARDENS_SHRINE, {
		"kind": ExplorationRewards.KIND_WAYPOINT,
		"id": SaveVault.SHRINE_WARDENS,
		"name": "Wardens' Shrine",
	})

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

	# A vault whose bytes no client can parse is set aside before anything reads
	# it (#290). Left in place it refuses every write for the life of the install:
	# the player is told each session that the Reach may not remember, with no way
	# to clear it from inside the game. Nothing is destroyed — the bytes are
	# preserved beside the vault — and a document from a NEWER client still
	# parses, so that one is never touched.
	#
	# The notice is COLLECTED rather than shown here — see [method _notify]. Every
	# startup path that speaks to the player does the same, so a boot with several
	# things to say delivers all of them instead of only the last.
	if not SaveVault.quarantine_unreadable(SaveVault.vault_path()).is_empty():
		_notify("What the Reach remembered has torn. Those pages are set aside; it begins again.")

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
		# The v4 reader accepts forward-only quest progress before any quest
		# definitions exist. QuestLog applies it when content registers later.
		_quest_log.restore(vault.get("quests", {}))
		# Validation has already proved this is an array of non-empty strings.
		# Restore unknown future names too: they must survive in the live
		# session even when this older build cannot register the place.
		_discovery.restore(vault.get("discoveries", []))
		# Validation has already proved this is an array of non-empty strings.
		# Restore unknown future claims too: forgetting one during rollback could
		# grant a reward that the newer client already consumed.
		_exploration_rewards.restore(vault.get("reward_claims", []))
		_apply_restored_reward_outcomes()
		# A discovery may have persisted before its reward claim during a
		# transient failure or an older release. Reconcile that durable discovery
		# now; claim_applied keeps already-restored claims idempotent.
		_claim_exploration_rewards(_discovery.discovered())
		# A direct attunement is an explicit player choice and therefore wins
		# over both restored and newly reconciled exploration waypoints. Select
		# it last, after every automatic outcome, so precedence is a named policy
		# rather than an accidental statement order.
		var preferred_attunement: Variant = _preferred_attuned_respawn(vault, world)
		if preferred_attunement != null:
			_player.set_respawn_point(preferred_attunement)
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
		# First in the notice list: this is the one the player must act on.
		_boot_notices.insert(
			0, "A saved character couldn't be restored — please restart. Your character is safe.")
	else:
		var save_path := CharacterStore.save_path()
		var saved = CharacterStore.load_saved()
		if saved is Dictionary:
			_player.set_character(saved)
		elif CharacterStore.is_refused(save_path):
			# There IS a character here, and this build cannot accept it — it was
			# written by a newer build, or it is damaged. Both are existing player
			# state, so the one thing we must not do is treat this as a first run
			# and open the writable creator over it. Lock every writer and say so;
			# the store keeps the refusal latched for the rest of the process.
			_save_blocked = true
			_boot_notices.insert(0, REFUSED_SAVE_NOTICE)
		else:
			# First time in the world: shape a character before setting out.
			_open_creator.call_deferred(true)

	# Every boot notice at once, so no fact is lost to the single toast label.
	# Placed after every startup path that can raise one — the vault quarantine
	# above, discovery persistence inside _observe_discoveries(), and legacy
	# character recovery — so none of them is left to be overwritten by this.
	_booting = false
	if not _boot_notices.is_empty():
		_hud.toast("   ".join(_boot_notices))

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
	# The whole load → reconcile → write is ONE transaction, held under the
	# ledger's write lock. Locking only the final replace would not close the
	# race: two shells can each load the same ledger before either takes the
	# lock, then acquire in turn, and the second's write discards the first's
	# quarantine record — the exact loss the lock exists to prevent.
	if not FileLock.with_lock(path, func() -> void: _reconcile_boot_recovery_locked(path)):
		push_warning(
			"boot recovery: another writer holds the ledger's write lock — leaving reconciliation to the next launch")


## _reconcile_boot_recovery()'s body, with the ledger's write lock already held.
## Split out so acquisition and release live on ONE path each: GDScript has no
## `defer`, and this body returns early on three separate branches.
func _reconcile_boot_recovery_locked(path: String) -> void:
	# The ledger's identity is captured BEFORE the load, and that order is the
	# whole guard (#453). Captured AFTER, a foreign write landing between the load
	# and the capture would become the expectation while this transaction still
	# held the document it actually read — the check would pass and quarantine
	# evidence would be renamed away. Captured before, that interleaving refuses.
	#
	# This is what covers the writers the lock above cannot bind: a retained
	# pre-lock build, a rollback build, cloud sync, a backup agent, a hand edit.
	var expected := BootRecovery.document_identity(path)
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
	# one where nothing was pending. An existing document then needs no rewrite,
	# but an absent first-boot path must persist the active writer schema once.
	# The load result owns that distinction; a caller-side existence check could
	# become stale before load_state consumes a concurrently-created v0 file.
	var pending: Variant = (state as Dictionary).get("marker") if state is Dictionary else null
	if pending == null:
		if loaded.get("path_was_missing", false) as bool and loaded["ok"] as bool:
			# Keep initialization conditional through the final replace: a cloud
			# sync writer may create valid v0 state after the missing load.
			var initialized := BootRecovery.save_state(path, state, true, expected)
			if not (initialized["ok"] as bool):
				push_warning("boot recovery: first-boot state was not persisted — %s" % str(initialized["reason"]))
		return

	var failed := str(settled["quarantined_version"])
	if failed.is_empty():
		push_warning("boot recovery: a boot-attempt marker was pending but unreadable — the failed build cannot be identified, so nothing was quarantined; clearing it so launches are not wedged forever")
	else:
		push_warning("boot recovery: the previous launch of %s never reached its checkpoint — quarantined" % failed)
	var written := BootRecovery.save_state(path, settled["state"], false, expected)
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
	_track_cave_atmosphere()
	_observe_discoveries(delta)
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


## Fold this frame's player position into the append-only discovery and reward
## sets. Outcomes apply before their place ids are marked claimed. Discovery and
## claim writes keep independent bounded exponential backoff. A writable claim
## refusal requeues its discovery prerequisite before retrying; a path-latched
## unreadable/newer vault stays session-only and is never retried, preserving
## the downgrade refusal.
func _observe_discoveries(delta: float = 0.0) -> void:
	if _player == null:
		return
	var newly_found := _discovery.observe(_player.global_position)
	if not newly_found.is_empty():
		for name: String in newly_found:
			if name not in _discovery_persistence_pending:
				_discovery_persistence_pending.append(name)
		_discovery_persistence_retry_in = 0.0
		_discovery_persistence_retry_delay = DISCOVERY_PERSIST_RETRY_INITIAL_SECONDS
		_claim_exploration_rewards(newly_found)
	_persist_pending_discoveries(delta)
	_persist_pending_reward_claims(delta)


## Apply registered outcomes for newly discovered places, then queue only the
## ids whose outcomes succeeded. The tracker records success before this method
## returns, so a persistence retry cannot re-grant the live reward.
func _claim_exploration_rewards(found_ids: Array) -> void:
	var applied := _exploration_rewards.claim_applied(
		found_ids, Callable(self, "_apply_exploration_reward"))
	if applied.is_empty():
		return
	for name: String in applied:
		if name not in _reward_persistence_pending:
			_reward_persistence_pending.append(name)
	_reward_persistence_retry_in = 0.0
	_reward_persistence_retry_delay = REWARD_PERSIST_RETRY_INITIAL_SECONDS


## The final respawn point selected by direct attunement, or null when this
## build cannot resolve one. Direct attunement has explicit precedence over an
## automatically restored waypoint claim.
func _preferred_attuned_respawn(vault: Dictionary, world: WorldGen) -> Variant:
	var preferred: Variant = null
	for name: String in SaveVault.attuned(vault):
		var point = RespawnPoints.resolve(name, world)
		if point != null:
			# Attunements are append-only in stored order, so the latest
			# resolvable direct choice retains the established v1 behaviour.
			preferred = point
	return preferred


## Re-apply the known outcomes represented by persisted claims. Unknown future
## claims remain remembered but inert in this rollback build; a later build can
## register them without granting twice.
func _apply_restored_reward_outcomes() -> void:
	for poi_id: String in _exploration_rewards.claimed():
		if not _exploration_rewards.is_registered(poi_id):
			continue
		var reward := _exploration_rewards.reward_for(poi_id)
		if not _apply_exploration_reward(poi_id, reward, false):
			push_warning("Main: could not restore exploration reward '%s'" % poi_id)


## Apply one horizontal reward to the live session. Only kinds with a real
## production outcome return true. The Wardens' waypoint resolves from its
## stable id into this generated world's current coordinate, so a world-layout
## change never strands the persisted claim at an obsolete position.
func _apply_exploration_reward(
		_poi_id: String, reward: Dictionary, announce: bool = true) -> bool:
	match String(reward.get("kind", "")):
		ExplorationRewards.KIND_WAYPOINT:
			var world := get_node_or_null("World") as WorldGen
			if world == null or _player == null:
				return false
			var point = RespawnPoints.resolve(String(reward.get("id", "")), world)
			if point == null:
				return false
			_player.set_respawn_point(point)
			if announce:
				_notify("You know a new way back: %s." % String(reward.get("name", "")))
			return true
	return false


func _persist_pending_discoveries(delta: float) -> void:
	if _discovery_persistence_pending.is_empty():
		return
	if _discovery_persistence_retry_in > 0.0:
		_discovery_persistence_retry_in = maxf(
			0.0, _discovery_persistence_retry_in - delta)
		if _discovery_persistence_retry_in > 0.0:
			return
	if SaveVault.persist_discoveries(_discovery_persistence_pending):
		_discovery_persistence_pending.clear()
		_discovery_persistence_retry_in = 0.0
		_discovery_persistence_retry_delay = DISCOVERY_PERSIST_RETRY_INITIAL_SECONDS
		return
	# persist_discoveries() latches unreadable/newer paths. Only a failure that
	# leaves this exact path writable is transient and eligible for retry.
	if SaveVault.can_write(SaveVault.vault_path()):
		_discovery_persistence_retry_in = _discovery_persistence_retry_delay
		_discovery_persistence_retry_delay = minf(
			_discovery_persistence_retry_delay * 2.0,
			DISCOVERY_PERSIST_RETRY_MAX_SECONDS)
	else:
		_discovery_persistence_pending.clear()
	if not _discovery_persistence_warning_shown:
		_discovery_persistence_warning_shown = true
		# _notify rather than a direct toast: the first observation happens during
		# _ready(), where a direct toast would be overwritten by the consolidated
		# boot notice and the player would never learn the place was not recorded.
		_notify("This place is known for now — though the Reach may not remember next waking.")


func _persist_pending_reward_claims(delta: float) -> void:
	if _reward_persistence_pending.is_empty():
		return
	if _reward_persistence_retry_in > 0.0:
		_reward_persistence_retry_in = maxf(
			0.0, _reward_persistence_retry_in - delta)
		if _reward_persistence_retry_in > 0.0:
			return
	if SaveVault.persist_reward_claims(_reward_persistence_pending):
		_reward_persistence_pending.clear()
		_reward_persistence_retry_in = 0.0
		_reward_persistence_retry_delay = REWARD_PERSIST_RETRY_INITIAL_SECONDS
		return
	if SaveVault.can_write(SaveVault.vault_path()):
		# A writable claim refusal can mean cloud sync replaced the vault after
		# its discovery write succeeded. The claim writer correctly refuses a
		# place that is no longer durable, so restore that prerequisite to the
		# discovery queue before retrying the claim. Both writes are append-only
		# and idempotent; the live reward remains claimed and is never re-applied.
		for name: String in _reward_persistence_pending:
			if name not in _discovery_persistence_pending:
				_discovery_persistence_pending.append(name)
		_discovery_persistence_retry_in = 0.0
		_reward_persistence_retry_in = _reward_persistence_retry_delay
		_reward_persistence_retry_delay = minf(
			_reward_persistence_retry_delay * 2.0,
			REWARD_PERSIST_RETRY_MAX_SECONDS)
	else:
		_reward_persistence_pending.clear()
	if not _reward_persistence_warning_shown:
		_reward_persistence_warning_shown = true
		_notify("This way back is known for now — though the Reach may not remember next waking.")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("character_editor") and _creator == null:
		_open_creator(false)
		get_viewport().set_input_as_handled()

func _open_creator(first_run: bool) -> void:
	# Single chokepoint: while a character exists that this build must not
	# replace — stranded and unrecovered, or refused — applying would overwrite
	# player state this build cannot read back (no-resets law). Refuse every
	# entry, auto and manual editor-key alike. CharacterStore.save_to() refuses
	# the same write independently, so this is the door and that is the lock.
	if _save_blocked:
		return
	var save_path := CharacterStore.save_path()
	# Capture the recipe's identity BEFORE reading it, so the apply below can
	# compare-and-swap on the bytes this session actually edited (#469). The order
	# is load-bearing and cannot be relaxed to "somewhere near the read": captured
	# AFTER, a foreign write landing between the load and the capture becomes the
	# expectation while the creator still opens on the OLD document, and the check
	# then passes on exactly the interleaving it exists to refuse. Captured before,
	# that interleaving refuses. The same ordering guards the vault (#386) and the
	# boot-recovery ledger (#453).
	var expected_identity := CharacterStore.document_identity(save_path)
	var initial = CharacterStore.load_saved()
	if initial is not Dictionary and CharacterStore.is_refused(save_path):
		# The file changed since boot — corrupted, or replaced by a newer build's
		# recipe — so the refusal is discovered HERE rather than at startup. It is
		# the same state, and it gets the same answer: lock the creator instead of
		# opening it over a character this build cannot read. Falling through
		# would open the editor on the wanderer preset, and applying would change
		# the body on screen while the store refused to persist it — telling the
		# player their character was saved when it was not.
		_save_blocked = true
		_notify(REFUSED_SAVE_NOTICE)
		return
	if initial is not Dictionary:
		initial = CharacterFactory.load_recipe("res://recipes/wanderer.json")
		if initial is Dictionary:
			initial.erase("comment")
		else:
			initial = { "version": 1 }
	_creator = CharacterCreator.new()
	add_child(_creator)
	_creator.applied.connect(func(recipe: Dictionary) -> void:
		# Only claim the body changed if it was actually recorded. The store can
		# refuse between opening the creator and applying, and showing the new
		# body with a success line would tell the player they are saved when the
		# next launch will show them someone else.
		if not CharacterStore.save_recipe(recipe, expected_identity):
			# A refused write and a CONTENDED one both answer false, and they must
			# not be treated alike. A refusal is permanent — the recipe on disk is
			# not this build's to replace — so the creator latches shut. Contention
			# is momentary, and now has two shapes: another copy of the game held the
			# write lock (or this attempt freed an abandoned one and deliberately
			# refused that pass), or the recipe changed under this edit and the
			# compare-and-swap refused rather than discarding whoever wrote it
			# (#469). Latching on either would lock the player out of their own
			# character for the rest of the session over a collision the next
			# attempt resolves. The store's refusal latch is what tells the
			# permanent case from both momentary ones; it is never set by a lock
			# failure or by a stale identity, and CharacterStore.last_refusal()
			# names which of the three occurred.
			# Put the BODY back to what is actually on disk. The creator previews
			# every edit on the live player as it is made, and _close(true) goes on
			# to tear itself down whether or not this callback returned early — so
			# without this the player is left looking at a character that was never
			# recorded, which is precisely the "saved when they are not" the notice
			# above exists to prevent. The cancel path already reverts this way; a
			# failed apply has exactly the same problem and now gets the same answer.
			# Disk is the truth where there IS one. Where there is not — a first
			# run, or a save deleted while the creator was open — the recipe the
			# creator OPENED with is the last state that was ever true for this
			# body, so fall back to it. Leaving the edit up in that case would
			# contradict the notice below on exactly the paths load_saved() cannot
			# answer for, which is the one case the player has no way to check.
			var on_disk = CharacterStore.load_saved()
			if on_disk is Dictionary:
				_player.set_character(on_disk)
			else:
				_player.set_character(initial)
			if CharacterStore.is_refused(CharacterStore.save_path()):
				_save_blocked = true
				_hud.toast(REFUSED_SAVE_NOTICE)
			else:
				_hud.toast(UNSAVED_NOTICE)
			return
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
	# The downward pooling is [CaveAtmosphere]'s to write — at build time under
	# an open sky, and again each frame for wherever the view has moved to.
	CaveAtmosphere.apply(env, 0.0)

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
	_env = env


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


## Retunes the ash's downward pooling for wherever the view is this frame, so
## the weather stops falling inside sealed rock ([CaveAtmosphere] carries the
## measurements and the reasoning).
##
## Driven off the ACTIVE camera rather than the player, for two reasons that
## point the same way. The camera is what the frame is composed from, so it is
## the thing whose air the fog is describing — and `tools/frame_capture` shoots
## the cave by making its own camera current while the wanderer stays put, so
## keying on the player would photograph the starter cave through surface
## weather and the evidence frames would not depict what a player sees.
func _track_cave_atmosphere() -> void:
	if _env == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var blocked := CaveAtmosphere.sky_blocked_fraction(
		cam.get_world_3d().direct_space_state, cam.global_position
	)
	# Written only when it actually changes. Setting a fog property does not
	# store a float — it re-issues the whole fog block to the rendering server —
	# and the cone can only report six values, so the overwhelming majority of
	# frames (all of them outdoors, all of them deep in the cave) would be
	# re-sending state identical to what is already there. This is an exact
	# compare on the computed result, NOT a positional or time-based cache: the
	# frame a reading changes on is still the frame it is written on, so what
	# the environment holds is bit-identical to writing it every time.
	if blocked == _sky_blocked:
		return
	_sky_blocked = blocked
	CaveAtmosphere.apply(_env, blocked)


## Where this boot pooled ash, deepest hollow first — a copy, so a caller can
## never disturb the built world. Each entry is a [HollowFog] placement
## (`pos`, `extents`, `density`, `relief`).
func hollow_fog_placements() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for placement: Dictionary in _hollow_fog:
		out.append(placement.duplicate(true))
	return out
