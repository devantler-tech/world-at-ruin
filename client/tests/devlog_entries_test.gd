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
##  1. NO ENTRY TWICE — no version and title appear together twice. This is the
##     guard the issue asks for, because the duplication is a recurring class of
##     bug rather than a one-off: two PRs landing around each other is precisely
##     how an entry gets copied. A release may still carry SEVERAL entries (#518):
##     every placeholder that ships in it is stamped with its number, so a
##     shared version is two changes in one build, not a copy.
##  2. NEWEST FIRST, NUMERICALLY — versions descend. The comparison is
##     component-wise integer, never string: lexically "0.1.9" sorts ABOVE
##     "0.1.10", so a string compare would call a correct log broken (and hide a
##     real inversion once the patch number reaches double digits). Entries that
##     share a release order by date, newest first, then by title.
##  3. WELL-FORMED — every entry carries version/date/title/notes, notes are
##     non-empty strings, and the version is a release number or the
##     placeholder, so a half-written entry cannot ship silently.
##  4. PLACEHOLDER ENTRIES (#518) — an entry may carry `DevLog.NEXT_VERSION`
##     until the release build stamps it. Such entries are newer than every
##     released one, may be several at once, and cannot declare `shipped_in`.
##     No real entry is a placeholder yet, so these rules are also proven
##     against constructed logs, where a rule that could never fail is caught.
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

	var problem := _problem_in(entries)
	if not problem.is_empty():
		_fail(problem)
		return

	problem = _placeholder_cases()
	if not problem.is_empty():
		_fail(problem)
		return

	# NOTE — deliberately NOT asserted: that `DevLog.VERSION` equals the newest
	# entry. They are meant to differ. `AGENTS.md` has a new entry carry "next"
	# until the release build stamps it, and says **do NOT hand-edit
	# `DevLog.VERSION`**, because `cd.yaml` stamps that from the release tag at
	# build time — the in-tree value is only a dev placeholder. So the top entry
	# legitimately runs AHEAD of it, and a guard demanding equality would pass
	# today by coincidence and then fail the next player-visible PR that follows
	# the documented workflow, pushing authors to hand-edit exactly the constant
	# the contract forbids touching.

	var newest: String = entries[0]["version"]
	print("TEST PASS — dev log holds (%d entries, %s down to %s: no entry twice, newest-first by numeric compare, all well-formed; placeholder and shared-release entries order and validate)"
		% [entries.size(), newest, entries[entries.size() - 1]["version"]])
	get_tree().quit(0)


## The first way `entries` breaks the log's rules, or empty when it keeps them.
## Run over the real log and over constructed ones alike.
func _problem_in(entries: Array[Dictionary]) -> String:
	var release := RegEx.create_from_string("^[0-9]+\\.[0-9]+\\.[0-9]+$")

	# --- 3. WELL-FORMED: every entry is a complete, readable record ---
	for i in entries.size():
		var e: Dictionary = entries[i]
		for key: String in ["version", "date", "title", "notes"]:
			if not e.has(key):
				return "dev-log entry %d is missing '%s'" % [i, key]
		for key: String in ["version", "date", "title"]:
			var value: Variant = e[key]
			if value is not String or (value as String).is_empty():
				return "dev-log entry %d has an empty or non-string '%s'" % [i, key]
		var version := String(e["version"])
		if version != DevLog.NEXT_VERSION and release.search(version) == null:
			return ("dev-log entry %d has version '%s', which is neither a release number (X.Y.Z) " +
				"nor the placeholder '%s'") % [i, version, DevLog.NEXT_VERSION]
		var notes: Variant = e["notes"]
		if notes is not Array or (notes as Array).is_empty():
			return "dev-log entry '%s' has no notes — an entry with nothing to say should not ship" % version
		for note: Variant in (notes as Array):
			if note is not String or (note as String).is_empty():
				return "dev-log entry '%s' has an empty or non-string note" % version
		# Optional, and only on an entry whose own version was never cut (#466).
		# Which release it names is proved against the repository's tags by
		# tools/devlog-entry-version-guard.sh, which can see them; the property
		# checkable from the data alone is that it points FORWARD. A declaration
		# at or below the entry's own number would render as "never released;
		# first shipped in" an earlier build, which is unreadable rather than
		# merely wrong.
		if e.has("shipped_in"):
			if version == DevLog.NEXT_VERSION:
				return ("dev-log entry '%s' is a placeholder that declares 'shipped_in' — its release " +
					"is stamped at build time, so there is no never-cut number to explain") % e["title"]
			var shipped: Variant = e["shipped_in"]
			if shipped is not String or (shipped as String).is_empty():
				return "dev-log entry '%s' has an empty or non-string 'shipped_in'" % version
			if _compare_versions(shipped as String, version) <= 0:
				return ("dev-log entry '%s' declares it first shipped in '%s', which is not ABOVE it. An entry " +
					"declares this because its own version was never cut, so the release that carried it is " +
					"necessarily a later one.") % [version, shipped]

	# --- 1. NO ENTRY TWICE: the #119 guard ---
	# Keyed on version AND title. A release can carry several entries, so a
	# shared version alone is not a copy; the same entry twice is.
	var seen: Dictionary = {}
	for e: Dictionary in entries:
		var key := "%s\n%s" % [e["version"], e["title"]]
		if seen.has(key):
			return ("dev log lists '%s — %s' TWICE — a duplicated entry makes the log show the same " +
				"change twice and reads as a rendering bug (issue #119): keep exactly one copy of each " +
				"entry.") % [e["version"], e["title"]]
		seen[key] = true

	# --- 2. NEWEST FIRST, compared numerically rather than as strings ---
	for i in range(1, entries.size()):
		var newer: String = entries[i - 1]["version"]
		var older: String = entries[i]["version"]
		if older == DevLog.NEXT_VERSION:
			if newer != DevLog.NEXT_VERSION:
				return ("dev log lists released '%s' above an unreleased entry — an entry not yet in any " +
					"release is newer than all of them") % newer
			if String(entries[i - 1]["date"]) < String(entries[i]["date"]):
				return "unreleased entries %d and %d are not newest-first by date" % [i - 1, i]
			continue
		if newer == DevLog.NEXT_VERSION:
			continue
		var cmp := _compare_versions(newer, older)
		if cmp == 0:
			# Two changes in one release: newest by date first, as the loader
			# orders them.
			if String(entries[i - 1]["date"]) < String(entries[i]["date"]):
				return "entries %d and %d share release '%s' but are not newest-first by date" % [i - 1, i, newer]
			continue
		if cmp < 0:
			return ("dev log is out of order: '%s' is listed above '%s' but is OLDER. Entries run " +
				"newest first (note the comparison is numeric — 0.1.10 is newer than 0.1.9, which a " +
				"string sort gets backwards).") % [newer, older]
	return ""


