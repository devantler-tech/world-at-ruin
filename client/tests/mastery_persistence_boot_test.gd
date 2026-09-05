extends Node
## Real launch-path proof: no helper is allowed to stand in for Main's ownership
## of saving and restoring the ledger. The prior waking's snapshot comes from
## real ledger mutations; no shutdown callback gets a chance to save for the test.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"

var _save: SaveIsolation
var _main: Node
var _failed := false


func _ready() -> void:
	_save = SaveIsolation.new("user://mastery_persistence_boot_probe.json")
	if not _save.begin():
		_fail("save isolation failed")
		return
	SaveVault.clear_refusals_for_test()
	var previous := Mastery.new()
	previous.accrue("sword", 250)
	if SaveVault.persist_mastery(previous.snapshot(), null) != OK:
		_fail("could not persist the previous waking")
		return
	_main = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	add_child(_main)
	await get_tree().process_frame
	var ledger: Mastery = _main.get("_mastery")
	if ledger.banked("sword") != 200 or ledger.unbanked("sword") != 50:
		_fail("real boot did not restore the previous waking")
		return
	ledger.die(50)
	ledger.accrue("sword", 80)
	ledger.reclaim()
	ledger.die(50)
	ledger.die(100)
	var vault = SaveVault.load_saved()
	if vault["mastery"] != {
		"weapons": {"sword": {"banked": 300.0, "unbanked": 0.0}},
		"bloodstain": {"sword": 15.0},
	}:
		_fail("real death replacement did not discard only the previous standing stain")
		return
	if ledger.reclaim() != 15 or ledger.reclaim() != 0:
		_fail("real boot duplicated the standing stain")
		return
	vault = SaveVault.load_saved()
	if vault["mastery"] != {
		"weapons": {"sword": {"banked": 300.0, "unbanked": 15.0}}, "bloodstain": {},
	}:
		_fail("real boot's reclaim was not durable")
		return
	_main.queue_free()
	await get_tree().process_frame
	if not _save.real_save_untouched():
		_fail("boot persistence touched real player state")
		return
	_save = null
	if _failed:
		return
	print("TEST PASS — real boot restores mastery and persists awards, banking, death and reclaim")
	get_tree().quit(0)


func _fail(message: String) -> void:
	_failed = true
	# Final persistence must finish while every seam still points at the probe.
	if is_instance_valid(_main):
		_main.free()
		_main = null
	if _save != null and not _save.real_save_untouched():
		push_error("TEST FAIL — mastery boot failure path touched real player state")
	_save = null
	push_error("TEST FAIL — " + message)
	get_tree().quit(1)


func _exit_tree() -> void:
	if _save != null:
		if not _save.real_save_untouched():
			push_error("TEST FAIL — mastery boot teardown detected real player-state changes")
