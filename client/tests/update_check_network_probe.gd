extends SceneTree
## Native network proof: fixture authority is explicit; no player state is read.

var _checker: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var path := OS.get_environment("WAR_UPDATE_CHECK_PROBE_FILE")
	if path.is_empty():
		_fail("one public fixture path is required")
		return
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	OS.set_environment("WAR_UPDATE_CHECK", "1")
	_checker = UpdateCheck.new()
	root.add_child(_checker)
	var ca := X509Certificate.new()
	if ca.load_from_string(fixture["tls_ca"]) != OK:
		_fail("fixture CA is unreadable")
		return
	var tls := TLSOptions.client(ca)
	var mode: String = fixture["mode"]
	if mode == "unsafe":
		tls = TLSOptions.client_unsafe()
	elif mode == "override":
		tls = TLSOptions.client(ca, "localhost")
	elif mode == "system_ca":
		tls = null
	elif mode == "disabled":
		OS.set_environment("WAR_UPDATE_CHECK", "0")
	var before := Time.get_ticks_msec()
	if mode == "cancel":
		create_timer(0.05).timeout.connect(_checker.cancel)
	elif mode == "detach":
		create_timer(0.05).timeout.connect(func() -> void: root.remove_child(_checker))
	var result: Dictionary = await _checker.check(fixture["installed"], fixture["config"],
		tls, float(fixture["timeout"]), func() -> String:
			if mode == "slow_clock":
				OS.delay_msec(2100)
			return fixture["observed_at"])
	var elapsed := Time.get_ticks_msec() - before
	if result["trusted"] != fixture["accepted"]:
		_fail("unexpected authentication result: " + str(result["error"]))
		return
	if fixture["accepted"] and result["decision"].get("action") != UpdateDecision.UP_TO_DATE:
		_fail("accepted fixture did not reach the decision core")
		return
	if not fixture["accepted"] and (str(result["error"]).is_empty()
			or not result.get("manifest", {}).is_empty() or not result.get("head", {}).is_empty()):
		_fail("refusal leaked accepted documents")
		return
	if elapsed > 1500 and mode in ["deadline", "cancel"]:
		_fail("bounded check exceeded its whole-operation budget")
		return
	_checker.free()
	print("TEST PASS — native update check " + mode)
	quit(0)


func _fail(message: String) -> void:
	if is_instance_valid(_checker):
		_checker.free()
	print("TEST FAIL: " + message)
	quit(1)
