extends SceneTree
## Native-only fixture probe. Production TLS options are never weakened.

const Predictor = preload("res://scripts/predicted_movement.gd")
var _failed := false


class VerifiedTransport:
	extends RefCounted
	var peer := WebSocketPeer.new()
	var trust: X509Certificate
	var identity := "zone.test"
	var successful_writes := 0

	func connect_to_url(url: String, _options: TLSOptions = null) -> int:
		return peer.connect_to_url(url, TLSOptions.client(trust, identity))

	func poll() -> void:
		peer.poll()

	func get_ready_state() -> int:
		return peer.get_ready_state()

	func get_available_packet_count() -> int:
		return peer.get_available_packet_count()

	func get_packet() -> PackedByteArray:
		return peer.get_packet()

	func was_string_packet() -> bool:
		return peer.was_string_packet()

	func set_inbound_buffer_size(size: int) -> void:
		peer.inbound_buffer_size = size

	func set_outbound_buffer_size(size: int) -> void:
		peer.outbound_buffer_size = size

	func get_current_outbound_buffered_amount() -> int:
		return peer.get_current_outbound_buffered_amount()

	func put_packet(bytes: PackedByteArray) -> int:
		var result := peer.put_packet(bytes)
		if result == OK:
			successful_writes += 1
		return result

	func set_handshake_headers(headers: PackedStringArray) -> void:
		peer.handshake_headers = headers

	func close() -> void:
		peer.close()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("WAR_ZONE_MOVEMENT_PROBE_FILE")))
	if not _check(parsed is Dictionary and parsed.has_all(["url", "token", "certificate", "mode"]), "native movement fixture"):
		return
	var fixture: Dictionary = parsed
	OS.set_environment("WAR_ZONE_TOKEN", fixture["token"])
	OS.unset_environment("WAR_ZONE_TLS_SERVER_NAME")
	OS.set_environment("WAR_ZONE_MOVEMENT", "0" if fixture["mode"] == "retained" else "1")
	var transport := VerifiedTransport.new()
	if not _check(ZoneConnection.new().state() == ZoneConnection.State.DISCONNECTED, "native production transport contract"):
		return
	for method: String in ZoneConnection.REQUIRED_TRANSPORT_METHODS + ZoneConnection.MOVEMENT_TRANSPORT_METHODS:
		if not _check(transport.peer.has_method(method), "native outbound transport method"):
			return
	transport.trust = X509Certificate.new()
	if not _check(transport.trust.load(fixture["certificate"]) == OK, "native movement trust fixture"):
		return
	if fixture["mode"] == "wrong_identity":
		transport.identity = "other.test"
	var connection := ZoneConnection.new(transport)
	if not _check(connection.connect_to(fixture["url"]), "native movement connection start"):
		return
	await _wait_join(connection)
	if fixture["mode"] in ["wrong_identity", "wrong_trust", "server_off"]:
		_check(connection.state() == ZoneConnection.State.FAILED and connection.error() == ZoneConnection.ERR_HANDSHAKE, "native movement admission/TLS refusal")
	elif fixture["mode"] == "retained":
		_check(connection.is_live() and connection.frames_applied() > 0 and not connection.queue_movement(Vector2.RIGHT), "native retained v2 path")
	else:
		if fixture["mode"] in ["prediction", "prediction_delayed"]:
			await _prediction(connection, fixture["url"], transport, fixture["mode"] == "prediction_delayed")
		else:
			await _movement(connection, fixture["url"])
	connection.close()
	await _wait_closed(connection)
	if not _failed:
		print("TEST PASS: native zone movement " + str(fixture["mode"]))
		quit()


