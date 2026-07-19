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
##  B. POSITIVE — boot with a vault that has the shrine attuned, and require
##     the respawn point to have MOVED to the shrine's.
##
## Both boots run behind SaveIsolation, so neither the player's character nor
## their real vault is ever read or written (no-resets law).
##
## Run: godot --headless --path client res://tests/vault_restore_boot_test.tscn

const ASSERT_TICK := 30
const EPS := 0.01

var _ticks := 0
var _main: Node
var _save: SaveIsolation
## false = the negative control boot, true = the restore boot.
var _seeded := false
var _control_spawn := Vector3.INF


func _ready() -> void:
	_begin_boot(false)


## Tear down any previous scene, redirect the save seams, optionally seed an
## attuned vault, then boot main.tscn.
func _begin_boot(seeded: bool) -> void:
	_seeded = seeded
	_ticks = 0
	if _main != null:
		_main.queue_free()
		_main = null
	_save = SaveIsolation.new("user://vault_restore_boot_probe.json")
	if not _save.begin():
		_fail("save isolation did not take — refusing to boot into the real save")
		return
	if seeded:
		# Written through the store's own save path, so the test seeds exactly
		# what a real earlier session would have left behind.
		var attuned := SaveVault.attune(SaveVault.empty(), SaveVault.SHRINE_WARDENS)
		if not SaveVault.save_to(SaveVault.vault_path(), attuned):
			_fail("could not seed the vault probe")
			return
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(_main)


func _physics_process(_delta: float) -> void:
	_ticks += 1
	var world := _main.get_node_or_null("World") as WorldGen
	var player := _main.get_node_or_null("Wanderer") as Player
	if world == null or player == null:
		if _ticks > 10:
			_fail("main scene did not build World and Wanderer")
		return
	if _ticks != ASSERT_TICK:
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
		_begin_boot(true)
		return

	# B. Positive: the attuned shrine was restored, so waking is at the shrine
	# and has MOVED from where the control woke.
	if woke_at.distance_to(shrine_point) > EPS:
		_fail(("RESTORE DID NOT HAPPEN: an attuned vault was on disk but the wanderer "
			+ "woke at %s, not the shrine's %s — main.gd is not applying the vault")
			% [str(woke_at), str(shrine_point)])
		return
	if woke_at.distance_to(_control_spawn) <= EPS:
		_fail("the restore boot woke in the same place as the control — nothing changed")
		return

	if not _save.real_save_untouched():
		_fail("the restore boot touched the player's real save or vault")
		return
	print("TEST PASS — an attuned shrine survives a logout (control woke at %s, restored woke at %s)" % [
		str(_control_spawn), str(woke_at)])
	get_tree().quit(0)


func _fail(message: String) -> void:
	if _save != null:
		_save.end()
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _exit_tree() -> void:
	if _save != null:
		_save.end()
