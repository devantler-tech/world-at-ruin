extends Node
## Uses the real ledger, vault and filesystem. A directory standing where the
## vault's parent should be makes writes fail without mocking persistence.

var _failed := false
var _save: SaveIsolation


func _ready() -> void:
	if not ResourceLoader.exists("res://scripts/mastery_persistence.gd"):
		_fail("no runtime owner persists and retries mastery changes")
		return
	_save = SaveIsolation.new("user://mastery_persistence_probe.json")
	if not _save.begin():
		_fail("save isolation failed")
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
	_check(_save.real_save_untouched(), "persistence test touched real player state")
	_save = null
	if _failed:
		return
	print("TEST PASS — mastery persists synchronously, retries boundedly, and fences stale owners")
	get_tree().quit(0)


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


func _stored() -> Dictionary:
	var vault = SaveVault.load_saved()
	return vault.get("mastery", {}) if vault is Dictionary else {}


func _snapshot(banked: int, unbanked: int, stain: Dictionary) -> Dictionary:
	return JSON.parse_string(JSON.stringify({
		"weapons": {"sword": {"banked": banked, "unbanked": unbanked}}, "bloodstain": stain}))


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
			push_error("TEST FAIL — mastery persistence teardown detected real player-state changes")
