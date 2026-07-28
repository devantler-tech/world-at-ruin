extends Node
## Boot test for the boot-recovery LEDGER being live (issue #301, parent #69).
##
## boot_recovery_test proves the core and the persistence are correct, and it
## would stay green with `main.gd` never calling either — which is exactly the
## state this test was written to end: every piece of the crash-loop guard
## existed, was covered, and did not run in the product. Only booting the real
## scene and reading what landed on disk can tell the difference.
##
## SCOPE — this slice wires the RECONCILE half only (`load_state` → `reconcile`
## → `save_state`). Marking (`begin_attempt`/`promote`) is deliberately NOT wired:
## its only honest subject is a staged pack, and approximating it with the running
## build is unrecoverable — an interrupted startup would quarantine the installed
## build, and `begin_attempt` refuses quarantined versions, so no later successful
## boot could clear it. The tests below therefore assert reconcile behaviour, and
## the ABSENCE of marking is itself part of the contract (phase A).
##
## Structure — five boots, because a single one cannot separate "the guard ran"
## from "the guard is absent and the file happened to look right":
##  A. NEGATIVE CONTROL — a clean boot must persist the active writer schema,
##     quarantine NOTHING, and must not mark anything either. Without this the
##     quarantine asserted in B is worthless: a wiring that quarantined on every
##     launch would satisfy B on its own. It also pins the no-marking decision,
##     so re-introducing `begin_attempt` here fails loudly rather than silently
##     reviving the unrecoverable case.
##  B. POSITIVE — seed a marker, as a launch that died before its checkpoint
##     would have left, and require the NEXT boot to quarantine exactly that
##     build and refuse to re-mount it. This is the load-bearing liveness proof:
##     it fails against a main.gd that never calls reconcile.
##  C. GUARDRAIL — an unreadable ledger must still boot the game, and must NOT
##     be overwritten (laundering junk into a well-formed file is how a recorded
##     failure gets erased).
##  D. GUARDRAIL — a boot whose own build is already quarantined must still
##     boot. The guard exists to stop a boot loop; one that could refuse a
##     launch would be the thing it guards against.
##  E. POSITIVE — a marker that is PENDING BUT UNREADABLE must be cleared ON
##     DISK. reconcile clears it in memory but cannot name the failed build, so
##     it reports an empty `quarantined_version`; a caller that decides whether
##     to save from that field alone drops the write and leaves the bad marker
##     forever. Every later launch then repeats the condition and the pack-mount
##     path keeps refusing new attempts because a marker is still pending. B
##     cannot catch this — there the version IS nameable, so the save happens
##     for the wrong reason and passes.
##
## Every boot runs behind SaveIsolation, so the player's real character, vault
## and recovery ledger are never read or written — quarantine is forward-only,
## so a test that marked the real installed build could never be undone.
##
## The ledger is read back by parsing the JSON directly rather than through
## BootRecovery.load_state: the oracle must not share a branch with the code
## under test, or a loader that silently defaulted a missing key would agree
## with itself (the DESTINATION_ORACLE lesson from vault_restore_boot_test).
##
## Each phase judges the ledger only once the booted scene reports itself ready,
## and then re-reads it until it is readable or a bounded deadline passes. The
## reconcile write is synchronous inside that `_ready()`, so the wait is normally
## over on the first look; what the bound buys is that a read arriving before the
## write can never be reported as data loss, while a ledger that never appears
## still fails loudly instead of hanging. This guard names a product-law
## violation when it fails, so it may only ever name one it actually observed —
## a guard that cries data loss at random is the one kind of red that gets
## learned as noise, and the day it reports a genuine loss it would read exactly
## like those false alarms.
##
## Run: godot --headless --path client res://tests/boot_ledger_boot_test.tscn

## The earliest frame at which a phase may judge what the boot left on disk;
## every boot needs a few frames to build its world first.
const ASSERT_TICK := 5
## How long a phase keeps re-reading the ledger before it gives a verdict.
const PROBE_DEADLINE_TICK := 180
## When to give up on the scene itself. Recovery memory must never block a
## launch, so a world that never builds is a failure of that law.
const SCENE_DEADLINE_TICK := 10
## A build distinct from the running one, standing in for the launch that died.
## Distinct on purpose: quarantining the RUNNING build would then refuse this
## boot's own attempt and tangle the two assertions together.
const FAILED_VERSION := "9.9.9"
## A marker that is present but is not a version, so reconcile can clear it yet
## can name nothing to quarantine. A JSON number rather than a junk string: it
## survives a parse, which is what puts it past load_state and into reconcile.
const UNREADABLE_MARKER := "42"

