extends Node
## The real boot must finish startup before it opens the opt-in zone socket.
## A missing token deliberately refuses admission without a network request.

var _boot: IsolatedBoot
var _main: Node
var _environment: Dictionary = {}
var _failed := false


func _ready() -> void:
	for name: String in ["WAR_ZONE_URL", "WAR_ZONE_TOKEN", "WAR_ZONE_TLS_SERVER_NAME"]:
		_environment[name] = OS.get_environment(name)
		OS.set_environment(name, "")
	OS.set_environment("WAR_ZONE_URL", "wss://trial.example.test/zone")
	_boot = IsolatedBoot.new("user://zone_startup_boot_probe.json")
	_main = _boot.boot()
	if _main == null:
		await _fail("save isolation did not take")
		return
	add_child(_main)
	if _main.get("_zone") != null:
		await _fail("the zone connection started inside synchronous boot")
		return
	# Headless startup has no rendered-frame signal, but must still start the
	# configured connection after boot and refuse its missing admission token.
	for frame: int in range(3):
		await get_tree().process_frame
	var zone := _main.get("_zone") as ZoneConnection
	if zone == null or zone.state() != ZoneConnection.State.FAILED:
		await _fail("headless startup never attempted the configured zone")
		return
	_main.call("_connect_zone")
	if _main.get("_zone") != zone:
		await _fail("startup can replace an already created zone connection")
		return
	await _finish()


func _fail(problem: String) -> void:
	if _failed:
		return
	_failed = true
	if _main != null:
		_main.queue_free()
		await get_tree().process_frame
		_main = null
	if _boot != null and not _boot.real_save_untouched():
		print("TEST FAIL — startup evaluation touched a real save seam")
	_restore_environment()
	print("TEST FAIL — " + problem)
	get_tree().quit(1)


func _finish() -> void:
	if _main != null:
		_main.queue_free()
		await get_tree().process_frame
		_main = null
	if _boot != null and not _boot.real_save_untouched():
		await _fail("startup evaluation touched a real save seam")
		return
	_restore_environment()
	print("TEST PASS — real boot defers its zone connection, starts headlessly and never replaces an existing connection")
	get_tree().quit(0)


func _restore_environment() -> void:
	for name: String in _environment:
		OS.set_environment(name, _environment[name] as String)
