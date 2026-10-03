extends PersistenceScenario
## Uses the real ledger, vault and filesystem. A directory standing where the
## vault's parent should be makes writes fail without mocking persistence.

func _ready() -> void:
	if not SaveContractStage.refusal_reason().is_empty():
		_fail(SaveContractStage.refusal_reason())
		return
	if UpdateManifest.SAVE_CAPABILITY_WRITES == 6:
		# The retained reader has no mutation owner yet. Its complete restoration
		# and ordinary-write behavior run in mastery_vault_reader_test at both stages.
		print("TEST PASS — retained reader stage does not advertise mastery writes")
		get_tree().quit(0)
		return
	if not ResourceLoader.exists("res://scripts/mastery_persistence.gd"):
		_fail("no runtime owner persists and retries mastery changes")
		return
	if not _begin("user://mastery_persistence_probe.json"):
		return
	SaveVault.clear_refusals_for_test()
	var ledger := Mastery.new()
	var persistence := load("res://scripts/mastery_persistence.gd")
	var writer: RefCounted = persistence.new(ledger, null)
	_check(not SaveVault.exists(), "constructing the writer originated empty mastery")
	ledger.accrue("sword", 250)
	_check(_stored() == _snapshot(200, 50, {}), "accrual was not durable before returning to play")
	ledger.die(50)
	_check(_stored() == _snapshot(200, 25, {"sword": 25}), "death did not persist its entire transfer")
	ledger.accrue("sword", 80)
	ledger.reclaim()
	_check(_stored() == _snapshot(300, 30, {}), "reclaim did not persist banking and consumption together")
	# A second owner starts from the same document. Its earlier observation is
	# no longer permission to replace the first owner's subsequent award.
	var other := Mastery.new()
	other.restore(_stored())
	var stale_writer: RefCounted = persistence.new(other, _stored())
	ledger.accrue("sword", 5)
	other.accrue("sword", 9)
	stale_writer.call("tick", 1000.0)
	other.die(100)
	_check(_stored() == _snapshot(300, 35, {}), "stale owner retried over the newer mastery")
	_check_transient_failure(ledger, writer)
	_check_conflict_after_retry(ledger, writer, persistence)
	_check_retry_ceiling(ledger, writer)
	_finish("mastery persists synchronously, retries boundedly, and fences stale owners",
		"persistence test touched real player state")


func _check_transient_failure(ledger: Mastery, writer: RefCounted) -> void:
	var path := SaveVault.vault_path()
	var blocked_path := path + ".missing-parent/vault.json"
	# Preserve the actual snapshot while redirecting to an absent parent. The
	# retry must use the same baseline and latest live state when storage returns.
	OS.set_environment("WAR_VAULT_PATH", blocked_path)
	ledger.die(50)
	ledger.accrue("sword", 10)
	writer.call("tick", 0.5)
	_check(not FileAccess.file_exists(blocked_path), "unavailable storage appeared writable")
	OS.set_environment("WAR_VAULT_PATH", path)
	writer.call("tick", 0.0)
	_check(_stored() == _snapshot(300, 35, {}), "new awards bypassed the retry backoff")
	writer.call("tick", 0.5)
	_check(_stored() == _snapshot(300, 28, {"sword": 17}),
		"retry lost or replayed mutations made while storage was unavailable")
	ledger.reclaim()
	_check(_stored() == _snapshot(300, 45, {}), "reclaim after retry duplicated or lost points")
	writer.call("tick", 1000.0)
	_check(_stored() == _snapshot(300, 45, {}), "idle retry replayed a completed mutation")
	# A clean logout gets one final attempt even while backoff is pending.
	OS.set_environment("WAR_VAULT_PATH", blocked_path)
	ledger.accrue("sword", 5)
	OS.set_environment("WAR_VAULT_PATH", path)
	if not writer.has_method("flush"):
		_fail("logout cannot flush pending mastery when storage has recovered")
		return
	writer.call("flush")
	_check(_stored() == _snapshot(300, 50, {}), "logout lost a pending award after storage recovered")


