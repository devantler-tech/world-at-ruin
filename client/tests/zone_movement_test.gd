extends Node

const FLAG := "WAR_ZONE_MOVEMENT"
const URL := "wss://zone.example/zone"
const RetainedTests = preload("res://tests/zone_connection_test.gd")
var _failed := false


class Transport:
	extends RefCounted
	var ready := WebSocketPeer.STATE_CLOSED
	var packets: Array[PackedByteArray] = []
	var sent: Array[PackedByteArray] = []
	var headers := PackedStringArray()
	var buffered := 0
	var write_result := OK
	var outbound_size := 0

	func connect_to_url(_url: String) -> int:
		ready = WebSocketPeer.STATE_OPEN
		return OK

	func poll() -> void:
		if ready == WebSocketPeer.STATE_CLOSING:
			ready = WebSocketPeer.STATE_CLOSED

	func get_ready_state() -> int:
		return ready

	func get_available_packet_count() -> int:
		return packets.size()

	func get_packet() -> PackedByteArray:
		return packets.pop_front()

	func was_string_packet() -> bool:
		return false

	func set_inbound_buffer_size(_size: int) -> void:
		pass

	func set_outbound_buffer_size(size: int) -> void:
		outbound_size = size

	func get_current_outbound_buffered_amount() -> int:
		return buffered

	func put_packet(bytes: PackedByteArray) -> int:
		if write_result == OK:
			sent.append(bytes.duplicate())
		return write_result

	func set_handshake_headers(value: PackedStringArray) -> void:
		headers = value

	func close() -> void:
		ready = WebSocketPeer.STATE_CLOSING


func _ready() -> void:
	var env := TestEnvironment.snapshot([FLAG, "WAR_ZONE_TOKEN", "WAR_ZONE_TLS_SERVER_NAME"])
	OS.set_environment("WAR_ZONE_TOKEN", "fixture-token")
	OS.unset_environment("WAR_ZONE_TLS_SERVER_NAME")
	OS.unset_environment(FLAG)
	var off := Transport.new()
	var ordinary := ZoneConnection.new(off)
	_check(ordinary.connect_to(URL) and "X-WAR-Wire-Version: 2" in off.headers, "default movement negotiation changed")
	ordinary.close()
	OS.set_environment(FLAG, "1")
	var retained := RetainedTests.FakeTransport.new()
	var incompatible := ZoneConnection.new(retained)
	_check(not incompatible.connect_to(URL) and incompatible.error() == "movement_transport", "opt-in admitted a receive-only transport")
	OS.unset_environment(FLAG)
	_check(incompatible.connect_to(URL) and "X-WAR-Wire-Version: 2" in retained.handshake_headers, "retained transport could not recover after capability refusal")
	incompatible.close()
	OS.set_environment(FLAG, "1")
	var transport := Transport.new()
	var connection := ZoneConnection.new(transport)
	connection.connect_to(URL)
	if not _check("X-WAR-Wire-Version: 3" in transport.headers, "opt-in still negotiates receive-only v2"):
		TestEnvironment.restore(env)
		return
	_test_cadence(connection, transport)
	_test_ack(connection, transport)
	_test_backpressure()
	_test_lifetime(connection, transport)
	_test_stream_refusals()
	TestEnvironment.restore(env)
	if not _failed:
		print("TEST PASS: movement cadence, ACK, bounds and lifecycle")
		get_tree().quit()


