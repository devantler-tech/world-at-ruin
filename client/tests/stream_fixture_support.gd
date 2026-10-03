class_name StreamFixtureSupport
extends RefCounted
## Observe the raw cross-tier fixture. Consumers retain their fold/pump laws
## and the two distinct diagnostics for an absent anchor or stream.


static func load_stream(path: String, empty_problem: String, missing_stream_problem: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return {"problem": empty_problem}
	var parsed: Variant = JSON.parse_string(text)
	if parsed is not Dictionary:
		return {"problem": "fixture %s did not parse as a JSON object" % path}
	var root: Dictionary = parsed
	if root.get("stream") is not Dictionary:
		return {"problem": missing_stream_problem}
	var stream: Dictionary = root["stream"]
	if stream.get("frames") is not Array or (stream["frames"] as Array).is_empty():
		return {"problem": "fixture stream has no frames"}
	if stream.get("end_state") is not Dictionary:
		return {"problem": "fixture stream has no end_state"}
	return {"problem": "", "stream": stream}
