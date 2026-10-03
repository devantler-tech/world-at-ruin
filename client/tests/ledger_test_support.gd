class_name LedgerTestSupport
extends RefCounted
## Independent readers for test-owned historical names; production parsers stay
## separate. The ledger's order and duplicates remain visible to assertions.


## Read nonblank, noncomment names without sorting or deduplicating them.
static func names(path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return out
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line != "" and not line.begins_with("#"):
			out.append(line)
	return out


## Strict first-separator mappings; caller-owned semantic assertions stay separate.
static func mappings(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var mappings := {}
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var parts := line.split("=", false, 1)
		if parts.size() != 2:
			return {}
		var name := String(parts[0]).strip_edges()
		var landmark := String(parts[1]).strip_edges()
		if name.is_empty() or landmark.is_empty() or mappings.has(name):
			return {}
		mappings[name] = landmark
	file.close()
	return mappings
