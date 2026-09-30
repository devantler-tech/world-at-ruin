extends Node
## A real foreign holder excludes the WHOLE mastery transaction, not only its
## final rename. Recovery preserves the other process's unrelated progression.

const WAIT_MSEC := 15000
const PROOF_ENV := "WAR_MASTERY_LOCK_PROBE"

var _failed := false
var _save: SaveIsolation
var _child_pid := -1


func _ready() -> void:
	if OS.get_cmdline_user_args() == PackedStringArray(["--mastery-lock-child"]):
		await _child()
		return
	if not ResourceLoader.exists("res://scripts/mastery_persistence.gd"):
		_fail("mastery has no retrying persistence owner")
		return
	_save = SaveIsolation.new("user://mastery_lock_process_probe.json")
	if not _save.begin():
		_fail("save isolation failed")
		return
	SaveVault.clear_refusals_for_test()
	var path := SaveVault.vault_path()
	var old := {
		"version": 4, "attuned": ["future_shrine"], "discoveries": ["future_place"],
		"reward_claims": ["future_reward"], "quests": {"future_quest": {"arrive": 12}},
	}
	_check(SaveVault.save_to(path, old), "could not seed prior progress")
	var ledger := Mastery.new()
	var writer: RefCounted = load("res://scripts/mastery_persistence.gd").new(ledger, null)
	var notices: Array[bool] = []
	writer.connect("saving_failed", func(conflict: bool) -> void: notices.append(conflict))
	OS.set_environment(PROOF_ENV, path)
	_child_pid = OS.create_process(OS.get_executable_path(), [
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"res://tests/mastery_lock_process_test.tscn", "--", "--mastery-lock-child",
	])
	if _child_pid <= 0 or not await _wait_for(path + ".ready"):
		_fail("foreign lock holder never became ready")
		return
	var before := FileAccess.get_sha256(path)
	var stamp := FileLock.owner_path(FileLock.path_for(path))
	var owner := FileAccess.get_sha256(stamp)
	_check(not owner.is_empty(), "child did not publish a real ownership stamp")
	SaveVault._last_write_expectation = SaveVault.IDENTITY_UNCHECKED
	ledger.accrue("sword", 25)
	ledger.accrue("sword", 10)
	_check(notices == [false], "contention was not reported as a transient refusal")
	_check(SaveVault._last_write_expectation == SaveVault.IDENTITY_UNCHECKED,
		"mastery entered guarded replacement without owning the whole transaction")
	var foreign_expected := {"weapons": {"sword": {"banked": 100, "unbanked": 0}}, "bloodstain": {}}
	_check(SaveVault.new().call("persist_mastery", ledger.snapshot(), foreign_expected) == ERR_BUSY,
		"mastery compared a stale observation before acquiring the foreign-held lock")
	_check(FileAccess.get_sha256(path) == before, "contending mastery changed the vault")
	_check(FileAccess.get_sha256(stamp) == owner, "contending mastery changed the child's ownership")
	_mark(path + ".release")
	if not await _wait_for(path + ".released"):
		_fail("foreign holder did not release its lock")
		return
	await _join_child()
	writer.call("tick", 0.5)
	_check(FileAccess.get_sha256(path) == before, "recovery bypassed the pending backoff")
	writer.call("tick", 0.5)
	var wanted := old.duplicate(true)
	wanted["version"] = 5
	wanted["quests"]["future_quest"]["arrive"] = 21
	wanted["mastery"] = {"weapons": {"sword": {"banked": 0, "unbanked": 35}}, "bloodstain": {}}
	_check(JCS.canonicalize(SaveVault.load_saved())["text"] == JCS.canonicalize(wanted)["text"],
		"recovered mastery lost foreign progress or replayed a pending award")
	before = FileAccess.get_sha256(path)
	writer.call("tick", 1000.0)
	writer.call("flush")
	_check(FileAccess.get_sha256(path) == before, "acknowledged recovery replayed mastery")
	_check(_save.real_save_untouched(), "foreign-process probe touched player state")
	_cleanup_markers(path)
	OS.unset_environment(PROOF_ENV)
	_save = null
	if _failed:
		return
	print("TEST PASS — foreign-process contention excludes the whole mastery transaction and recovers once")
	get_tree().quit(0)


func _child() -> void:
	var path := OS.get_environment(PROOF_ENV)
	if path.is_empty() or path != SaveVault.vault_path():
		_fail("foreign child has no inherited isolated path proof")
		return
	if not SaveVault.persist_quests({"future_quest": {"arrive": 21}}) or not FileLock.acquire(path):
		_fail("foreign child could not commit progress and acquire the lock")
		return
	_mark(path + ".ready")
	var released := await _wait_for(path + ".release")
	FileLock.release(path)
	if not released:
		_fail("foreign child timed out awaiting release")
		return
	_mark(path + ".released")
	get_tree().quit(0)


func _wait_for(path: String) -> bool:
	var deadline := Time.get_ticks_msec() + WAIT_MSEC
	while not FileAccess.file_exists(path):
		if Time.get_ticks_msec() >= deadline:
			return false
		await get_tree().process_frame
	return true


func _join_child() -> void:
	var deadline := Time.get_ticks_msec() + WAIT_MSEC
	while _child_pid > 0 and OS.is_process_running(_child_pid):
		if Time.get_ticks_msec() >= deadline:
			_fail("foreign child did not terminate after release")
			return
		await get_tree().process_frame
	_child_pid = -1


func _mark(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("could not publish process handshake")
		return
	file.store_string("ready")
	file.close()


func _cleanup_markers(path: String) -> void:
	for suffix: String in [".ready", ".release", ".released"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path + suffix))


func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failed = true
	push_error("TEST FAIL — " + message)
	get_tree().quit(1)


func _exit_tree() -> void:
	if _child_pid > 0 and OS.is_process_running(_child_pid):
		OS.kill(_child_pid)
	if _save != null:
		_cleanup_markers(SaveVault.vault_path())
		OS.unset_environment(PROOF_ENV)
		if not _save.real_save_untouched():
			push_error("TEST FAIL — process teardown touched player state")