func _test_cadence(connection: ZoneConnection, transport: Transport) -> void:
	OS.unset_environment(FLAG)  # selection must remain latched on this socket
	_check(not connection.call("queue_movement", Vector2.RIGHT, false), "input admitted before join")
	transport.packets.append(_join())
	connection.call("poll", 0)
	_check(connection.call("queue_movement", Vector2(1, 1), false), "finite input refused")
	_check(not connection.call("queue_movement", Vector2(INF, 0), false), "infinity accepted")
	_check(not connection.call("queue_movement", Vector2(NAN, 0), false), "NaN accepted")
	connection.call("poll", 0)
	_check(transport.sent.size() == 1 and transport.sent[0].decode_s16(11) == 707 and transport.sent[0].decode_s16(13) == 707, "diagonal quantization changed")
	connection.call("queue_movement", Vector2.LEFT, false)
	connection.call("queue_movement", Vector2.ZERO, true)
	connection.call("poll", 33333)
	_check(transport.sent.size() == 1, "cadence sent early")
	connection.call("poll", 33334)
	_check(transport.sent.size() == 2 and transport.sent[1].decode_s16(11) == 0 and transport.sent[1][15] == 1, "latest sample did not replace direction")
	connection.call("queue_movement", Vector2(2, -1), false)
	connection.call("poll", 900000)
	_check(transport.sent.size() == 3 and transport.sent[2].decode_u64(3) == 3, "stall burst or sequence gap")
	connection.call("poll", 933334)
	_check(transport.sent.size() == 3, "producer silence resent stale direction")
	OS.set_environment(FLAG, "1")
	var clock_transport := Transport.new()
	var clock_connection := _live(clock_transport)
	clock_connection.call("queue_movement", Vector2.RIGHT, false)
	clock_connection.call("poll", 200000)
	clock_connection.call("queue_movement", Vector2.LEFT, false)
	clock_connection.call("poll", 100000)
	_check(clock_transport.sent.size() == 1, "clock regression sent input")
	clock_connection.call("poll", 233334)
	_check(clock_transport.sent.size() == 2, "clock regression lost pending sample")


func _test_ack(connection: ZoneConnection, transport: Transport) -> void:
	transport.packets.append(_ack(3, 9, -2))
	connection.call("poll", 933334)
	_check(connection.call("pending_movement_count") == 0, "cumulative ACK did not retire inputs")
	var state: Dictionary = connection.call("movement_state")
	_check(state == {"applied_sequence": 3, "tick": 9, "x": -2, "y": 0, "z": 0}, "own authoritative state differs")
	state["x"] = 99
	_check(connection.call("movement_state").get("x") == -2, "caller mutated own state")
	transport.packets.append(_delta(9))
	transport.packets.append(_ack(3, 9, -2))
	transport.packets.append(_ack(3, 10, -3))
	transport.packets.append(_join(11))
	connection.call("poll", 966668)
	_check(connection.is_live() and connection.store().tick() == 11 and connection.call("movement_state").get("tick") == 10, "ACK/replica clocks collided")


func _test_backpressure() -> void:
	var transport := Transport.new()
	var connection := _live(transport)
	transport.buffered = 1088
	connection.call("queue_movement", Vector2.LEFT, false)
	connection.call("poll", 0)
	connection.call("queue_movement", Vector2.RIGHT, true)
	connection.call("poll", 100000)
	_check(transport.sent.is_empty(), "backpressure emitted an extra frame")
	transport.buffered = 0
	connection.call("poll", 133334)
	_check(transport.sent.size() == 1 and transport.sent[0].decode_u64(3) == 1 and transport.sent[0].decode_s16(11) == 1000, "backpressure lost newest sample or consumed sequence")
	transport.write_result = ERR_OUT_OF_MEMORY
	connection.call("queue_movement", Vector2.LEFT, false)
	connection.call("poll", 166668)
	_check(connection.state() == ZoneConnection.State.FAILED and connection.error() == "movement_write", "failed write was silent")
	var bounded := Transport.new()
	connection = _live(bounded)
	for i: int in 65:
		connection.call("queue_movement", Vector2.RIGHT, false)
		connection.call("poll", i * 33334)
	_check(bounded.sent.size() <= 60 and connection.state() == ZoneConnection.State.FAILED and connection.error() == "movement_deadline", "missing ACK stayed active without bounds")
	var blocked := Transport.new()
	connection = _live(blocked)
	blocked.buffered = 1088
	connection.call("queue_movement", Vector2.RIGHT, false)
	connection.call("poll", 0)
	connection.call("poll", 2000000)
	_check(blocked.sent.is_empty() and connection.error() == "movement_deadline", "blocked transport never expired")
	blocked = Transport.new()
	connection = _live(blocked)
	blocked.buffered = 1088
	connection.call("queue_movement", Vector2.RIGHT, false)
	connection.call("poll", 0)
	blocked.buffered = 0
	connection.call("poll", 2000001)
	_check(blocked.sent.is_empty() and connection.error() == "movement_deadline", "late transport recovery sent stale input")
	var exhausted := ZoneMovement.new()
	# Place the counter at its naturally reachable boundary without billions
	# of sends; exercise the real next-write refusal, never a test-only API.
	exhausted.set("_sequence", 9223372036854775807)
	exhausted.queue(Vector2.RIGHT, false)
	var exhausted_transport := Transport.new()
	_check(exhausted.pump(exhausted_transport, 0).get("error") == "movement_sequence" and exhausted_transport.sent.is_empty(), "sequence exhaustion wrapped onto the wire")


