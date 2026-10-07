extends Node

var _codec: Object = WireCodec.new()
var _failed := false


func _ready() -> void:
	if not _check(_codec.has_method("encode_intent"), "movement intent encoder is unavailable"):
		return
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/data/movement_goldens.json"))
	for row: Dictionary in fixture["intents"]:
		var encoded: Dictionary = _codec.call("encode_intent", int(row.sequence), int(row.x), int(row.z), bool(row.sprint))
		_check(encoded.get("ok") == true and encoded.get("bytes") == str(row.hex).hex_decode(), "cross-tier intent bytes differ")
	for fields: Array in [[0, 0, 0], [-1, 0, 0], [1, 1001, 0], [1, 800, 800], [1, -32768, 0]]:
		var refused: Dictionary = _codec.call("encode_intent", fields[0], fields[1], fields[2], false)
		_check(refused.get("ok") == false, "invalid intent encoded")
	_check(_codec.call("encode_intent", 1, 0, 0, false, 1).get("ok") == false, "reserved swimming mode enabled")
	for row: Dictionary in fixture["acks"]:
		var bytes := str(row.hex).hex_decode()
		var decoded: Dictionary = _codec.call("decode_movement_frame", bytes)
		var expected: Dictionary = {}
		for key: String in row["value"]:
			expected[key] = int(row["value"][key])
		_check(decoded.get("ok") == true and decoded.get("ack") == expected, "cross-tier ACK differs")
		for length: int in bytes.size():
			var short: Dictionary = _codec.call("decode_movement_frame", bytes.slice(0, length))
			_check(short.get("ok") == false and short.get("error") == WireCodec.ERR_TRUNCATED, "ACK prefix accepted")
		bytes.append(0)
		_check(_codec.call("decode_movement_frame", bytes).get("error") == WireCodec.ERR_TRAILING, "ACK trailing byte accepted")
	_test_domains()
	if not _failed:
		print("TEST PASS: movement wire goldens and refusal domains")
		get_tree().quit()


func _test_domains() -> void:
	var bytes := ("030004" + "0000000000000000" + "0900000000000000" + "0000000000000000".repeat(3)).hex_decode()
	_check(WireCodec.decode(bytes).get("error") == WireCodec.ERR_VERSION, "default decoder expanded")
	for version: int in [1, 2, 4]:
		var wrong := bytes.duplicate()
		wrong.encode_u16(0, version)
		_check(_codec.call("decode_movement_frame", wrong).get("error") == WireCodec.ERR_VERSION, "movement accepted another version")
	for offset: int in [3, 11]:
		var overflow := bytes.duplicate()
		overflow[offset + 7] = 128
		_check(_codec.call("decode_movement_frame", overflow).get("error") == WireCodec.ERR_RANGE, "unsigned overflow accepted")
	for offset: int in [19, 27, 35]:
		for value: int in [-1000001, 1000001]:
			var outside := bytes.duplicate()
			outside.encode_s64(offset, value)
			_check(_codec.call("decode_movement_frame", outside).get("ok") == false, "out-of-world ACK accepted")
	bytes[2] = 3
	_check(_codec.call("decode_movement_frame", bytes).get("error") == WireCodec.ERR_KIND, "inbound intent accepted")


func _check(condition: bool, detail: String) -> bool:
	if not condition:
		_failed = true
		print("TEST FAIL: " + detail)
		get_tree().quit(1)
	return condition
