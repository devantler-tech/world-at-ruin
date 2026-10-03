class_name PersistenceScenario
extends Node
## Synchronous persistence scene lifetime. Child crash paths may use fail/check
## without beginning a scope; their inherited save seams must remain intact.
var _failed := false
var _save: SaveIsolation

func _begin(probe: String) -> bool:
	_save = SaveIsolation.new(probe)
	if not _save.begin():
		_fail("save isolation failed")
		return false
	return true

func _finish(message: String, isolation_message: String) -> void:
	_check(_save.real_save_untouched(), isolation_message)
	_save = null
	if not _failed:
		print("TEST PASS — " + message)
		get_tree().quit(0)

func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _fail(message: String) -> void:
	_failed = true
	push_error("TEST FAIL — " + message)
	get_tree().quit(1)

func _exit_tree() -> void:
	if _save != null and not _save.real_save_untouched():
		_fail("persistence teardown detected real player-state changes")
