extends Node
## Boot test for save-vault RESTORE (issue #249, parent #3): a shrine attuned in
## an earlier session is honoured on the NEXT boot.
##
## This is the end-to-end half the unit tests cannot reach. save_vault_test
## proves the store round-trips and save_vault_guard_test proves shipped vaults
## survive, but BOTH would still pass if main.gd never read the vault at all —
## the store would be perfect and the game would ignore it. Only booting the
## real scene against a pre-seeded vault shows the wiring is live.
##
## Structure, and why it is two boots rather than one:
##  A. NEGATIVE CONTROL — boot with NO vault and record where the wanderer
##     respawns. Without this the positive case is VACUOUS: if the default
##     spawn point already happened to equal the shrine's respawn point, an
##     assertion that they match would pass against a main.gd that reads
##     nothing. The control proves the two differ, so the match in B can only
##     come from the restore.
##  B. POSITIVE — boot once PER SHIPPED LEDGER NAME, seeding a vault with that
##     name attuned, and require the respawn point to have MOVED. Walking the
##     ledger rather than one constant is the point: a name can be added to
##     shipped_attunements.txt and to KNOWN_ATTUNEMENTS while nothing actually
##     restores it, and every in-game ledger guard stays green. Only booting
##     each name and watching where the wanderer wakes catches that.
##
## Both boots run behind SaveIsolation, so neither the player's character nor
## their real vault is ever read or written (no-resets law).
##
## Run: godot --headless --path client res://tests/vault_restore_boot_test.tscn

const ASSERT_TICK := 30
const RETRY_ASSERT_TICK := 90
const DRIFT_ASSERT_TICK := 60
const EPS := 0.01
const PROBE_PATH := "user://vault_restore_boot_probe.json"
const DISCOVERY_PROBE := ["wardens_shrine", "future_place", "wardens_shrine"]
const SHIPPED_DISCOVERIES := "res://tests/data/shipped_discoveries.txt"
const RETRY_CHARACTER_PROBE := "user://vault_discovery_retry_character.json"
const RETRY_PROBE_DIR := "user://vault_discovery_retry"
const RETRY_VAULT := RETRY_PROBE_DIR + "/vault.json"

## An INDEPENDENT expected destination per shipped attunement name.
##
## The obvious assertion — compare where the wanderer woke against
## RespawnPoints.resolve(name, world) — is worthless: main.gd resolves through
## exactly that call, so test and code read the same branch and a name wired to
## the WRONG place agrees with itself. Combined with the control comparison it
## would only ever prove "something moved", not "moved to the right landmark".
##
## So each name is anchored here to a landmark this test derives from the WORLD
## directly, never through the resolver under test. Repointing `wardens_shrine`
## at anything other than the Wardens' Shrine now fails, because the oracle and
## the implementation no longer share a source.
##
## A new shipped name with no entry here fails too — deliberately. An
## unanchored name is exactly the case this guards.
const DESTINATION_ORACLE := {
	"wardens_shrine": "shrine",
}

var _ticks := 0
var _main: Node
var _save: SaveIsolation
## false = the negative control boot, true = the restore boot.
var _seeded := false
var _control_spawn := Vector3.INF
## Shipped attunement names still to exercise; the control boot fills it.
var _pending: Array = []
## The name the current seeded boot is exercising.
var _current := ""
var _restored := 0
## The final boots exercise vault-v2 discovery restoration, a real cave-to-
## shrine discovery write, a reboot that can only recover the shrine from disk,
## retry after a deliberately transient first write failure, and a valid
## cloud-synced vault replacement that drops a rollback-only name from disk.
var _discovery_phase := ""


func _ready() -> void:
	_begin_boot(false)


## Tear down any previous scene, redirect the save seams, optionally seed an
## attuned vault, then boot main.tscn.
func _begin_boot(seeded: bool, name: String = "") -> void:
	_seeded = seeded
	_discovery_phase = ""
	_current = name
	_ticks = 0
	if _main != null:
		_main.queue_free()
		_main = null
	_save = SaveIsolation.new(PROBE_PATH)
	if not _save.begin():
		_fail("save isolation did not take — refusing to boot into the real save")
		return
	if seeded:
		# Written through the store's own save path, so the test seeds exactly
		# what a real earlier session would have left behind.
		SaveVault.clear_refusals_for_test()
		var attuned := SaveVault.attune(SaveVault.empty(), name)
		if not SaveVault.save_to(SaveVault.vault_path(), attuned):
			_fail("could not seed the vault probe for '%s'" % name)
			return
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(_main)