func _check_conflict_after_retry(ledger: Mastery, writer: RefCounted, persistence: Script) -> void:
	var other := Mastery.new()
	other.restore(_stored())
	var stale: RefCounted = persistence.new(other, _stored())
	var notices: Array[bool] = []
	stale.connect("saving_failed", func(conflict: bool) -> void: notices.append(conflict))
	var path := SaveVault.vault_path()
	OS.set_environment("WAR_VAULT_PATH", path + ".missing-parent/vault.json")
	other.accrue("sword", 1)
	OS.set_environment("WAR_VAULT_PATH", path)
	ledger.accrue("sword", 2)
	_check(_stored() == _snapshot(300, 52, {}), "successful flush left a stale retry delay on later awards")
	writer.call("flush")
	stale.call("tick", 1.0)
	_check(notices == [false, true], "transient warning hid the later permanent session conflict")
	_check(_stored() == _snapshot(300, 52, {}), "conflict after a retry overwrote newer mastery")
	stale.call("flush")
	_check(_stored() == _snapshot(300, 52, {}), "logout flush revived a conflicted writer")
	# Restoring older disk bytes must not reopen this session's permission to
	# write. Otherwise a missing permanent fence hides behind another CAS refusal.
	var winning := SaveVault.load_saved() as Dictionary
	var restored := winning.duplicate(true)
	restored["mastery"] = _snapshot(300, 50, {})
	_check(SaveVault.save_to(SaveVault.vault_path(), restored), "could not seed restored disk history")
	stale.call("flush")
	other.accrue("sword", 10)
	stale.call("tick", 1000.0)
	stale.call("flush")
	_check(SaveVault.load_saved() == restored,
		"restored disk history or later awards revived a permanently conflicted writer")
	_check(SaveVault.save_to(SaveVault.vault_path(), winning), "could not restore the winning session")


## Drive real storage refusals across every backoff boundary, including two
## capped intervals. Temporarily available storage exposes premature retries.
func _check_retry_ceiling(ledger: Mastery, writer: RefCounted) -> void:
	var path := SaveVault.vault_path()
	var blocked_path := path + ".missing-parent/vault.json"
	var before := _stored()
	OS.set_environment("WAR_VAULT_PATH", blocked_path)
	ledger.accrue("sword", 1)
	var intervals := [1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0]
	for index in intervals.size():
		OS.set_environment("WAR_VAULT_PATH", path)
		writer.call("tick", intervals[index] - 0.125)
		_check(_stored() == before, "mastery retried before its backoff boundary")
		if index < intervals.size() - 1:
			OS.set_environment("WAR_VAULT_PATH", blocked_path)
		writer.call("tick", 0.125)
		if index < intervals.size() - 1:
			# Coalesce a new award without resetting the outstanding delay.
			ledger.accrue("sword", 1)
	OS.set_environment("WAR_VAULT_PATH", path)
	_check(_stored() == _snapshot(300, 59, {}),
		"retry exceeded the 30-second ceiling or lost coalesced awards")
	# Success resets the next refusal to one second, even after reaching the cap.
	OS.set_environment("WAR_VAULT_PATH", blocked_path)
	ledger.accrue("sword", 1)
	OS.set_environment("WAR_VAULT_PATH", path)
	writer.call("tick", 0.875)
	_check(_stored() == _snapshot(300, 59, {}), "new refusal skipped its initial retry delay")
	writer.call("tick", 0.125)
	_check(_stored() == _snapshot(300, 60, {}), "successful retry did not reset the delay")


func _stored() -> Dictionary:
	var vault = SaveVault.load_saved()
	return vault.get("mastery", {}) if vault is Dictionary else {}


func _snapshot(banked: int, unbanked: int, stain: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify({
		"weapons": {"sword": {"banked": banked, "unbanked": unbanked}}, "bloodstain": stain}))
