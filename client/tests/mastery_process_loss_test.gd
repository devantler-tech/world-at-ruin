extends Node
## Kill each writer process after its real mutation returns, without running
## shutdown callbacks. A new process must observe committed value exactly once.

var _failed := false
var _save: SaveIsolation


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() == 2 and args[0] == "--mastery-crash-child":
		_child(args[1])
		return
	if not ResourceLoader.exists("res://scripts/mastery_persistence.gd"):
		_fail("mastery has no durable mutation owner")
		return
	_save = SaveIsolation.new("user://mastery_process_loss_probe.json")
	if not _save.begin():
		_fail("save isolation failed")
		return
	OS.set_environment("WAR_MASTERY_CRASH_PROBE", SaveVault.vault_path())
	for stage: String in ["award", "death", "reclaim", "repeat"]:
		var output: Array = []
		var code := OS.execute(OS.get_executable_path(), [
			"--headless", "--path", ProjectSettings.globalize_path("res://"),
			"res://tests/mastery_process_loss_test.tscn", "--", "--mastery-crash-child", stage,
		], output, true)
		var log := "\n".join(output)
		_check(code != 0 and log.contains("MASTERY_COMMITTED " + stage)
				and not log.contains("TEST FAIL") and not log.contains("SCRIPT ERROR"),
			"child did not commit then terminate abruptly: %s (%d) %s" % [stage, code, log])
		var vault = SaveVault.load_saved()
		if vault is not Dictionary or not vault.has("mastery"):
			_fail("process loss left no committed mastery after " + stage)
			break
		var ledger := Mastery.new()
		_check(ledger.restore(vault["mastery"]), "restart refused committed mastery")
		_check(ledger.banked("sword") == 200, "process loss changed the banked floor")
		_check(ledger.unbanked("sword") == (25 if stage == "death" else 50),
			"process loss lost or duplicated current mastery")
		_check(ledger.bloodstain() == ({"sword": 25} if stage == "death" else {}),
			"process loss left a stale or missing stain")
	OS.unset_environment("WAR_MASTERY_CRASH_PROBE")
	_check(_save.real_save_untouched(), "process test touched real player state")
	_save = null
	if _failed:
		return
	print("TEST PASS — abrupt process loss preserves committed mastery and consumes reclaim once")
	get_tree().quit(0)


func _child(stage: String) -> void:
	if OS.get_environment("WAR_MASTERY_CRASH_PROBE").is_empty() \
			or OS.get_environment("WAR_MASTERY_CRASH_PROBE") != SaveVault.vault_path():
		_fail("child has no isolated save-path proof")
		return
	var ledger := Mastery.new()
	var vault = SaveVault.load_or_empty()
	if vault is not Dictionary:
		_fail("child cannot read prior process state")
		return
	var expected: Variant = vault.get("mastery")
	if expected != null and not ledger.restore(expected):
		_fail("child cannot restore prior process mastery")
		return
	var writer: RefCounted = load("res://scripts/mastery_persistence.gd").new(ledger, expected)
	match stage:
		"award": ledger.accrue("sword", 250)
		"death": ledger.die(50)
		"reclaim": ledger.reclaim()
		"repeat":
			if ledger.reclaim() != 0:
				_fail("restarted process reclaimed an already consumed stain")
				return
		_:
			_fail("unknown process-loss test stage")
			return
	# Keep the mutation owner alive through the assertion, but never ask it to
	# flush: every ordinary mutation already promised synchronous persistence.
	if writer == null or SaveVault.load_saved() is not Dictionary:
		_fail("child has no durable outcome")
		return
	print("MASTERY_COMMITTED " + stage)
	OS.kill(OS.get_process_id())


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
			push_error("TEST FAIL — mastery process teardown detected real player-state changes")