var _ticks := 0
var _main: Node
var _save: SaveIsolation
## Which of the five boots is running.
var _phase := "control"
## The identity of the ledger bytes [method _seed] last wrote, for the
## compare-and-swap threading assertions (#453).
var _seeded_identity := BootRecovery.IDENTITY_ABSENT


func _ready() -> void:
	_begin_boot("control")


## Tear down any previous scene, redirect the save seams, optionally seed a
## recovery ledger, then boot main.tscn.
func _begin_boot(phase: String) -> void:
	_phase = phase
	_ticks = 0
	if _main != null:
		_main.queue_free()
		_main = null
	# Each phase models a new executable launch. BootRecovery's refused-path
	# latch correctly survives for a real process lifetime, so reset it at this
	# synthetic process boundary just as SaveVault's multi-case tests do.
	BootRecovery.clear_refusals_for_test()
	_save = SaveIsolation.new("user://boot_ledger_probe.json")
	if not _save.begin():
		_fail("save isolation did not take — refusing to boot into the real save or recovery ledger")
		return
	# Machine-readable evidence for the cross-process isolation guard.
	print("SAVE_ISOLATION_PROBE=%s" % CharacterStore.save_path())
	# begin() starts from clean probes, so the seed goes in afterwards.
	match phase:
		"failed_previous":
			# Exactly what a launch that never reached its checkpoint leaves.
			if not _seed('{"marker": "%s", "quarantined": [], "last_good": null}' % FAILED_VERSION):
				return
		"torn":
			if not _seed("this is not json"):
				return
		"self_quarantined":
			if not _seed('{"marker": null, "quarantined": ["%s"], "last_good": null}' % DevLog.VERSION):
				return
		"unreadable_marker":
			# Well-formed JSON carrying all three keys, so the file LOADS — the
			# marker alone is junk. That is the whole point: a torn file (phase
			# C) never reaches reconcile, so only a loadable file with an
			# unreadable marker exercises the clear-without-a-version path.
			if not _seed('{"marker": %s, "quarantined": [], "last_good": null}' % UNREADABLE_MARKER):
				return
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(_main)


## Write a raw ledger body to the probe. Raw rather than through save_state so a
## deliberately unreadable file can be seeded at all — save_state refuses to
## write one, which is the very behaviour phase C checks.
func _seed(body: String) -> bool:
	var file := FileAccess.open(_save.recovery_probe(), FileAccess.WRITE)
	if file == null:
		_fail("could not seed the recovery probe at %s" % _save.recovery_probe())
		return false
	file.store_string(body)
	file.close()
	# What the booting scene must compare against: the bytes that are on disk the
	# moment before it reads them. Recorded here rather than derived in the
	# assertion, so the oracle is the seed itself and not a second call to the
	# primitive under test.
	_seeded_identity = BootRecovery.document_identity(_save.recovery_probe())
	return true


func _physics_process(_delta: float) -> void:
	# _begin_boot returns without a scene when seeding or isolation fails, and
	# get_tree().quit() does not halt the frame (#305) — so this runs at least
	# once more with _main still null. Dereferencing it there throws BEFORE the
	# real failure message is printed, replacing a precise diagnosis with a null
	# access.
	if _main == null:
		return
	_ticks += 1
	var world := _main.get_node_or_null("World") as WorldGen
	var player := _main.get_node_or_null("Wanderer") as Player
	# is_node_ready() is what makes "the boot has finished writing" checkable
	# rather than assumed: _reconcile_boot_recovery() is the first thing
	# main.tscn's _ready() does, so a scene that reports ready has already been
	# through its recovery write. Without this the phases below could read the
	# ledger before the write and report the gap as a write that never happened.
	if world == null or player == null or not _main.is_node_ready():
		if _ticks > SCENE_DEADLINE_TICK:
			_fail("main scene did not build World and Wanderer in the '%s' boot — recovery memory must never block a launch" % _phase)
		return
	# `>=`, never `==`: an exact-tick assertion does nothing at all on every later
	# frame, so a boot that became ready one frame late would leave the phase
	# spinning until the CI timeout instead of ever reaching a verdict.
	if _ticks < ASSERT_TICK:
		return

	match _phase:
		"control":
			_assert_control()
		"failed_previous":
			_assert_failed_previous()
		"torn":
			_assert_torn()
		"self_quarantined":
			_assert_self_quarantined()
		"unreadable_marker":
			_assert_unreadable_marker()


