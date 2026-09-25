class_name DevLog
## The in-game development log.
##
## World at Ruin is built almost entirely by agents, and the owner watches
## development progress by playing. Every change that a player could notice
## gets an entry here, newest first — open it in-game with F1.

const VERSION := "0.1.17"
const CODENAME := "Ashfall Reach"

## One file per entry, named by the version the change ships in — or, for an
## entry still carrying [constant NEXT_VERSION], by a slug.
##
## Every player-visible change adds an entry, and roughly seven agent sessions
## work in parallel, so a single shared list put every concurrent change on the
## same few lines: each one had to rebase behind every sibling merge, and each
## rebase moved the head and staled an already rate-limited review. Separate
## files share no line, so concurrent entries touch disjoint paths and merge
## without contest. Nothing about what an entry says or where it appears
## changes — only where it is stored.
const ENTRY_DIR := "res://devlog/"

## The version an entry carries until the release build stamps it (#518).
##
## Which release a change ships in cannot be known on its branch: several are
## cut an hour, so a sibling can release first. An entry whose version is this
## placeholder is rewritten by `tools/devlog-stamp.sh`, which `cd.yaml` runs, to
## the first release containing the commit that added it — in the release build
## only, as `VERSION` is. Anywhere that has not been through a release it stays
## the placeholder and sorts above every released entry, because it is newer
## than all of them. Placeholders that ship together receive the same number.
const NEXT_VERSION := "next"

## A placeholder entry's filename: lowercase words joined by hyphens. Having no
## dots, it can never collide with a released entry's `X.Y.Z.json`.
const NEXT_ENTRY_NAME := "^[a-z0-9]+(-[a-z0-9]+)*$"

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
	out = newest_first(out)
	if out.is_empty():
		push_error("dev log: no entries found under %s — the log would render empty" % ENTRY_DIR)
	return out


## A copy of `entries`, newest first. The loader orders the log with this, and
## the tests order constructed entries with it, so there is one ordering.
static func newest_first(entries: Array[Dictionary]) -> Array[Dictionary]:
	var ordered: Array[Dictionary] = entries.duplicate()
	ordered.sort_custom(_newer_first)
	return ordered


## Whether an entry still carries [constant NEXT_VERSION] rather than a release.
static func is_next(entry: Dictionary) -> bool:
	return String(entry.get("version", "")) == NEXT_VERSION


## What the log shows ahead of an entry's title. A released entry reads as the
## build it shipped in (`v0.98.0`); one whose number was never cut drops the `v`
## (#466). A [constant NEXT_VERSION] entry says it is numbered at release rather
## than showing the placeholder. Only a build that has not been through a release
## shows one, and there the entry may already have shipped — a development build
## cannot tell — so the heading claims nothing about whether it has.
static func heading(entry: Dictionary) -> String:
	if is_next(entry):
		return "Numbered at release"
	var version := String(entry.get("version", ""))
	if not String(entry.get("shipped_in", "")).is_empty():
		return version
	return "v" + version


## Empty when an entry file's name fits what it declares, otherwise why not. A
## released entry is named for its version, which is how an author finds it and
## what keeps two releases on disjoint paths; a [constant NEXT_VERSION] entry has
## no version yet, so it is named by a slug matching [constant NEXT_ENTRY_NAME].
static func name_problem(stem: String, entry: Dictionary) -> String:
	if is_next(entry):
		if RegEx.create_from_string(NEXT_ENTRY_NAME).search(stem) == null:
			return ("a \"%s\" entry is named by a lowercase-hyphen slug such as 'ash-settles', "
				+ "not '%s'") % [NEXT_VERSION, stem]
		return ""
	var declared := String(entry.get("version", "<missing>"))
	if declared != stem:
		return "declares version '%s' but is named '%s'" % [declared, stem]
	return ""


## Newest first. A [constant NEXT_VERSION] entry is newer than every released
## one. Released versions are compared component-wise as integers through a
## zero-padded key, because "0.1.9" sorts ABOVE "0.1.10" as plain text and the
## patch number is already into double digits.
##
## One release can carry several entries: every placeholder in it is stamped
## with the same number. Entries in the same release, like unreleased ones,
## order by date, newest first, then by title, so the order is total.
static func _newer_first(a: Dictionary, b: Dictionary) -> bool:
	var a_next := is_next(a)
	if a_next != is_next(b):
		return a_next
	if not a_next:
		var a_key := _sort_key(String(a.get("version", "")))
		var b_key := _sort_key(String(b.get("version", "")))
		if a_key != b_key:
			return a_key > b_key
	var a_date := String(a.get("date", ""))
	var b_date := String(b.get("date", ""))
	if a_date != b_date:
		return a_date > b_date
	return String(a.get("title", "")) < String(b.get("title", ""))


static func _sort_key(version: String) -> String:
	var key := ""
	for part: String in version.split("."):
		key += "%06d." % int(part)
	return key
