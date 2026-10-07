class_name UpdateCheck
extends Node
## Explicit opt-in control-document checks. This never downloads or mounts a pack.
## Installation-owned authority is copied before any asynchronous work.

const ENABLE_ENV := "WAR_UPDATE_CHECK"
const CONFIG_ENV := "WAR_UPDATE_CHECK_CONFIG"
const MAX_DOCUMENT_BYTES := 131072
const MAX_CHECK_SECONDS := 10.0
const MAX_DEPTH := 64

var _active := false
var _canceled := false


static func is_enabled() -> bool:
	return OS.get_environment(ENABLE_ENV) == "1"


static func validate_configuration(raw: Variant) -> String:
	if not raw is Dictionary:
		return "installation update configuration is not an object"
	var config: Dictionary = raw
	var required := ["channel", "manifest_url", "revocation_head_url", "root_public_key"]
	if config.size() != required.size():
		return "installation update configuration has missing or unknown fields"
	for field: String in required:
		if not config.get(field) is String or str(config[field]).is_empty():
			return "installation update configuration has missing authority"
	if config["channel"] != UpdateManifest.CHANNEL:
		return "installation update channel is unsupported"
	for field: String in ["manifest_url", "revocation_head_url"]:
		if not is_endpoint(config[field]):
			return "installation update endpoint is not an unambiguous HTTPS document URL"
	if config["manifest_url"] == config["revocation_head_url"]:
		return "manifest and independent revocation head need distinct endpoints"
	return UpdateTrust.public_key_error(config["root_public_key"])


static func is_endpoint(value: String) -> bool:
	var pattern := RegEx.new()
	pattern.compile("^https://([a-z0-9]+(?:[.-][a-z0-9]+)*)(?::([0-9]{1,5}))?(/[A-Za-z0-9_./~-]+)$")
	var matched := pattern.search(value)
	if matched == null:
		return false
	var port := matched.get_string(2)
	if not port.is_empty() and (int(port) < 1 or int(port) > 65535 or str(int(port)) != port):
		return false
	var path := matched.get_string(3)
	if path.contains("//"):
		return false
	for segment: String in path.split("/"):
		if segment in [".", ".."]:
			return false
	return true


