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

## The pre-release block, by exact membership. A CLOSED set: these are the
## entries written before the repo's first tag, nothing can join them later
## (`devlog-entry-version-guard.sh` refuses `shipped_in` on an entry that has not
## shipped, which every new entry is), and an entry only leaves by being deleted.
##
## Pinned as the whole list rather than as a count or a "at least one" floor,
## because the failure this guards against is ONE entry silently losing its
## declaration. Such an entry falls back to rendering `v0.1.4 — …`, which is
## exactly the misleading form this change removed, and every other check would
## still pass: the sweep reclassifies it `NEVER-CUT`, which the gate excludes;
## `check_shipped_in` skips an entry with no declaration to skip; and a floor of
## "some entry declares" is still satisfied by the other sixteen. Membership is
## the only assertion that fails on a single-entry regression.
const PRE_RELEASE_BLOCK: Array[String] = [
	"0.1.0", "0.1.1", "0.1.2", "0.1.3", "0.1.4", "0.1.5", "0.1.6", "0.1.7",
	"0.1.8", "0.1.9", "0.1.10", "0.1.11", "0.1.12", "0.1.13", "0.1.14",
	"0.1.16", "0.1.17",
]

var _failed := false


func _ready() -> void:
	var hud := Hud.new()
	add_child(hud)
	var rendered: String = hud._render_devlog()

	var declaring: Array[String] = []
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

		declaring.append(version)
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

	# --- MEMBERSHIP: the block is exactly this set, no more and no less ---
	# Reported as the difference in each direction rather than as a count
	# mismatch, so the message names the entry to look at.
	var missing: Array[String] = []
	for version: String in PRE_RELEASE_BLOCK:
		if not declaring.has(version):
			missing.append(version)
	if not missing.is_empty():
		_fail(("dev-log entries no longer declaring 'shipped_in': %s — each falls straight back to rendering "
			+ "'v<version> — ', the misleading form naming a build that was never cut. Nothing else "
			+ "catches this: the sweep reclassifies such an entry NEVER-CUT, which the gate excludes, "
			+ "and the guard has no declaration left to check.")
			% [", ".join(missing)])
		return
	var unexpected: Array[String] = []
	for version: String in declaring:
		if not PRE_RELEASE_BLOCK.has(version):
			unexpected.append(version)
	if not unexpected.is_empty():
		_fail(("dev-log entries declaring 'shipped_in' outside the pre-release block: %s. The block is "
			+ "closed — it is the entries written before the repo's first tag, and an entry that has "
			+ "shipped since cannot join it. An ordinarily mislabelled entry is corrected by renaming "
			+ "it onto the release that contains it, not by declaring where it landed.")
			% [", ".join(unexpected)])
		return
	if ordinary == 0:
		_fail("every dev-log entry declares 'shipped_in', so the untouched-ordinary-entry check passed vacuously")
		return

	print("TEST PASS — dev log renders the %d-entry pre-release block without a v and naming where each shipped, %d released entries unchanged"
		% [declaring.size(), ordinary])
	get_tree().quit(0)


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