## A. A clean boot persists the active writer schema, quarantines nothing and
## marks nothing.
func _assert_control() -> void:
	var probe := _await_probe()
	if probe["state"] == "pending":
		return
	if probe["state"] != "ok":
		_fail("a clean first boot did not persist boot recovery schema v%d — %s" % [
			BootRecovery.WRITE_VERSION, _probe_evidence(probe)])
		return
	var doc: Dictionary = probe["doc"]
	if doc.get("version", -1) != BootRecovery.WRITE_VERSION:
		_fail("a clean first boot persisted recovery schema %s instead of active writer schema v%d" % [
			str(doc.get("version")), BootRecovery.WRITE_VERSION])
		return
	var ledger := doc.get("quarantined", []) as Array
	if not ledger.is_empty():
		_fail(("VACUOUS TEST GUARD: a clean boot quarantined %s. Nothing failed, so the "
			+ "quarantine asserted in the next phase would prove nothing") % str(ledger))
		return
	if doc.get("marker") != null:
		_fail(("a clean boot left a boot-attempt marker (%s). Marking the RUNNING build is "
			+ "unrecoverable — an interrupted startup quarantines the installed build, and "
			+ "begin_attempt refuses quarantined versions, so no later successful boot can "
			+ "ever clear it. Marking belongs to the pack-mount path")
			% str(doc.get("marker")))
		return
	# The first-boot write must be GUARDED, not blind. A ledger created by cloud
	# sync between this shell's load and its rename would otherwise be discarded
	# along with whatever quarantine record it carried (#453).
	if BootRecovery._last_write_expectation != BootRecovery.IDENTITY_ABSENT:
		_fail(("the first-boot write did not compare against the absence it read "
			+ "(expectation %s). A blind first-boot write discards a ledger another "
			+ "writer created after the load")
			% _describe_expectation(BootRecovery._last_write_expectation))
		return
	if not _save.real_save_untouched():
		_fail("the control boot touched the player's real save, vault or recovery ledger")
		return
	_begin_boot("failed_previous")


## B. A marker left by the previous launch is reconciled into a quarantine, and
## the failed build can no longer be mounted.
func _assert_failed_previous() -> void:
	var probe := _await_probe(_marker_cleared)
	if probe["state"] == "pending":
		return
	if probe["state"] != "ok":
		_fail("the boot after a failed launch left no readable recovery file — %s" % _probe_evidence(probe))
		return
	var doc: Dictionary = probe["doc"]
	var ledger := doc.get("quarantined", []) as Array
	if not ledger.has(FAILED_VERSION):
		_fail(("RECONCILE DID NOT RUN: a marker for %s was on disk — the previous launch died "
			+ "before its checkpoint — and this boot did not quarantine it (ledger %s). "
			+ "The player would be re-mounted into the same broken build every launch")
			% [FAILED_VERSION, str(ledger)])
		return
	if doc.get("marker") != null:
		_fail("the marker was not cleared after reconcile (%s) — the failure would be recorded again on every future launch" % str(doc.get("marker")))
		return
	# The obligation is that the failed build is never re-mounted. is_quarantined
	# is the predicate RollbackSelection.select itself consults, so asserting it
	# here covers selection without building a full rollback catalogue whose
	# unrelated required fields would make this test about select() instead.
	if not RollbackSelection.is_quarantined(ledger, FAILED_VERSION):
		_fail("%s is in the ledger but is_quarantined says otherwise — selection would offer the failed build again" % FAILED_VERSION)
		return
	if BootRecovery.begin_attempt(doc, FAILED_VERSION)["ok"] as bool:
		_fail("%s was quarantined and begin_attempt STILL accepted it — the boot loop is not actually closed" % FAILED_VERSION)
		return
	# THE THREADING PROOF (#453). The reconcile write is protected only if it
	# compares against the document it actually READ. A caller passing
	# IDENTITY_UNCHECKED writes correctly whenever nothing races it, so every
	# assertion above — and even a replay of this caller's own sequence — passes
	# while the guard is absent from the product. That exact ablation was measured
	# slipping through the vault's end-to-end coverage, so the expectation the
	# production write ran under is asserted directly rather than inferred from a
	# correct-looking file.
	#
	# This phase, not the control one, carries the load-bearing version: here a
	# real ledger existed, so the expectation must be its SHA-256 — a value that
	# is neither sentinel and cannot be produced by forgetting to thread anything.
	if BootRecovery._last_write_expectation == BootRecovery.IDENTITY_UNCHECKED:
		_fail("the reconcile write ran BLIND — the compare-and-swap never runs on the "
			+ "production path, so a foreign writer's quarantine record is silently "
			+ "renamed away exactly when it matters most")
		return
	if BootRecovery._last_write_expectation != _seeded_identity:
		_fail(("the reconcile write compared against %s rather than the ledger it read (%s). "
			+ "An expectation captured after the load would pass this check only by "
			+ "accident, and would let a write interleaved with the load through")
			% [
				_describe_expectation(BootRecovery._last_write_expectation),
				_describe_expectation(_seeded_identity),
			])
		return
	if not _save.real_save_untouched():
		_fail("the recovering boot touched the player's real save, vault or recovery ledger")
		return
	_begin_boot("torn")