static func read_configuration(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": "installation update configuration cannot be read", "document": {}}
	if file.get_length() > MAX_DOCUMENT_BYTES:
		file.close()
		return {"error": "installation update configuration exceeds its byte budget", "document": {}}
	var raw := file.get_buffer(MAX_DOCUMENT_BYTES + 1)
	file.close()
	return decode_document(raw)


## Canonical byte equality detects duplicate names, parser extensions, invalid
## UTF-8 and rounded integers before their normalized values can reach signatures.
static func decode_document(raw: PackedByteArray) -> Dictionary:
	if raw.is_empty() or raw.size() > MAX_DOCUMENT_BYTES:
		return {"error": "control document exceeds its byte budget or is empty", "document": {}}
	if not _valid_utf8(raw):
		return {"error": "control document has invalid UTF-8", "document": {}}
	var text := raw.get_string_from_utf8()
	if text.to_utf8_buffer() != raw or not _bounded_depth(raw):
		return {"error": "control document has invalid UTF-8 or excessive nesting", "document": {}}
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return {"error": "control document is not a JSON object", "document": {}}
	var canonical := JCS.canonicalize(json.data)
	if not str(canonical["error"]).is_empty() or str(canonical["text"]).to_utf8_buffer() != raw:
		return {"error": "control document is not exact canonical JSON", "document": {}}
	return {"error": "", "document": json.data}


static func _valid_utf8(raw: PackedByteArray) -> bool:
	var index := 0
	while index < raw.size():
		var first := raw[index]
		index += 1
		if first < 128:
			continue
		var count := 1 if first >= 194 and first <= 223 else 2 if first >= 224 and first <= 239 else 3 if first >= 240 and first <= 244 else -1
		if count < 0 or index + count > raw.size():
			return false
		var second := raw[index]
		if (first == 224 and second < 160) or (first == 237 and second >= 160) or (first == 240 and second < 144) or (first == 244 and second >= 144):
			return false
		for offset in count:
			if raw[index + offset] < 128 or raw[index + offset] > 191:
				return false
		index += count
	return true


static func _bounded_depth(raw: PackedByteArray) -> bool:
	var depth := 0
	var quoted := false
	var escaped := false
	for byte: int in raw:
		if quoted:
			if escaped:
				escaped = false
			elif byte == 92:
				escaped = true
			elif byte == 34:
				quoted = false
		elif byte == 34:
			quoted = true
		elif byte in [123, 91]:
			depth += 1
			if depth > MAX_DEPTH:
				return false
		elif byte in [125, 93]:
			depth -= 1
			if depth < 0:
				return false
	return depth == 0 and not quoted


func cancel() -> void:
	_canceled = true


func _exit_tree() -> void:
	cancel()


## Custom trusted CA chains are useful for native fixtures; hostname overrides
## and unsafe TLS clients are always refused. The shipped caller uses system CAs.
func check(installed: Dictionary, configuration: Dictionary,
		tls_options: TLSOptions = null, timeout_seconds: float = MAX_CHECK_SECONDS,
		clock: Callable = Callable()) -> Dictionary:
	if not is_enabled():
		return _refused("experimental update checks are disabled")
	if _active or not is_inside_tree():
		return _refused("update checker is busy or detached")
	if not is_finite(timeout_seconds) or timeout_seconds <= 0.0 or timeout_seconds > MAX_CHECK_SECONDS:
		return _refused("update check deadline is outside its bounded policy")
	if tls_options != null and (tls_options.is_unsafe_client() or tls_options.is_server()
			or not tls_options.get_common_name_override().is_empty()):
		return _refused("unsafe TLS or a hostname override is refused")
	var config := configuration.duplicate(true)
	var facts := installed.duplicate(true)
	var error := validate_configuration(config)
	if not error.is_empty():
		return _refused(error)
	_active = true
	_canceled = false
	var deadline := Time.get_ticks_usec() + int(timeout_seconds * 1000000.0)
	var manifest_reply := await _fetch(config["manifest_url"], deadline, tls_options)
	if not str(manifest_reply["error"]).is_empty():
		_active = false
		return _refused(str(manifest_reply["error"]))
	var head_reply := await _fetch(config["revocation_head_url"], deadline, tls_options)
	_active = false
	if not str(head_reply["error"]).is_empty():
		return _refused(str(head_reply["error"]))
	if _canceled or Time.get_ticks_usec() >= deadline:
		return _refused("complete update check was canceled or exceeded its deadline")
	facts["channel"] = config["channel"]
	facts["revocation_head_url"] = config["revocation_head_url"]
	facts["observed_at"] = clock.call() if clock.is_valid() else Time.get_datetime_string_from_system(true) + "Z"
	var verdict := UpdateTrust.verify_and_decide(facts, manifest_reply["document"],
		config["root_public_key"], head_reply["document"])
	if _canceled or Time.get_ticks_usec() >= deadline:
		return _refused("complete update verification exceeded its deadline or was canceled")
	verdict["manifest"] = manifest_reply["document"] if verdict["trusted"] else {}
	verdict["head"] = head_reply["document"] if verdict["trusted"] else {}
	verdict["observed_at"] = facts["observed_at"]
	return verdict


func _fetch(url: String, deadline: int, tls_options: TLSOptions) -> Dictionary:
	var remaining := float(deadline - Time.get_ticks_usec()) / 1000000.0
	if remaining <= 0.0 or _canceled:
		return {"error": "complete update check deadline exceeded or canceled", "document": {}}
	var request := HTTPRequest.new()
	request.accept_gzip = false
	request.body_size_limit = MAX_DOCUMENT_BYTES
	request.download_chunk_size = 4096
	request.max_redirects = 0
	request.timeout = remaining
	if tls_options != null:
		request.set_tls_options(tls_options)
	add_child(request)
	var reply := {}
	request.request_completed.connect(func(result: int, code: int,
			_headers: PackedStringArray, body: PackedByteArray) -> void:
		reply["result"] = result
		reply["code"] = code
		reply["body"] = body)
	var started := request.request(url, ["Accept: application/json", "Cache-Control: no-cache"])
	if started != OK:
		request.queue_free()
		return {"error": "control request could not start", "document": {}}
	while not reply.has("result"):
		if _canceled or not is_inside_tree() or Time.get_ticks_usec() >= deadline:
			request.cancel_request()
			request.queue_free()
			return {"error": "complete update check deadline exceeded or canceled", "document": {}}
		await get_tree().process_frame
	request.queue_free()
	if reply["result"] != HTTPRequest.RESULT_SUCCESS or reply["code"] != 200:
		return {"error": "control request failed its transport or HTTP status checks", "document": {}}
	return decode_document(reply["body"])


static func _refused(error: String) -> Dictionary:
	return {"trusted": false, "error": error, "decision": {}, "manifest": {}, "head": {}}
