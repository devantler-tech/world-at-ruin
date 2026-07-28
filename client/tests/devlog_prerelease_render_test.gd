extends Node
## Regression test for the pre-release block in the rendered dev log (issue #466).
##
## Seventeen entries carry a version that was never cut — they were written
## before the repo's first tag, so `v0.1.0` names a build that has never
## existed. The log rendered them exactly like released ones, so it told the
## maintainer a change arrived in a build he could have played, and anyone
## reading the log to find when something appeared was pointed at nothing.
##
## Renaming them onto the release that carried them is not available: fifteen
## first shipped in `v0.1.15`, and filenames, `devlog_storage_test` and
## `devlog_entries_test` all require versions to be unique. So the entry keeps
## its number as its identity and declares where its change actually landed,
## and the RENDERER is what stops the number reading as a build:
##
##  1. A declaring entry drops the `v`. The `v` is the whole of what makes a
##     number read as a release tag, and this is the assertion that fails if a
##     later change renders every entry through one uniform header again.
##  2. It names where the change first shipped, so the log answers the question
##     the wrong number used to answer incorrectly.
##  3. An ordinary entry is untouched — the fix must not restyle the 46 entries
##     that were always correct.
##
## Non-vacuity is asserted rather than assumed: with no declaring entry (or no
## ordinary one) the checks above pass while proving nothing, which is exactly
## what this would look like if the declarations were dropped from the data.
##
## Pure string composition over the real entries — no save IO and no main.tscn
## boot, so it is safe headless and deterministic.
##
## Run: godot --headless --path client res://tests/devlog_prerelease_render_test.tscn

## The marker the renderer emits for a declaring entry. Stated once here and
## compared against the real output, so a reworded note is a deliberate edit to
## this test rather than a silent loss of the correction.
const SHIPPED_NOTE := "never released; first shipped in v%s"

var _failed := false


func _ready() -> void:
	var hud := Hud.new()
	add_child(hud)
	var rendered: String = hud._render_devlog()

	var declaring := 0
	var ordinary := 0
	for entry: Dictionary in DevLog.ENTRIES:
		var version := String(entry["version"])
		var shipped_in := String(entry.get("shipped_in", ""))
		# The header a released entry gets. The trailing " — " is load-bearing:
		# without it "v0.1.1" is a prefix of "v0.1.15" and the two entries'
		# assertions would read each other's headers.
		var release_header := "[b]v%s — " % version
		if shipped_in.is_empty():
			ordinary += 1
			if not rendered.contains(release_header):
				_fail(("entry %s renders without its 'v%s — ' header — it names a release that was "
					+ "actually cut, so it must keep reading as the build it shipped in")
					% [version, version])
				return
			continue

		declaring += 1
		if rendered.contains(release_header):
			_fail(("entry %s still renders as 'v%s' — that version was NEVER released, so the leading "
				+ "v presents a build the reader could not have played. Drop it for a declaring entry.")
				% [version, version])
			return
		if not rendered.contains("[b]%s — " % version):
			_fail("entry %s does not render its own number at all — it is the entry's identity and how the log stays ordered" % version)
			return
		if not rendered.contains(SHIPPED_NOTE % shipped_in):
			_fail(("entry %s does not say where its change first shipped (expected '%s') — without it the log "
				+ "drops the number's meaning instead of correcting it")
				% [version, SHIPPED_NOTE % shipped_in])
			return

	if declaring == 0:
		_fail("no dev-log entry declares 'shipped_in', so every check above passed vacuously — the pre-release block is what this test exists for")
		return
	if ordinary == 0:
		_fail("every dev-log entry declares 'shipped_in', so the untouched-ordinary-entry check passed vacuously")
		return

	print("TEST PASS — dev log renders %d pre-release entries without a v and naming where they shipped, %d released entries unchanged"
		% [declaring, ordinary])
	get_tree().quit(0)


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