## Seed the exact expanded vault shape, then boot the real production scene.
## This is deliberately separate from the pure Discovery and SaveVault tests:
## capability 3 is safe only when main.gd actually owns and restores the live
## tracker a rollback-selected build will use.
func _begin_discovery_boot() -> void:
	_discovery_phase = "restore"
	_ticks = 0
	if _main != null:
		_main.queue_free()
		_main = null
	_save = SaveIsolation.new(PROBE_PATH)
	if not _save.begin():
		_fail("save isolation did not take for the discovery boot")
		return
	SaveVault.clear_refusals_for_test()
	var expanded := {
		"version": 2,
		"attuned": [],
		"discoveries": DISCOVERY_PROBE.duplicate(),
	}
	if not SaveVault.save_to(SaveVault.vault_path(), expanded):
		_fail("could not seed the vault-v2 discovery probe")
		return
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(_main)


## Start from a genuinely empty vault and let the production scene discover
## both shipped places. Unlike the seeded reader boot above, this gives the
## test no persistence help: only main.gd observing the real player and calling
## the real SaveVault writer can create the v2 document.
func _begin_discovery_writer_boot() -> void:
	_discovery_phase = "write"
	_ticks = 0
	if _main != null:
		_main.queue_free()
		_main = null
	_save = SaveIsolation.new(PROBE_PATH)
	if not _save.begin():
		_fail("save isolation did not take for the discovery writer boot")
		return
	SaveVault.clear_refusals_for_test()
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(_main)


## Boot against a vault path whose parent does not exist. The cave is observed
## during Main._ready(), so its first persistence attempt must fail. Creating
## the parent afterwards turns the exact same path writable and proves Main
## retries pending progression without rediscovering the already-found cave.
func _begin_discovery_retry_boot() -> void:
	_discovery_phase = "retry"
	_ticks = 0
	if _main != null:
		_main.queue_free()
		_main = null
	_cleanup_retry_probe()
	_save = SaveIsolation.new(RETRY_CHARACTER_PROBE)
	if not _save.begin():
		_fail("save isolation did not take for the transient discovery-write boot")
		return
	OS.set_environment(SaveVault.VAULT_PATH_ENV, RETRY_VAULT)
	if SaveVault.vault_path() != RETRY_VAULT:
		_fail("the transient discovery-write vault seam did not take")
		return
	SaveVault.clear_refusals_for_test()
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(_main)


## Restore a rollback-only discovery into the live tracker, then replace the
## on-disk vault with another valid document that lacks it (the observable shape
## of cloud sync or another rollback client winning between writes). Reaching
## the shrine afterwards must still persist that known discovery; a restored
## future id may not poison every later write merely because the current disk
## document no longer carries it.
func _begin_discovery_drift_boot() -> void:
	_discovery_phase = "drift"
	_ticks = 0
	if _main != null:
		_main.queue_free()
		_main = null
	_save = SaveIsolation.new(PROBE_PATH)
	if not _save.begin():
		_fail("save isolation did not take for the cloud-synced discovery boot")
		return
	SaveVault.clear_refusals_for_test()
	var expanded := {
		"version": 2,
		"attuned": [],
		"discoveries": ["future_place", "starter_cave"],
	}
	if not SaveVault.save_to(SaveVault.vault_path(), expanded):
		_fail("could not seed the rollback-only discovery probe")
		return
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(_main)


