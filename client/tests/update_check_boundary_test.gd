extends Node
## Installation authority and exact-byte controls for experimental update checks.
const CHECK_PATH := "res://scripts/shell/update_check.gd"
var _failed := false


func _ready() -> void:
	if not ResourceLoader.exists(CHECK_PATH):
		_fail("installed-client update checker is missing")
		return
	var checker: Script = load(CHECK_PATH)
	var vector: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
		"res://tests/data/update_trust_chain_vector.json"))
	var config := {
		"channel": "live",
		"manifest_url": "https://updates.worldatruin.example/live/manifest.json",
		"revocation_head_url": vector["installed"]["revocation_head_url"],
		"root_public_key": FileAccess.get_file_as_string(vector["root_public_key_path"]),
	}
	if not checker.validate_configuration(config).is_empty():
		_fail("valid installation authority was refused")
	for field: String in config:
		var missing := config.duplicate(true)
		missing.erase(field)
		if checker.validate_configuration(missing).is_empty():
			_fail("missing installation authority was accepted: " + field)
	for url: String in ["http://example.com/head", "https://u:p@example.com/head",
			"https://example.com/head#fragment", "https://example.com/head?token=value",
			"https://example.com/../head", "https://example.com:0/head",
			"https://EXAMPLE.com/head", "https://example.com/%2e/head"]:
		var altered := config.duplicate(true)
		altered["revocation_head_url"] = url
		if checker.validate_configuration(altered).is_empty():
			_fail("ambiguous or unsafe endpoint was accepted")
	var wrong_root := config.duplicate(true)
	wrong_root["root_public_key"] = "not a public key"
	if checker.validate_configuration(wrong_root).is_empty():
		_fail("invalid trust root was accepted")
	var canonical: Dictionary = JCS.canonicalize(vector["manifest"])
	var accepted: Dictionary = checker.decode_document(str(canonical["text"]).to_utf8_buffer())
	if not accepted.get("error", "").is_empty() or accepted.get("document") != vector["manifest"]:
		_fail("canonical signed document did not survive exact-byte decoding")
	for text: String in ["{\"a\":1,\"a\":2}", "{\"a\":1,}", "[1]",
			"{\"a\":9007199254740993}", "{ \"a\": 1 }", "null"]:
		if checker.decode_document(text.to_utf8_buffer()).get("error", "").is_empty():
			_fail("ambiguous signed input was accepted")
	var invalid_utf8 := PackedByteArray([123, 34, 97, 34, 58, 34, 255, 34, 125])
	if checker.decode_document(invalid_utf8).get("error", "").is_empty():
		_fail("invalid UTF-8 was accepted")
	var deep := "{\"a\":".repeat(80) + "0" + "}".repeat(80)
	if checker.decode_document(deep.to_utf8_buffer()).get("error", "").is_empty():
		_fail("unbounded nesting was accepted")
	if not _failed:
		print("TEST PASS — update configuration and canonical document boundaries refuse ambiguity")
		get_tree().quit(0)


func _fail(message: String) -> void:
	_failed = true
	print("TEST FAIL: " + message)
	get_tree().quit(1)
