extends Node
## The real Main boot owns both the trial status and its once-only live marker.
## Fixtures are used only in this deterministic regression. Live user-path
## acceptance runs the native TLS socket against the actual Go zone separately.

const ConnectionTests := preload("res://tests/zone_connection_test.gd")
const FIXTURE := "res://tests/data/wire_goldens.json"
const ENV_NAMES := ["WAR_ZONE_URL", "WAR_ZONE_TOKEN", "WAR_ZONE_TLS_SERVER_NAME"]

var _boot: IsolatedBoot
var _main: Node
var _environment: Dictionary = {}
var _failed := false


func _ready() -> void:
	for name: String in ENV_NAMES:
		_environment[name] = OS.get_environment(name)
		OS.set_environment(name, "")
	_boot = IsolatedBoot.new("user://zone_trial_boot_probe.json")
	_main = _boot.boot()
	if _main == null:
		_fail("save isolation did not take")
		return
	add_child(_main)
	await get_tree().process_frame
	var hud := _main.get("_hud") as Hud
	if hud == null or hud.get_node_or_null("ZoneTrialStatus") != null or _main.get("_zone") != null:
		_fail("ordinary boot must have no trial connection or status label")
		return
	if not hud.has_method("update_zone_trial_status") or not _main.has_method("_update_zone_trial_status"):
		_fail("the real Main scene does not drive the trial connection status")
		return
	# Admission refusal is deliberate: there is no token and no network attempt.
	OS.set_environment("WAR_ZONE_URL", "wss://trial.example.test/zone")
	_main.call("_connect_zone")
	var label := hud.get_node_or_null("ZoneTrialStatus") as Label
	if label == null or not label.text.contains("disconnected"):
		_fail("a refused opt-in connection must leave a persistent disconnected status")
		return
	OS.set_environment("WAR_ZONE_TOKEN", "fixture-token")
	var transport := ConnectionTests.FakeTransport.new()
	var zone := ZoneConnection.new(transport)
	if not zone.connect_to("wss://trial.example.test/zone"):
		_fail("the controlled transport could not begin connecting")
		return
	_main.set("_zone", zone)
	_main.call("_process", 0.0)
	if label.text != "Private server trial · connecting…":
		_fail("Main must publish the connecting state")
		return
	transport.ready_state = WebSocketPeer.STATE_OPEN
	_main.call("_process", 0.0)
	if label.text != "Private server trial · waiting for world data" or bool(_main.get("_zone_trial_live_reported")):
		_fail("socket-open alone must never claim receipt of live world data")
		return
	var golden: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	if not golden is Dictionary:
		_fail("the cross-tier stream fixture could not be read")
		return
	var frames: Array = (golden["stream"] as Dictionary)["frames"]
	transport.packets.append((frames[0]["hex"] as String).hex_decode())
	_main.call("_process", 0.0)
	if label.text != "Private server trial · live · tick 0 · 2 entities" or not bool(_main.get("_zone_trial_live_reported")):
		_fail("the first applied snapshot must activate the live status and its marker, including tick zero")
		return
	transport.packets.append((frames[1]["hex"] as String).hex_decode())
	transport.packets.append((frames[2]["hex"] as String).hex_decode())
	_main.call("_process", 0.0)
	if label.text != "Private server trial · live · tick 2 · 1 entities":
		_fail("Main must update the applied tick and actual replica count as the stream changes")
		return
	_main.call("_process", 0.0)
	if not bool(_main.get("_zone_trial_live_reported")):
		_fail("the live marker must remain claimed after later frames")
		return
	transport.packets.append(PackedByteArray([255]))
	_main.call("_process", 0.0)
	if zone.state() != ZoneConnection.State.FAILED or not zone.store().has_base() or not label.text.contains("disconnected"):
		_fail("a refused stream must show disconnected even while its last consistent snapshot is retained")
		return
	var closed_transport := ConnectionTests.FakeTransport.new()
	var closed_zone := ZoneConnection.new(closed_transport)
	closed_zone.connect_to("wss://trial.example.test/zone")
	closed_transport.ready_state = WebSocketPeer.STATE_OPEN
	closed_transport.packets.append((frames[0]["hex"] as String).hex_decode())
	closed_zone.poll()
	_main.set("_zone", closed_zone)
	closed_transport.closing_polls = 3
	closed_transport.close()
	_main.call("_process", 0.0)
	if closed_zone.state() != ZoneConnection.State.CLOSING or not label.text.contains("disconnected"):
		_fail("a peer beginning its close handshake after live data must immediately stop claiming LIVE")
		return
	_main.call("_process", 0.0)
	_main.call("_process", 0.0)
	if closed_zone.state() != ZoneConnection.State.CLOSED:
		_fail("the peer's close handshake must keep being pumped until CLOSED")
		return
	if not label.text.contains("disconnected") or not label.text.contains("relaunch"):
		_fail("a formerly live stream must show its stopped state and real recovery action")
		return
	await _finish()


func _fail(message: String) -> void:
	if _failed:
		return
	_failed = true
	print("TEST FAIL — " + message)
	if _main != null:
		_main.queue_free()
		await get_tree().process_frame
		_main = null
	if _boot != null and not _boot.real_save_untouched():
		print("TEST FAIL — trial HUD evaluation touched a real save seam")
	_restore_environment()
	get_tree().quit(1)


func _finish() -> void:
	if _main != null:
		_main.queue_free()
		await get_tree().process_frame
		_main = null
	if _boot != null and not _boot.real_save_untouched():
		_fail("trial HUD evaluation touched a real save seam")
		return
	_restore_environment()
	print("TEST PASS — Main leaves ordinary boots unchanged and drives provisional, live, advancing, refused and disconnected trial states from the real connection pump")
	get_tree().quit(0)


func _restore_environment() -> void:
	for name: String in _environment:
		OS.set_environment(name, _environment[name] as String)
