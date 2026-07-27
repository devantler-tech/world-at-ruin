extends Node
## Regression for #311: every dev-log entry file becomes an entry.
##
## Entries live one-per-file so that concurrent player-visible PRs stop
## colliding on a shared list. That trades a compile-time array for a directory
## read, which introduces a failure mode the old shape could not have: a file
## that is present but unreadable, unparseable, or misnamed is skipped, and the
## log renders one entry shorter with nothing to say so. `devlog_entries_test`
## cannot see it either — a list missing an entry is still unique, ordered and
## well-formed.
##
## So this pins the two properties that make the directory the source of truth:
##
##  1. EVERY FILE IS AN ENTRY — the count of `.json` files under the entry
##     directory equals `DevLog.ENTRIES.size()`. A silently dropped entry fails
##     here.
##  2. THE NAME IS THE VERSION — each file is named for the version it carries.
##     The filename is how an author finds the entry to edit and how two
##     concurrent PRs are guaranteed disjoint paths, so a file whose name and
##     content disagree breaks the very property this storage exists for.
##
## Plus non-vacuity: the directory must actually hold entries. A guard that
## inspects an empty directory would pass while the in-game log renders blank —
## which is the shape of failure an unexported directory would produce.
##
## Run: godot --headless --path client res://tests/devlog_storage_test.tscn

## Below this the log is too short to be a real record, matching
## devlog_entries_test's own floor.
const MIN_ENTRIES := 10


func _ready() -> void:
	var files: PackedStringArray = DirAccess.get_files_at(DevLog.ENTRY_DIR)
	var entry_files: Array[String] = []
	for name: String in files:
		# Same stem match the loader uses: an exported filesystem can present a
		# .json as .json.remap, and a guard that counted only the plain form
		# would report every entry missing on exactly the build that ships.
		var stem := name.trim_suffix(".remap")
		if stem.ends_with(".json"):
			entry_files.append(stem)

	if entry_files.size() < MIN_ENTRIES:
		_fail(("only %d entry file(s) under %s — the guards below would be near-vacuous, and this is "
			+ "what an unexported or missing entry directory looks like")
			% [entry_files.size(), DevLog.ENTRY_DIR])
		return

	# --- 1. EVERY FILE IS AN ENTRY ---
	var entries := DevLog.ENTRIES
	if entries.size() != entry_files.size():
		_fail(("%d entry file(s) under %s but DevLog.ENTRIES holds %d — a file was skipped as "
			+ "unreadable or unparseable, so the log is silently missing a release")
			% [entry_files.size(), DevLog.ENTRY_DIR, entries.size()])
		return

	# --- 2. THE NAME IS THE VERSION ---
	# Each file is compared against its OWN declared version. Asking instead
	# whether the filename appears somewhere among the loaded versions would be a
	# membership test, not a mapping one: swap the contents of two entry files and
	# every name would still be found, so both violations would pass.
	for file_name: String in entry_files:
		var named := file_name.trim_suffix(".json")
		var declared := _version_in(file_name)
		if declared != named:
			_fail(("%s%s declares version '%s' — the filename is how an author finds an entry and "
				+ "how two concurrent PRs stay on disjoint paths, so the two must agree")
				% [DevLog.ENTRY_DIR, file_name, declared])
			return

	print("TEST PASS — dev log is %d file(s) under %s, each named for the version it carries, all loaded"
		% [entries.size(), DevLog.ENTRY_DIR])
	get_tree().quit(0)


## The version a file actually declares, for a failure message that names the
## mismatch rather than restating the filename.
func _version_in(file_name: String) -> String:
	var file := FileAccess.open(DevLog.ENTRY_DIR + file_name, FileAccess.READ)
	if file == null:
		return "<unreadable>"
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is not Dictionary:
		return "<unparseable>"
	return String((parsed as Dictionary).get("version", "<missing>"))


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
