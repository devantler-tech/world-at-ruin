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
