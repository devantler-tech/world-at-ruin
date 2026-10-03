extends PersistenceScenario
func _ready() -> void:
	if not _begin("user://persistence_scope_contract_probe.json"):
		return
	var mode := OS.get_cmdline_user_args()[0]
	if mode == "sticky":
		_check(false, "sticky false assertion")
	else:
		# Change the test-owned captured expectation, never a player file.
		_save.set("_default_before_exists", not _save.get("_default_before_exists"))
	if mode == "teardown":
		get_tree().quit(0)
	else:
		_finish("must not pass", "scope verification failed")
