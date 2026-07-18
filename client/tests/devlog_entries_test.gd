extends Node
## Regression test for the in-game dev log's entry list (issue #119).
##
## The dev log is the maintainer's channel for watching progress — the repo's
## dev-log contract says every player-visible change appends an entry, and the
## log is read in-game with L / F1. That makes `DevLog.ENTRIES` a **shared,
## append-at-the-top structure that every player-visible PR edits**, which is
## exactly the shape that accumulates copy-paste damage: two byte-identical
## copies of the 0.1.5 and 0.1.4 entries had already crept in, so scrolling the
## log showed the same two releases twice and it read as a rendering bug.
##
## This pins the properties that make the log trustworthy as a record:
##  1. UNIQUE VERSIONS — no version ever appears twice. This is the guard the
##     issue asks for, because the duplication is a recurring class of bug rather
##     than a one-off: every player-visible PR appends here, and two PRs landing
##     around each other is precisely how a block gets duplicated in a merge.
##  2. NEWEST FIRST, NUMERICALLY — versions strictly descend. The comparison is
##     component-wise integer, never string: lexically "0.1.9" sorts ABOVE
##     "0.1.10", so a string compare would call a correct log broken (and hide a
##     real inversion once the patch number reaches double digits).
##  3. WELL-FORMED — every entry carries version/date/title/notes, notes are
##     non-empty strings, so a half-written entry cannot ship silently.
##
## It deliberately does NOT tie the entries to `DevLog.VERSION`: an entry carries
## the version its change will SHIP in, while `DevLog.VERSION` is a dev
## placeholder stamped from the release tag by `cd.yaml`, so the top entry is
## expected to run ahead of it (see the note at the end of `_ready`).
##
## Pure data inspection — no scene, no save, no boot — so it is safe to run
## locally and deterministic in CI.
##
## Run: godot --headless --path client res://tests/devlog_entries_test.tscn

## Below this the log is too short to be a meaningful record, and a guard over an
## almost-empty list would pass vacuously.
const MIN_ENTRIES := 10

var _failed := false


func _ready() -> void:
	var entries := DevLog.ENTRIES
	if entries.size() < MIN_ENTRIES:
		_fail("the dev log has only %d entries (expected at least %d) — the guards below would be near-vacuous"
			% [entries.size(), MIN_ENTRIES])
		return

	# --- 3. WELL-FORMED: every entry is a complete, readable record ---
	for i in entries.size():
		var e: Dictionary = entries[i]
		for key: String in ["version", "date", "title", "notes"]:
			if not e.has(key):
				_fail("dev-log entry %d is missing '%s'" % [i, key])
				return
		for key: String in ["version", "date", "title"]:
			var value: Variant = e[key]
			if value is not String or (value as String).is_empty():
				_fail("dev-log entry %d has an empty or non-string '%s'" % [i, key])
				return
		var notes: Variant = e["notes"]
		if notes is not Array or (notes as Array).is_empty():
			_fail("dev-log entry '%s' has no notes — an entry with nothing to say should not ship" % e["version"])
			return
		for note: Variant in (notes as Array):
			if note is not String or (note as String).is_empty():
				_fail("dev-log entry '%s' has an empty or non-string note" % e["version"])
				return

	# --- 1. UNIQUE VERSIONS: the #119 guard ---
	var seen: Dictionary = {}
	for e: Dictionary in entries:
		var v: String = e["version"]
		if seen.has(v):
			_fail(("dev log lists version '%s' TWICE — a duplicated entry makes the log show the same " +
				"release twice and reads as a rendering bug (issue #119). Every player-visible PR " +
				"appends here, so a merge can duplicate a block: keep exactly one entry per version.") % v)
			return
		seen[v] = true

	# --- 2. NEWEST FIRST, compared numerically rather than as strings ---
	for i in range(1, entries.size()):
		var newer: String = entries[i - 1]["version"]
		var older: String = entries[i]["version"]
		var cmp := _compare_versions(newer, older)
		if cmp == 0:
			_fail("dev-log entries %d and %d report the same version '%s'" % [i - 1, i, newer])
			return
		if cmp < 0:
			_fail(("dev log is out of order: '%s' is listed above '%s' but is OLDER. Entries run " +
				"newest first (note the comparison is numeric — 0.1.10 is newer than 0.1.9, which a " +
				"string sort gets backwards).") % [newer, older])
			return

	# NOTE — deliberately NOT asserted: that `DevLog.VERSION` equals the newest
	# entry. They are meant to differ. `AGENTS.md` has an entry carry "the version
	# the change will ship in (the next semantic-release bump implied by your
	# commit type)" and says **do NOT hand-edit `DevLog.VERSION`**, because
	# `cd.yaml` stamps it from the release tag at build time — the in-tree value is
	# only a dev placeholder. So the top entry legitimately runs AHEAD of it, and a
	# guard demanding equality would pass today by coincidence and then fail the
	# next player-visible PR that follows the documented workflow, pushing authors
	# to hand-edit exactly the constant the contract forbids touching.

	var newest: String = entries[0]["version"]
	print("TEST PASS — dev log holds (%d entries, %s down to %s: unique versions, strictly newest-first by numeric compare, all well-formed)"
		% [entries.size(), newest, entries[entries.size() - 1]["version"]])
	get_tree().quit(0)


## Compare two dotted version strings component-wise as INTEGERS. Returns >0 when
## `a` is newer, <0 when older, 0 when equal. Numeric comparison is the point: a
## string compare puts "0.1.9" above "0.1.10", so it would both mis-order a
## correct log and mask a genuine inversion once the patch number passes 9. A
## non-numeric component sorts as 0 rather than crashing — a malformed version is
## the well-formedness check's business, not this one's.
func _compare_versions(a: String, b: String) -> int:
	var pa := a.split(".")
	var pb := b.split(".")
	var n := maxi(pa.size(), pb.size())
	for i in n:
		var ia := int(pa[i]) if i < pa.size() else 0
		var ib := int(pb[i]) if i < pb.size() else 0
		if ia != ib:
			return 1 if ia > ib else -1
	return 0


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