## Name an identity for a failure message. The sentinels are a single character
## each, so printing them raw produces messages like `expectation ` that read as
## a formatting bug rather than as the diagnosis.
func _describe_expectation(identity: String) -> String:
	match identity:
		BootRecovery.IDENTITY_UNCHECKED:
			return "IDENTITY_UNCHECKED (a blind replace)"
		BootRecovery.IDENTITY_ABSENT:
			return "IDENTITY_ABSENT (no ledger on disk)"
		BootRecovery.IDENTITY_UNREADABLE:
			return "IDENTITY_UNREADABLE (present but unhashable)"
		_:
			return "identity %s" % identity


## C. A torn ledger boots the game anyway, and is preserved rather than laundered.
func _assert_torn() -> void:
	# Reaching here at all means the world and the wanderer were built — the
	# degrade-never-block law held. What remains is that the evidence survived.
	# No wait here, and none is wanted: this phase's file is seeded before the
	# boot and the whole assertion is that the boot left it alone. Absence is
	# still called out separately, because get_file_as_string answers a missing
	# file with "" — which would otherwise be reported as an overwrite with
	# empty content rather than as the removal it is.
	if not FileAccess.file_exists(_save.recovery_probe()):
		_fail("the unreadable ledger was REMOVED — the player loses the one record that would "
			+ "have stopped a boot loop, and a file that is gone is a different failure from the "
			+ "overwrite this phase guards against")
		return
	var text := FileAccess.get_file_as_string(_save.recovery_probe())
	if text != "this is not json":
		_fail(("the unreadable ledger was OVERWRITTEN with %s — a well-formed file holding a "
			+ "lie erases whatever failure the torn file was hiding, and the player loses the "
			+ "one record that would have stopped a boot loop") % JSON.stringify(text))
		return
	if not _save.real_save_untouched():
		_fail("the torn-ledger boot touched the player's real save, vault or recovery ledger")
		return
	_begin_boot("self_quarantined")


## D. A build that is itself quarantined still boots.
func _assert_self_quarantined() -> void:
	# Again, arriving here means the world built. The ledger must also be intact:
	# the boot may not quietly un-quarantine itself to get its attempt recorded.
	var probe := _await_probe()
	if probe["state"] == "pending":
		return
	if probe["state"] != "ok":
		# This phase seeds the ledger before the boot, so — and only so — absence
		# here really is destruction. Saying which of the two states was seen
		# keeps a genuine loss distinguishable from a file replaced with junk.
		_fail("the self-quarantined boot destroyed or replaced the seeded recovery ledger — %s" % _probe_evidence(probe))
		return
	var ledger := (probe["doc"] as Dictionary).get("quarantined", []) as Array
	if not ledger.has(DevLog.VERSION):
		_fail(("the running build removed ITSELF from the quarantine ledger (%s) to record an "
			+ "attempt — quarantine is forward-only and a build may never launder its own "
			+ "failure away") % str(ledger))
		return
	if not _save.real_save_untouched():
		_fail("the self-quarantined boot touched the player's real save, vault or recovery ledger")
		return
	_begin_boot("unreadable_marker")