func _physics_process(_delta: float) -> void:
	# _fail() requests tree shutdown but does not end this frame. A setup helper
	# can fail after clearing the previous scene and before assigning the next;
	# keep the pending callback from masking that real failure with a null access.
	if _main == null:
		return
	_ticks += 1
	var world := _main.get_node_or_null("World") as WorldGen
	var player := _main.get_node_or_null("Wanderer") as Player
	if world == null or player == null:
		if _ticks > 10:
			_fail("main scene did not build World and Wanderer")
		return
	# Approach the shrine from its negative-Z edge. This point is within the
	# clearing around the shrine itself (Z=0) but outside the same radius around
	# its standable respawn point (Z=5), so an offset discovery centre fails.
	# The reboot deliberately does NOT repeat this move: finding the shrine then
	# can only come from the persisted vault.
	if _discovery_phase == "write" and _ticks == 10:
		player.global_position = Vector3(0.0, world.shrine_respawn_point().y, -13.0)
	if _discovery_phase == "retry" and _ticks == 3:
		if FileAccess.file_exists(RETRY_VAULT):
			_fail("the transient write unexpectedly succeeded before its parent directory existed")
			return
		var mkdir_error := DirAccess.make_dir_absolute(
			ProjectSettings.globalize_path(RETRY_PROBE_DIR))
		if mkdir_error != OK and mkdir_error != ERR_ALREADY_EXISTS:
			_fail("could not make the transient vault path writable (%d)" % mkdir_error)
			return
	if _discovery_phase == "drift" and _ticks == 3:
		var replacement := {
			"version": 2,
			"attuned": [],
			"discoveries": ["starter_cave"],
		}
		if not SaveVault.save_to(SaveVault.vault_path(), replacement):
			_fail("could not simulate the valid cloud-synced vault replacement")
			return
	if _discovery_phase == "drift" and _ticks == 10:
		player.global_position = Vector3(0.0, world.shrine_respawn_point().y, -13.0)
	var assert_tick := ASSERT_TICK
	if _discovery_phase == "retry":
		assert_tick = RETRY_ASSERT_TICK
	elif _discovery_phase == "drift":
		assert_tick = DRIFT_ASSERT_TICK
	if _ticks != assert_tick:
		return

	match _discovery_phase:
		"restore":
			_assert_discovery_restore()
			return
		"write":
			_assert_discovery_write()
			return
		"reboot":
			_assert_discovery_reboot(player, world)
			return
		"retry":
			_assert_discovery_retry()
			return
		"drift":
			_assert_discovery_drift()
			return

	var shrine_point := world.shrine_respawn_point()
	# respawn() is the observable effect: it is what actually moves the wanderer
	# when they fall. Asserting through it — rather than reading spawn_point —
	# keeps the test on the behaviour the player experiences.
	player.respawn()
	var woke_at := player.global_position

	if not _seeded:
		# A. Negative control: with no vault, waking must NOT already be at the
		# shrine, or the positive assertion below proves nothing.
		if woke_at.distance_to(shrine_point) <= EPS:
			_fail(("VACUOUS TEST: with no vault the wanderer already wakes at the shrine "
				+ "(%s ~= %s) — the restore assertion could not distinguish a live "
				+ "restore from a no-op") % [str(woke_at), str(shrine_point)])
			return
		_control_spawn = woke_at
		if not _save.real_save_untouched():
			_fail("the control boot touched the player's real save or vault")
			return
		_pending = _shipped_attunements()
		if _pending.is_empty():
			_fail("shipped_attunements.txt is missing or empty — nothing to exercise end-to-end")
			return
		_begin_boot(true, _pending.pop_front())
		return

	# B. Positive: this shipped name was restored, so waking has MOVED from
	# where the control woke. Every name in the ledger gets its own boot — a
	# name with no RespawnPoints branch fails HERE, which is the whole reason
	# this walks the ledger instead of one constant.
	if RespawnPoints.resolve(_current, world) == null:
		_fail(("SHIPPED ATTUNEMENT HAS NO RESTORE BRANCH (no-resets law): '%s' is in "
			+ "shipped_attunements.txt but RespawnPoints cannot place it — a player attuned "
			+ "there wakes in the cave forever, and every ledger guard stays green")
			% _current)
		return
	# The destination comes from the ORACLE, not from the resolver — see
	# DESTINATION_ORACLE. Asking RespawnPoints where it should be would let a
	# mis-wired name agree with itself.
	var expected = _oracle_point(_current, world)
	if expected == null:
		_fail(("SHIPPED ATTUNEMENT HAS NO ORACLE ENTRY: '%s' is in shipped_attunements.txt but "
			+ "DESTINATION_ORACLE does not say where it must lead — an unanchored name could be "
			+ "repointed anywhere and still pass") % _current)
		return
	if woke_at.distance_to(expected) > EPS:
		_fail(("RESTORE WENT TO THE WRONG PLACE for '%s': the wanderer woke at %s, but this name "
			+ "must lead to %s (%s) — either the vault is not being applied, or the name has been "
			+ "repointed away from its landmark")
			% [_current, str(woke_at), str(expected), String(DESTINATION_ORACLE[_current])])
		return
	if woke_at.distance_to(_control_spawn) <= EPS:
		_fail("the restore boot for '%s' woke in the same place as the control — nothing changed" % _current)
		return
	if not _save.real_save_untouched():
		_fail("the restore boot touched the player's real save or vault")
		return
	_restored += 1

	if not _pending.is_empty():
		_begin_boot(true, _pending.pop_front())
		return

	_begin_discovery_boot()


