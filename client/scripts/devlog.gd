class_name DevLog
## The in-game development log.
##
## World at Ruin is built almost entirely by agents, and the owner watches
## development progress by playing. Every change that a player could notice
## gets an entry here, newest first — open it in-game with F1.

const VERSION := "0.1.17"
const CODENAME := "Ashfall Reach"

## One file per entry, named by the version the change ships in.
##
## Every player-visible change adds an entry, and roughly seven agent sessions
## work in parallel, so a single shared list put every concurrent change on the
## same few lines: each one had to rebase behind every sibling merge, and each
## rebase moved the head and staled an already rate-limited review. Separate
## files share no line, so concurrent entries touch disjoint paths and merge
## without contest. Nothing about what an entry says or where it appears
## changes — only where it is stored.
const ENTRY_DIR := "res://devlog/"

## Newest first. Keys: version, date, title, notes (Array[String]).
##
## Read on FIRST USE rather than when the class loads. Boot needs `VERSION` but
## never the entries — only opening the log in-game does — and eagerly reading
## every entry file put that work inside the launch path, where it competed with
## the recovery ledger's read-modify-write and made `boot_ledger_boot_test`
## intermittent. Nothing on the boot path pays for the log now.
## Constant in spirit but read from disk, so it cannot be a `const` — the same
## shape as `CaveAtmosphere.PROBE_OFFSETS`, and named to match how every caller
## already reads it.
# gdlint:ignore = class-variable-name
static var ENTRIES: Array[Dictionary]:
	get:
		if not _loaded:
			_loaded = true
			_entries = _load_entries()
		return _entries

static var _entries: Array[Dictionary] = []
static var _loaded := false


## Read every entry file and order them newest first.
##
## An empty result is pushed as an error rather than returned quietly: the log
## renders from this list, so a missing or unexported directory would otherwise
## show a blank panel, which reads as a log with nothing in it yet rather than
## as a broken one.
static func _load_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for file_name: String in DirAccess.get_files_at(ENTRY_DIR):
		# Godot's exported/imported filesystem can present a .json as
		# .json.remap; match on the stem so discovery survives both.
		var stem := file_name.trim_suffix(".remap")
		if not stem.ends_with(".json"):
			continue
		var file := FileAccess.open(ENTRY_DIR + stem, FileAccess.READ)
		if file == null:
			push_error("dev log: cannot read %s%s" % [ENTRY_DIR, stem])
			continue
		var parsed: Variant = JSON.parse_string(file.get_as_text())
		file.close()
		if parsed is not Dictionary:
			push_error("dev log: %s%s is not a JSON object" % [ENTRY_DIR, stem])
			continue
		out.append(parsed as Dictionary)
	out.sort_custom(_newer_first)
	if out.is_empty():
		push_error("dev log: no entries found under %s — the log would render empty" % ENTRY_DIR)
	return out


## Newest first. Versions are compared component-wise as integers through a
## zero-padded key, because "0.1.9" sorts ABOVE "0.1.10" as plain text and the
## patch number is already into double digits.
static func _newer_first(a: Dictionary, b: Dictionary) -> bool:
	return _sort_key(String(a.get("version", ""))) > _sort_key(String(b.get("version", "")))


static func _sort_key(version: String) -> String:
	var key := ""
	for part: String in version.split("."):
		key += "%06d." % int(part)
	return key
