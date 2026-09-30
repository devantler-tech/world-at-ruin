extends Node
## Real launch-path proof: no helper is allowed to stand in for Main's ownership
## of saving and restoring the ledger. The seed is independent of the new writer;
## no shutdown callback gets a chance to save the mutations under examination.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"

var _save: SaveIsolation
var _main: Node
var _failed := false
var _expected_vault: Dictionary


func _ready() -> void:
	if not SaveContractStage.refusal_reason().is_empty():
		_fail(SaveContractStage.refusal_reason())
		return
	_save = SaveIsolation.new("user://mastery_persistence_boot_probe.json")
	if not _save.begin():
		_fail("save isolation failed")
		return
	SaveVault.clear_refusals_for_test()
	var previous := {
		"version": 5, "comment": "progress from before mastery activation",
		"attuned": ["wardens_shrine", "future_shrine"],
		"discoveries": ["starter_cave", "wardens_shrine", "future_place"],
		"reward_claims": ["wardens_shrine", "future_reward"],
		"quests": {"future_quest": {"future_objective": 9007199254740991}},
		"mastery": {"weapons": {"sword": {"banked": 200.0, "unbanked": 50.0}}, "bloodstain": {}},
	}
	_expected_vault = previous.duplicate(true)
	if not SaveVault.save_to(SaveVault.vault_path(), previous):
		_fail("could not persist the previous waking")
		return
	_main = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	add_child(_main)
	await get_tree().process_frame
	var ledger: Mastery = _main.get("_mastery")
	if ledger.banked("sword") != 200 or ledger.unbanked("sword") != 50:
		_fail("real boot did not restore the previous waking")
		return
	if UpdateManifest.SAVE_CAPABILITY_WRITES == 6:
		# A writer may not hide behind reader-only metadata to avoid the
		# activation probes. The retained reader must carry, not mutate, v5 state.
		ledger.accrue("sword", 7)
		_main.free()
		_main = null
		if not _vault_equals(previous):
			_fail("the retained reader changed seeded progression while advertising capability 6")
			return
		if not _save.real_save_untouched():
			_fail("retained reader boot touched real player state")
			return
		_save = null
		print("TEST PASS — retained reader boots and restores mastery before writer activation")
		get_tree().quit(0)
		return
	ledger.die(50)
	ledger.accrue("sword", 80)
	ledger.reclaim()
	ledger.die(50)
	ledger.die(100)
	if not _has_snapshot({
		"weapons": {"sword": {"banked": 300.0, "unbanked": 0.0}},
		"bloodstain": {"sword": 15.0},
	}):
		_fail("real death replacement lost existing progression or the expected mastery")
		return
	if ledger.reclaim() != 15 or ledger.reclaim() != 0:
		_fail("real boot duplicated the standing stain")
		return
	if not _has_snapshot({
		"weapons": {"sword": {"banked": 300.0, "unbanked": 15.0}}, "bloodstain": {},
	}):
		_fail("real boot's reclaim lost existing progression or was not durable")
		return
	# A temporary failure must recover through Main's ordinary frame processing,
	# without this harness constructing the owner or calling its retry method.
	var path := SaveVault.vault_path()
	OS.set_environment("WAR_VAULT_PATH", path + ".missing-parent/vault.json")
	ledger.accrue("sword", 5)
	OS.set_environment("WAR_VAULT_PATH", path)
	await get_tree().create_timer(1.25).timeout
	await get_tree().process_frame
	if not _has_saved_points(20):
		_fail("Main did not retry pending mastery through ordinary frame processing")
		return
	# Exit before the retry window: only Main's exit callback can flush this.
	OS.set_environment("WAR_VAULT_PATH", path + ".missing-parent/vault.json")
	ledger.accrue("sword", 7)
	OS.set_environment("WAR_VAULT_PATH", path)
	_main.free()
	_main = null
	if not _has_saved_points(27):
		_fail("Main did not flush pending mastery on clean exit")
		return
	_main = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	add_child(_main)
	await get_tree().process_frame
	var restored: Mastery = _main.get("_mastery")
	if restored.banked("sword") != 300 or restored.unbanked("sword") != 27 \
			or not restored.bloodstain().is_empty() or not _has_saved_points(27):
		_fail("reboot lost existing progression or the mastery committed by Main")
		return
	if not await _check_visible_conflict(restored):
		return
	if not _save.real_save_untouched():
		_fail("boot persistence touched real player state")
		return
	_save = null
	if _failed:
		return
	print("TEST PASS — real boot preserves mastery through mutation, retry, exit and reboot")
	get_tree().quit(0)


func _has_saved_points(unbanked: int) -> bool:
	return _has_snapshot({
		"weapons": {"sword": {"banked": 300.0, "unbanked": float(unbanked)}}, "bloodstain": {},
	})


## Compare the whole independent seed, including rollback-only names and exact
## quest counters, so a mastery-only replacement cannot pass this launch proof.
func _has_snapshot(mastery: Dictionary) -> bool:
	var expected := _expected_vault.duplicate(true)
	expected["mastery"] = mastery
	return _vault_equals(expected)


## Parsed JSON numbers are floats; compare exact canonical values instead of
## treating an in-memory integer and its parsed representation as different.
func _vault_equals(expected: Dictionary) -> bool:
	var actual := JCS.canonicalize(SaveVault.load_saved())
	var wanted := JCS.canonicalize(expected)
	return actual["error"].is_empty() and wanted["error"].is_empty() \
		and actual["text"] == wanted["text"]


## Observe the real HUD after a second session wins. A test-local signal
## listener cannot prove that Main tells the player how to recover.
func _check_visible_conflict(ledger: Mastery) -> bool:
	var hud: Node = _main.get("_hud")
	var toast: Label = hud.get("_toast")
	if toast.text.contains("Another session changed your mastery"):
		_fail("healthy boot showed a permanent mastery conflict")
		return false
	var path := SaveVault.vault_path()
	OS.set_environment("WAR_VAULT_PATH", path + ".missing-parent/vault.json")
	ledger.accrue("sword", 10)
	OS.set_environment("WAR_VAULT_PATH", path)
	if not toast.is_visible_in_tree() or toast.modulate.a <= 0.01 \
			or not toast.text.contains("may not remember next waking"):
		_fail("Main did not show the temporary mastery save failure")
		return false
	var newer := SaveVault.load_saved() as Dictionary
	newer["mastery"]["weapons"]["sword"]["unbanked"] = 28.0
	if not SaveVault.save_to(SaveVault.vault_path(), newer):
		_fail("could not seed the second session's committed award")
		return false
	await get_tree().create_timer(1.25).timeout
	await get_tree().process_frame
	if not toast.is_visible_in_tree() or toast.modulate.a <= 0.01 \
			or not toast.text.contains("Another session changed your mastery") \
			or not toast.text.contains("cannot save further mastery") \
			or not toast.text.contains("reopen the game"):
		_fail("Main did not show the permanent save conflict and recovery action on its HUD")
		return false
	_main.free()
	_main = null
	if not _vault_equals(newer):
		_fail("exiting the conflicted Main overwrote the second session's progression")
		return false
	return true


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
