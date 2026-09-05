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
	_check(SaveVault.persist_mastery(previous.snapshot(), null) == OK,
		"could not persist the previous waking")
	_main = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	add_child(_main)
	await get_tree().process_frame
	var ledger: Mastery = _main.get("_mastery")
	_check(ledger.banked("sword") == 200 and ledger.unbanked("sword") == 50,
		"real boot did not restore the previous waking")
	ledger.die(50)
	ledger.accrue("sword", 80)
	ledger.reclaim()
	ledger.die(50)
	ledger.die(100)
	var vault = SaveVault.load_saved()
	_check(vault["mastery"] == {
		"weapons": {"sword": {"banked": 300.0, "unbanked": 0.0}},
		"bloodstain": {"sword": 15.0},
	}, "real death replacement did not discard only the previous standing stain")
	_check(ledger.reclaim() == 15 and ledger.reclaim() == 0, "real boot duplicated the standing stain")
	vault = SaveVault.load_saved()
	_check(vault["mastery"] == {
		"weapons": {"sword": {"banked": 300.0, "unbanked": 15.0}}, "bloodstain": {},
	}, "real boot's reclaim was not durable")
	_main.queue_free()
	await get_tree().process_frame
	_check(_save.real_save_untouched(), "boot persistence touched real player state")
	_save = null
	if _failed:
		return
	print("TEST PASS — real boot restores mastery and persists awards, banking, death and reclaim")
	get_tree().quit(0)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failed = true
	push_error("TEST FAIL — " + message)
	get_tree().quit(1)


func _exit_tree() -> void:
	if _save != null:
		if not _save.real_save_untouched():
			push_error("TEST FAIL — mastery boot teardown detected real player-state changes")