## E. A pending-but-unreadable marker is cleared ON DISK, not only in memory.
func _assert_unreadable_marker() -> void:
	var probe := _await_probe(_marker_cleared)
	if probe["state"] == "pending":
		return
	if probe["state"] != "ok":
		_fail(("the unreadable-marker boot destroyed or replaced the recovery file — the ledger "
			+ "loaded fine and only its marker was junk, so there was nothing to preserve as "
			+ "evidence. %s") % _probe_evidence(probe))
		return
	var doc: Dictionary = probe["doc"]
	if doc.get("marker") != null:
		_fail(("the pending marker %s was NOT cleared on disk — reconcile clears it in memory but "
			+ "cannot name the failed build, so a caller that decides to save from "
			+ "quarantined_version alone drops the write. The marker then stays forever: every "
			+ "launch repeats this, and the pack-mount path refuses new attempts while one is "
			+ "pending") % str(doc.get("marker")))
		return
	var ledger := doc.get("quarantined", []) as Array
	if not ledger.is_empty():
		_fail(("VACUOUS TEST GUARD: an unreadable marker quarantined %s. Nothing nameable failed, "
			+ "so a build was invented — clearing the marker must never fabricate a victim")
			% str(ledger))
		return
	if not _save.real_save_untouched():
		_fail("the unreadable-marker boot touched the player's real save, vault or recovery ledger")
		return
	print(("TEST PASS — reconcile is live: a clean first boot persists recovery v%d while "
		+ "quarantining and marking nothing, a marker left by a dead launch quarantines %s "
		+ "and refuses to re-mount it, a torn or "
		+ "self-quarantined ledger still boots the game, and a pending-but-unreadable marker is "
		+ "cleared on disk rather than wedging every future launch")
		% [BootRecovery.WRITE_VERSION, FAILED_VERSION])
	get_tree().quit(0)


## What the recovery ledger looks like right now, keeping apart the outcomes a
## caller must never conflate.
##
## Answering "missing", "not JSON" and "not written yet" with one bare null is
## what let this harness report data loss for a read that simply arrived early.
## Each caller below therefore gets a state it can name in its own message:
##   pending    — nothing settled yet and the deadline has not passed; the
##                caller returns and looks again next frame.
##   ok         — `doc` holds the parsed ledger.
##   absent     — the deadline passed with no file at all.
##   unreadable — the deadline passed with a file that is not a JSON object;
##                `body` carries what was actually on disk.
##
## A phase whose ledger is SEEDED passes `settled` — the visible mark the boot's
## own write leaves. Readability alone cannot serve there: the seed already
## parses, so such a phase would otherwise judge the boot's work against the
## content that preceded it. On the deadline the last read is returned as `ok`
## anyway, so the phase renders its own precise verdict on what it found instead
## of every stall collapsing into one timeout message.
func _await_probe(settled: Callable = Callable()) -> Dictionary:
	var path := _save.recovery_probe()
	if FileAccess.file_exists(path):
		var text := FileAccess.get_file_as_string(path)
		var parsed: Variant = JSON.parse_string(text)
		if parsed is Dictionary:
			var doc := parsed as Dictionary
			var waiting := settled.is_valid() and not (settled.call(doc) as bool)
			if waiting and _ticks < PROBE_DEADLINE_TICK:
				return {"state": "pending"}
			return {"state": "ok", "doc": doc}
		if _ticks < PROBE_DEADLINE_TICK:
			return {"state": "pending"}
		return {"state": "unreadable", "body": text}
	if _ticks < PROBE_DEADLINE_TICK:
		return {"state": "pending"}
	return {"state": "absent"}


## Reconcile's one visible effect on disk that every seeded phase shares: a
## pending marker is cleared. Waiting on it is what makes those phases judge the
## boot's write rather than the seed that preceded it.
func _marker_cleared(doc: Dictionary) -> bool:
	return doc.get("marker") == null


## What was actually observed, in the words of the thing observed, so a failure
## states its evidence rather than asserting a cause it cannot see.
func _probe_evidence(probe: Dictionary) -> String:
	var waited := _ticks - ASSERT_TICK
	match str(probe.get("state")):
		"absent":
			return ("no file exists at %s, still absent %d frames after the boot reported ready — "
				+ "the reconcile write runs inside that same _ready(), so this is a file that is "
				+ "not coming rather than one that has yet to arrive") % [
					_save.recovery_probe(), waited]
		"unreadable":
			var body := str(probe.get("body"))
			return ("the file at %s still does not parse as a JSON object %d frames after the boot "
				+ "reported ready (%d bytes: %s)") % [
					_save.recovery_probe(), waited, body.length(), JSON.stringify(body)]
	return "the probe reported an unexpected state %s" % JSON.stringify(probe)


## Report a failure — and NEVER let the reported one hide an isolation breach.
##
## `real_save_untouched()` is asked BEFORE `end()`, because ending clears the
## seams and removes the probes: afterwards there is nothing left to compare.
## Tearing down first meant a run that both failed an assertion and wrote the
## player's real save reported only the assertion, and the breach — much the
## worse of the two — went unmentioned.
func _fail(message: String) -> void:
	var breached := false
	if _save != null:
		breached = not _save.real_save_untouched()
		_save.end()
	if breached:
		message += (" — AND the run touched the player's real save, vault or recovery ledger; "
			+ "the isolation breach outranks the failure above")
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _exit_tree() -> void:
	if _save != null:
		_save.end()