## The production boot must own the tracker and apply every accepted v2 name.
## Discovering the private member through the property list keeps the RED case
## a clear assertion failure instead of an invalid-property engine error.
func _assert_discovery_restore() -> void:
	var world := _main.get_node_or_null("World") as WorldGen
	if world == null:
		_fail("the discovery restore boot has no live world for landmark verification")
		return
	var tracker: Variant = null
	for property: Dictionary in _main.get_property_list():
		if String(property.get("name", "")) == "_discovery":
			tracker = _main.get("_discovery")
			break
	if tracker is not Discovery:
		_fail("CAPABILITY 3 IS PARSER-ONLY: the production boot owns no Discovery tracker")
		return
	var shipped := _shipped_discoveries()
	if shipped.is_empty():
		_fail("shipped_discoveries.txt is missing, malformed, or empty — no live discovery mappings can be guarded")
		return
	for name: String in shipped:
		if not (tracker as Discovery).is_registered(name):
			_fail("shipped discovery '%s' has no live point-of-interest registration" % name)
			return
		var registrations: Variant = (tracker as Discovery).get("_pois")
		if registrations is not Dictionary:
			_fail("Discovery does not expose its registrations to the boot guard")
			return
		var poi: Variant = (registrations as Dictionary).get(name)
		if poi is not Dictionary or (poi as Dictionary).get("center") is not Vector3:
			_fail("shipped discovery '%s' has no inspectable registered centre" % name)
			return
		var expected = _discovery_landmark_point(String(shipped[name]), world)
		if expected == null:
			_fail("shipped discovery '%s' has an unreadable ledgered landmark '%s'"
				% [name, String(shipped[name])])
			return
		var registered_center: Vector3 = (poi as Dictionary)["center"]
		if registered_center.distance_to(expected) > EPS:
			_fail(("SHIPPED DISCOVERY REPOINTED (no-resets law): '%s' is registered at %s, "
				+ "but its permanent '%s' landmark is %s")
				% [name, str(registered_center), String(shipped[name]), str(expected)])
			return
	if (tracker as Discovery).total() != shipped.size():
		_fail("the production boot registers an unledgered discovery id")
		return
	var expected: Array[String] = ["future_place", "starter_cave", "wardens_shrine"]
	if (tracker as Discovery).discovered() != expected:
		_fail("the production boot did not restore the vault-v2 set and observe the starter cave")
		return
	if not _save.real_save_untouched():
		_fail("the discovery restore boot touched the player's real save or vault")
		return
	_begin_discovery_writer_boot()


## The production scene must have created a v2 vault through the public writer,
## not merely changed its in-memory tracker. Both stable shipped ids are exact
## assertions so a renamed place cannot silently strand a player's history.
func _assert_discovery_write() -> void:
	var vault = SaveVault.load_saved()
	if vault is not Dictionary:
		_fail("the production discovery boot wrote no readable vault")
		return
	if vault.get("version") != SaveVault.VAULT_VERSION:
		_fail("the production discovery boot did not activate vault-v2 writes")
		return
	var expected: Array[String] = ["starter_cave", "wardens_shrine"]
	if vault.get("discoveries", []) != expected:
		_fail("the cave-to-shrine walk did not persist both stable discovery ids exactly")
		return

	# Reboot without clearing the probes. The wanderer returns to the cave, so
	# wardens_shrine cannot be rediscovered by proximity in the second scene.
	_discovery_phase = "reboot"
	_ticks = 0
	_main.queue_free()
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(_main)