## Constructed logs that exercise the placeholder rules, since the real log has
## no placeholder entry to exercise them yet. Each rule must pass its good case
## AND refuse its bad one, or it could not fail at all.
func _placeholder_cases() -> String:
	var older_next := _entry(DevLog.NEXT_VERSION, "2026-09-24", "Older unreleased")
	var newer_next := _entry(DevLog.NEXT_VERSION, "2026-09-25", "Newer unreleased")
	var released := _entry("0.98.0", "2026-09-05", "Released")
	var earlier := _entry("0.93.1", "2026-09-01", "Released earlier")

	# The loader's own ordering puts both placeholders first, newest by date.
	var shuffled: Array[Dictionary] = [released, older_next, earlier, newer_next]
	var ordered := DevLog.newest_first(shuffled)
	var expected: Array[Dictionary] = [newer_next, older_next, released, earlier]
	if ordered != expected:
		return "DevLog orders placeholder entries as %s, not newest-first above every release" % [
			ordered.map(func(e: Dictionary) -> String: return String(e["title"]))]
	var problem := _problem_in(expected)
	if not problem.is_empty():
		return "a well-formed log with two placeholder entries was refused: %s" % problem

	var below: Array[Dictionary] = [released, newer_next, earlier]
	if _problem_in(below).is_empty():
		return "a placeholder entry listed below a released one was accepted"
	var declaring := _entry(DevLog.NEXT_VERSION, "2026-09-25", "Declares")
	declaring["shipped_in"] = "0.99.0"
	var with_declaring: Array[Dictionary] = [declaring, released]
	if _problem_in(with_declaring).is_empty():
		return "a placeholder entry declaring 'shipped_in' was accepted"
	for bad: String in ["0.98", "v0.98.0", "Next"]:
		var malformed: Array[Dictionary] = [_entry(bad, "2026-09-25", "Malformed")]
		if _problem_in(malformed).is_empty():
			return "version '%s' was accepted as either a release number or the placeholder" % bad

	# What a release build holds once two placeholders ship together: both are
	# stamped with the same number. That is two changes in one build, and the
	# loader gives them a fixed order — newest by date, then by title.
	var stamped_older := _entry("0.99.0", "2026-09-24", "Older change")
	var stamped_newer := _entry("0.99.0", "2026-09-25", "Newer change")
	var stamped_same_day := _entry("0.99.0", "2026-09-25", "Another change")
	var shipped_together: Array[Dictionary] = [released, stamped_older, stamped_newer, stamped_same_day]
	var together := DevLog.newest_first(shipped_together)
	var together_expected: Array[Dictionary] = [stamped_same_day, stamped_newer, stamped_older, released]
	if together != together_expected:
		return "DevLog orders entries sharing a release as %s, not newest by date then by title" % [
			together.map(func(e: Dictionary) -> String: return String(e["title"]))]
	problem = _problem_in(together_expected)
	if not problem.is_empty():
		return "a release carrying three entries was refused: %s" % problem
	var inverted: Array[Dictionary] = [stamped_older, stamped_newer, released]
	if _problem_in(inverted).is_empty():
		return "entries sharing a release, listed oldest first, were accepted"

	# The #119 copy: the same entry twice, whether released or not.
	var copied: Array[Dictionary] = [stamped_newer, stamped_newer.duplicate(), released]
	if _problem_in(copied).is_empty():
		return "a released entry listed twice was accepted"
	var copied_next: Array[Dictionary] = [newer_next, newer_next.duplicate(), released]
	if _problem_in(copied_next).is_empty():
		return "an unreleased entry listed twice was accepted"
	return ""


func _entry(version: String, date: String, title: String) -> Dictionary:
	return {"version": version, "date": date, "title": title, "notes": ["What changed, in one line."]}


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