func _test_lifetime(connection: ZoneConnection, transport: Transport) -> void:
	connection.call("queue_movement", Vector2.RIGHT, false)
	connection.close()
	_check(connection.call("movement_state").is_empty() and connection.call("pending_movement_count") == 0, "close retained own movement")
	connection.call("poll", 1000000)
	_check(connection.connect_to(URL), "reconnect refused")
	transport.packets.append(_join())
	connection.call("poll", 0)
	var count := transport.sent.size()
	connection.call("poll", 100000)
	_check(transport.sent.size() == count, "reconnect sent old direction")
	connection.call("queue_movement", Vector2.LEFT, false)
	connection.call("poll", 100000)
	_check(transport.sent[-1].decode_u64(3) == 1, "reconnect inherited sequence")
	transport.ready = WebSocketPeer.STATE_CLOSED
	connection.call("poll", 133334)
	_check(connection.call("pending_movement_count") == 0, "hangup retained pending input")


func _test_stream_refusals() -> void:
	for bad: PackedByteArray in [_ack(1, 2), _ack(0, 0), _ack(0, 1, 1), _delta(1)]:
		var transport := Transport.new()
		var connection := _live(transport)
		transport.packets.append(_ack(0, 1))
		connection.call("poll", 0)
		if bad[2] == 2:
			bad.encode_u16(0, 2)
		transport.packets.append(bad)
		connection.call("poll", 33334)
		_check(connection.state() == ZoneConnection.State.FAILED, "future/regressing/mixed-version ACK accepted")
	var transport := Transport.new()
	var connection := ZoneConnection.new(transport)
	connection.connect_to(URL)
	transport.packets.append(_ack(0, 1))
	connection.call("poll", 0)
	_check(connection.state() == ZoneConnection.State.FAILED, "ACK accepted before join")
	transport = Transport.new()
	connection = _live(transport)
	connection.call("queue_movement", Vector2.RIGHT, false)
	connection.call("poll", 0)
	connection.call("queue_movement", Vector2.RIGHT, false)
	connection.call("poll", 33334)
	transport.packets.append(_ack(2, 8))
	connection.call("poll", 66668)
	transport.packets.append(_ack(1, 9))
	connection.call("poll", 100002)
	_check(connection.error() == "movement_ack_order", "sequence regression with increasing tick accepted")


func _live(transport: Transport) -> ZoneConnection:
	var connection := ZoneConnection.new(transport)
	connection.connect_to(URL)
	transport.packets.append(_join())
	connection.call("poll", 0)
	return connection


func _join(tick: int = 1) -> PackedByteArray:
	var bytes := ("030001" + "0100000000000000".repeat(2) + "00000000".repeat(2)).hex_decode()
	bytes.encode_u64(3, tick)
	return bytes


func _delta(tick: int) -> PackedByteArray:
	var bytes := ("030002" + "0000000000000000" + "00000000".repeat(5)).hex_decode()
	bytes.encode_u64(3, tick)
	return bytes


func _ack(sequence: int, tick: int, x: int = 0) -> PackedByteArray:
	var bytes := ("030004" + "0000000000000000".repeat(5)).hex_decode()
	bytes.encode_u64(3, sequence)
	bytes.encode_u64(11, tick)
	bytes.encode_s64(19, x)
	return bytes


func _check(condition: bool, detail: String) -> bool:
	if not condition:
		_failed = true
		print("TEST FAIL: " + detail)
		get_tree().quit(1)
	return condition
