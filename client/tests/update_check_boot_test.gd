extends Node
## The real game starts checks after boot; test isolation suppresses ambient opt-in.
var _boot: SaveIsolation
var _main: Node
var _before_enable := ""
var _before_config := ""
var _before_history := ""


func _ready() -> void:
	_before_enable = OS.get_environment("WAR_UPDATE_CHECK")
	_before_config = OS.get_environment("WAR_UPDATE_CHECK_CONFIG")
	_before_history = OS.get_environment(UpdateHistory.PATH_ENV)
	OS.set_environment("WAR_UPDATE_CHECK", "1")
	OS.set_environment("WAR_UPDATE_CHECK_CONFIG", "user://must-not-contact-origin.json")
	OS.set_environment(UpdateHistory.PATH_ENV, "user://must-not-touch-update-history.json")
	_boot = SaveIsolation.new("user://update_check_boot_probe.json")
	if not _boot.begin():
		_fail("isolated boot was refused")
		return
	var scene: PackedScene = load("res://scenes/main.tscn")
	_main = scene.instantiate()
	if OS.get_environment("WAR_UPDATE_CHECK") == "1" or UpdateHistory.history_path() == "user://must-not-touch-update-history.json":
		_fail("save isolation left ambient update networking enabled")
		return
	add_child(_main)
	await get_tree().process_frame
	if not _has_property(_main, "_update_check_result"):
		_fail("real installed boot has no update-check completion")
		return
	if not (_main.get("_update_check_result") as Dictionary).is_empty():
		_fail("disabled boot started an update check")
		return
	_main.queue_free()
	await get_tree().process_frame
	# Explicit test opt-in after every save seam has been redirected.
	OS.set_environment("WAR_UPDATE_CHECK", "1")
	OS.set_environment("WAR_UPDATE_CHECK_CONFIG", "user://missing-update-config.process-%d.json" % OS.get_process_id())
	_main = scene.instantiate()
	add_child(_main)
	var deadline := Time.get_ticks_msec() + 30000
	while (_main.get("_update_check_result") as Dictionary).is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	var result: Dictionary = _main.get("_update_check_result")
	if result.is_empty() or result.get("trusted", true) or not is_instance_valid(_main.get_node_or_null("Wanderer")):
		_fail("a refused update check did not leave the actual boot playable")
		return
	_main.queue_free()
	await get_tree().process_frame
	for seam: String in [CharacterStore.SAVE_PATH_ENV, SaveVault.VAULT_PATH_ENV]:
		CharacterStore.clear_refusals_for_test()
		SaveVault.clear_refusals_for_test()
		if not _boot.begin():
			_fail("future-save isolation was refused")
			return
		var path := OS.get_environment(seam)
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string('{"version":999}')
		file.close()
		var before := FileAccess.get_sha256(path)
		OS.set_environment("WAR_UPDATE_CHECK", "1")
		_main = scene.instantiate()
		add_child(_main)
		deadline = Time.get_ticks_msec() + 30000
		while (_main.get("_update_check_result") as Dictionary).is_empty() and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
		result = _main.get("_update_check_result")
		if seam == SaveVault.VAULT_PATH_ENV and _main.get("_save_blocked"):
			_fail("future-vault control was masked by the character refusal latch")
			return
		if result.get("error") != "installed save requirements are unknown" or FileAccess.get_sha256(path) != before:
			_fail("unreadable installed state authorized an update or changed its bytes")
			return
		if not is_instance_valid(_main.get_node_or_null("Wanderer")):
			_fail("unreadable installed state interrupted playable boot")
			return
		_main.queue_free()
		await get_tree().process_frame
	if not _boot.real_save_untouched():
		_fail("experimental update checks changed a real player save")
		return
	if OS.get_environment("WAR_UPDATE_CHECK") != "1" or OS.get_environment("WAR_UPDATE_CHECK_CONFIG") != "user://must-not-contact-origin.json":
		_fail("test isolation did not restore ambient update configuration")
		return
	if UpdateHistory.history_path() != "user://must-not-touch-update-history.json":
		_fail("test isolation did not restore ambient update-history path")
		return
	_restore()
	print("TEST PASS — opt-in update refusal leaves actual isolated game boot playable; ambient checks stay isolated")
	get_tree().quit(0)


func _has_property(object: Object, property: String) -> bool:
	for info: Dictionary in object.get_property_list():
		if info["name"] == property:
			return true
	return false


func _restore() -> void:
	OS.set_environment("WAR_UPDATE_CHECK", _before_enable)
	OS.set_environment("WAR_UPDATE_CHECK_CONFIG", _before_config)
	OS.set_environment(UpdateHistory.PATH_ENV, _before_history)


func _fail(message: String) -> void:
	if is_instance_valid(_main):
		_main.free()
	if _boot != null:
		if not _boot.real_save_untouched():
			message += "; player-save isolation also failed"
	_restore()
	print("TEST FAIL: " + message)
	get_tree().quit(1)