func _prediction(connection: ZoneConnection, url: String, transport: VerifiedTransport, delayed: bool) -> void:
	await _wait_ack(connection, 0, -1)
	var anchor := connection.movement_state()
	var predictor := Predictor.new()
	var spec := {"max_speed_mm_s": 4000, "min_x": -20000, "min_y": 0, "min_z": -20000,
		"max_x": 20000, "max_y": 4000, "max_z": 20000, "hold_ticks": 2,
		"collision_mode": "isolated_flat"}
	if not _check(predictor.configure(spec)["ok"] and predictor.seed(anchor)["ok"], "native prediction anchor/spec"):
		return
	if delayed:
		# Make receipt newer than the local speculative ticks; silence must use the actual ACK.
		await create_timer(0.4).timeout
	if not _check(connection.queue_movement(Vector2.RIGHT, true), "native predicted input queued"):
		return
	var deadline := Time.get_ticks_msec() + 2000
	while transport.successful_writes == 0 and Time.get_ticks_msec() < deadline:
		connection.poll()
		await create_timer(0.005).timeout
	if not _check(transport.successful_writes == 1 and predictor.record_sent(1, {"x": 1000, "z": 0, "sprint": true})["ok"], "native successful write ownership"):
		return
	for _tick: int in 6:
		if not _check(predictor.step_tick()["ok"], "native speculative tick"):
			return
	var speculative := predictor.state()
	if not _check(speculative["x"] == anchor["x"] + 266 and speculative["y"] == anchor["y"], "native isolated prediction and hold expiry"):
		return
	await _wait_ack(connection, 1, int(anchor["tick"]))
	var applied := connection.movement_state()
	var reconciled := predictor.reconcile(applied)
	if not _check(reconciled["ok"] and predictor.pending_count() == 0 and applied["x"] > anchor["x"] and applied["x"] <= anchor["x"] + 266, "native authoritative movement anchor"):
		return
	var state := predictor.state()
	if not _check(state["tick"] == maxi(speculative["tick"], applied["tick"]) and state["x"] >= applied["x"] and state["x"] <= applied["x"] + 133 and reconciled["correction"]["x"] == state["x"] - speculative["x"], "native actual ACK reconciliation"):
		return
	await _wait_ack(connection, 1, maxi(speculative["tick"], applied["tick"]) + 3)
	var stopped := connection.movement_state()
	if not _check(stopped["tick"] > applied["tick"] + 2 and stopped["x"] == anchor["x"] + 266 and predictor.reconcile(stopped)["ok"] and predictor.state()["x"] == stopped["x"] and predictor.history_count() == 0, "native silence authoritative catch-up"):
		return
	predictor.step_tick()
	if not _check(predictor.state()["x"] == stopped["x"], "native catch-up invented held phase"):
		return
	connection.close()
	await _wait_closed(connection)
	predictor.reset()
	if not _check(predictor.state().is_empty() and predictor.pending_count() == 0 and predictor.history_count() == 0 and connection.connect_to(url), "native prediction reconnect reset"):
		return
	await _wait_join(connection)
	await _wait_ack(connection, 0, -1)
	if not _check(predictor.seed(connection.movement_state())["ok"], "native fresh prediction anchor"):
		return
	predictor.step_tick()
	_check(predictor.state()["x"] == connection.movement_state()["x"] and predictor.pending_count() == 0, "native reconnect inherited old input")


func _movement(connection: ZoneConnection, url: String) -> void:
	if not _check(connection.is_live() and connection.frames_applied() > 0, "native movement join"):
		return
	await _wait_ack(connection, 0, -1)
	var before := connection.movement_state()
	if not _check(not before.is_empty() and connection.queue_movement(Vector2.RIGHT, true), "native movement producer"):
		return
	await _wait_ack(connection, 1, int(before["tick"]))
	var moved := connection.movement_state()
	var elapsed := int(moved.get("tick", 0)) - int(before["tick"])
	if not _check(not moved.is_empty() and moved["applied_sequence"] == 1 and moved["x"] > before["x"] and moved["x"] - before["x"] <= mini(266, 133 * elapsed) and moved["y"] == before["y"], "native movement application"):
		return
	await _wait_ack(connection, 1, int(moved["tick"]) + 7)
	var stopped := connection.movement_state()
	await _wait_ack(connection, 1, int(stopped["tick"]) + 3)
	var later := connection.movement_state()
	_check(later["x"] == stopped["x"] and later["y"] == stopped["y"] and later["z"] == stopped["z"], "native movement producer silence stop")
	connection.close()
	await _wait_closed(connection)
	if not _check(connection.movement_state().is_empty() and connection.pending_movement_count() == 0 and connection.connect_to(url), "native movement reconnect reset"):
		return
	await _wait_join(connection)
	await _wait_ack(connection, 0, -1)
	before = connection.movement_state()
	if not _check(before.get("applied_sequence") == 0 and connection.queue_movement(Vector2.LEFT), "native reconnect sequence start"):
		return
	await _wait_ack(connection, 1, int(before["tick"]))
	_check(connection.movement_state().get("applied_sequence") == 1, "native reconnect inherited sequence")


func _wait_join(connection: ZoneConnection) -> void:
	var deadline := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline:
		connection.poll()
		if connection.store().has_base() or connection.state() == ZoneConnection.State.FAILED:
			return
		await create_timer(0.005).timeout
	_check(false, "native movement join deadline")


func _wait_ack(connection: ZoneConnection, sequence: int, after_tick: int) -> void:
	var deadline := Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline:
		connection.poll()
		var own := connection.movement_state()
		if not own.is_empty() and own["applied_sequence"] >= sequence and own["tick"] > after_tick:
			return
		if connection.state() == ZoneConnection.State.FAILED:
			break
		await create_timer(0.005).timeout
	_check(false, "native movement ACK deadline")


func _wait_closed(connection: ZoneConnection) -> void:
	var deadline := Time.get_ticks_msec() + 1000
	while Time.get_ticks_msec() < deadline and connection.state() not in [ZoneConnection.State.CLOSED, ZoneConnection.State.FAILED]:
		connection.poll()
		await create_timer(0.005).timeout
	# FAILED still pumps the close handshake. Give it the same bounded window.
	for _i: int in 10:
		connection.poll()
		await create_timer(0.005).timeout


func _check(condition: bool, detail: String) -> bool:
	if not condition:
		_failed = true
		print("TEST FAIL: " + detail)
		quit(1)
	return condition
