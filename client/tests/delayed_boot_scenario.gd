class_name DelayedBootScenario
extends Node
## Physics-tick boot lifetime. Owning scenes resolve their required node types
## and retain all world, population and cave assertions.
var _ticks := 0
var _main: Node
var _save: IsolatedBoot

func _boot(probe: String) -> void:
	_save = IsolatedBoot.new(probe)
	_main = _save.boot()
	if _main == null:
		_fail("save isolation did not take — refusing to boot into the real save")
		return
	add_child(_main)

func _advance() -> bool:
	if _main == null:
		return false
	_ticks += 1
	return true

func _nodes_ready(ready: bool, message: String) -> bool:
	if not ready and _ticks > 10:
		_fail(message)
	return ready

func _finish(message: String) -> void:
	if not _save.real_save_untouched():
		_fail("the boot test touched the player's real save")
		return
	print("TEST PASS — " + message)
	get_tree().quit(0)

func _fail(message: String) -> void:
	if _save != null and not _save.real_save_untouched():
		message += " — AND the run touched real player state; the isolation breach outranks the failure above"
	push_error(message)
	print("TEST FAIL — " + message)
	get_tree().quit(1)

func _exit_tree() -> void:
	if _save != null:
		_save.end()