func _assert_discovery_reboot(player: Player, world: WorldGen) -> void:
	if player.global_position.distance_to(world.shrine_respawn_point()) <= WorldGen.SHRINE_CLEAR_RADIUS:
		_fail("VACUOUS TEST: the rebooted wanderer is still close enough to rediscover the shrine")
		return
	var tracker: Variant = null
	for property: Dictionary in _main.get_property_list():
		if String(property.get("name", "")) == "_discovery":
			tracker = _main.get("_discovery")
			break
	if tracker is not Discovery or not (tracker as Discovery).is_discovered("wardens_shrine"):
		_fail("the shrine discovered before logout was not restored by the real reboot")
		return
	if not _save.real_save_untouched():
		_fail("the discovery writer/reboot touched the player's real save or vault")
		return
	_begin_discovery_retry_boot()


func _assert_discovery_retry() -> void:
	var vault = SaveVault.load_saved()
	if vault is not Dictionary:
		_fail("a transient first write failure was never retried after the vault became writable")
		return
	if vault.get("discoveries", []) != ["starter_cave"]:
		_fail("the retried discovery write did not persist exactly the cave: %s" % str(vault))
		return
	if not _save.real_save_untouched():
		_fail("the transient discovery retry touched the player's real save or vault")
		return
	_cleanup_retry_probe()
	_begin_discovery_drift_boot()


func _assert_discovery_drift() -> void:
	var vault = SaveVault.load_saved()
	if vault is not Dictionary:
		_fail("the cloud-synced replacement left no readable vault")
		return
	if "wardens_shrine" not in vault.get("discoveries", []):
		_fail(("a rollback-only in-memory id blocked the newly found shrine from reaching disk: %s")
			% str(vault))
		return
	if not _save.real_save_untouched():
		_fail("the cloud-synced discovery boot touched the player's real save or vault")
		return
	print(("TEST PASS — %d shipped attunement(s) and vault-v2 discovery state survive "
		+ "a logout, transient writes retry, and rollback-only ids cannot poison known writes "
		+ "(control woke at %s)")
		% [_restored, str(_control_spawn)])
	get_tree().quit(0)


## The landmark a shipped name MUST lead to, derived straight from the world so
## it is independent of RespawnPoints. Null when the name has no oracle entry.
func _oracle_point(name: String, world: WorldGen) -> Variant:
	if not DESTINATION_ORACLE.has(name):
		return null
	match String(DESTINATION_ORACLE[name]):
		"shrine":
			return world.shrine_respawn_point()
	return null


## Resolve an immutable ledger landmark straight from WorldGen, independently
## of Main's registration under test.
func _discovery_landmark_point(landmark: String, world: WorldGen) -> Variant:
	match landmark:
		"cave":
			return world.cave_spawn_point()
		"shrine_interactable":
			return world.shrine_interactable().global_position
	return null


## The shipped live-name ledger — the same file the guard test anchors, read
## here so this test exercises exactly the names that have shipped.
func _shipped_attunements() -> Array:
	var file := FileAccess.open("res://tests/data/shipped_attunements.txt", FileAccess.READ)
	if file == null:
		return []
	var names := []
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		names.append(line)
	file.close()
	return names


func _shipped_discoveries() -> Dictionary:
	var file := FileAccess.open(SHIPPED_DISCOVERIES, FileAccess.READ)
	if file == null:
		return {}
	var mappings := {}
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var parts := line.split("=", false, 1)
		if parts.size() != 2:
			return {}
		var name := String(parts[0]).strip_edges()
		var landmark := String(parts[1]).strip_edges()
		if name.is_empty() or landmark.is_empty() or mappings.has(name):
			return {}
		mappings[name] = landmark
	file.close()
	return mappings


func _cleanup_retry_probe() -> void:
	for path in [RETRY_VAULT + ".tmp", RETRY_VAULT]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(RETRY_PROBE_DIR))


func _fail(message: String) -> void:
	if _save != null:
		_save.end()
	_cleanup_retry_probe()
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _exit_tree() -> void:
	if _save != null:
		_save.end()
	_cleanup_retry_probe()
