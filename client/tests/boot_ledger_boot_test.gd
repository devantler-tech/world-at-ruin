extends Node
## Boot test for the boot-recovery LEDGER being live (issue #301, parent #69).
##
## boot_recovery_test proves the core and the persistence are correct, and it
## would stay green with `main.gd` never calling either — which is exactly the
## state this test was written to end: every piece of the crash-loop guard
## existed, was covered, and did not run in the product. Only booting the real
## scene and reading what landed on disk can tell the difference.
##
## Structure — four boots, because a single one cannot separate "the guard ran"
## from "the guard is absent and the file happened to look right":
##  A. NEGATIVE CONTROL — a clean first boot. It must record an attempt and then
##     promote it, and it must quarantine NOTHING. Without this the quarantine
##     asserted in B is worthless: a wiring that quarantined on every launch, or
##     a seeded file that already held the entry, would satisfy B alone.
##  B. POSITIVE — seed a marker, as a launch that died before its checkpoint
##     would have left, and require the NEXT boot to quarantine exactly that
##     build and refuse to re-mount it.
##  C. GUARDRAIL — an unreadable ledger must still boot the game, and must NOT
##     be overwritten (laundering junk into a well-formed file is how a recorded
##     failure gets erased).
##  D. GUARDRAIL — a boot whose own build is already quarantined must still
##     boot. The guard exists to stop a boot loop; one that could refuse a
##     launch would be the thing it guards against.
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
## Run: godot --headless --path client res://tests/boot_ledger_boot_test.tscn

const ASSERT_TICK := 5
## A build distinct from the running one, standing in for the launch that died.
## Distinct on purpose: quarantining the RUNNING build would then refuse this
## boot's own attempt and tangle the two assertions together.
const FAILED_VERSION := "9.9.9"

var _ticks := 0
var _main: Node
var _save: SaveIsolation
## Which of the four boots is running.
var _phase := "control"


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
	_save = SaveIsolation.new("user://boot_ledger_probe.json")
	if not _save.begin():
		_fail("save isolation did not take — refusing to boot into the real save or recovery ledger")
		return
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
	return true


func _physics_process(_delta: float) -> void:
	_ticks += 1
	var world := _main.get_node_or_null("World") as WorldGen
	var player := _main.get_node_or_null("Wanderer") as Player
	if world == null or player == null:
		if _ticks > 10:
			_fail("main scene did not build World and Wanderer in the '%s' boot — recovery memory must never block a launch" % _phase)
		return
	if _ticks != ASSERT_TICK:
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


## A. The clean boot records an attempt and promotes it, and quarantines nothing.
func _assert_control() -> void:
	var raw: Variant = _read_probe()
	if raw == null:
		_fail(("THE LEDGER IS NOT LIVE: a clean boot wrote no recovery file at all. "
			+ "main.gd is not calling BootRecovery — the crash-loop guard is absent from "
			+ "the product however green its unit tests are"))
		return
	var doc: Dictionary = raw
	if doc.get("marker") != null:
		_fail("the clean boot left a boot-attempt marker behind (%s) — it never reached its checkpoint, so the NEXT launch would quarantine a build that booted fine" % str(doc.get("marker")))
		return
	if str(doc.get("last_good")) != DevLog.VERSION:
		_fail(("the clean boot did not promote itself: last_good is %s, expected %s. "
			+ "A boot that records an attempt but never clears it turns every launch into a "
			+ "recorded failure") % [str(doc.get("last_good")), DevLog.VERSION])
		return
	var ledger := doc.get("quarantined", []) as Array
	if not ledger.is_empty():
		_fail(("VACUOUS TEST GUARD: a clean boot quarantined %s. Nothing failed, so the "
			+ "quarantine asserted in the next phase would prove nothing") % str(ledger))
		return
	if not _save.real_save_untouched():
		_fail("the control boot touched the player's real save, vault or recovery ledger")
		return
	_begin_boot("failed_previous")


## B. A marker left by the previous launch is reconciled into a quarantine, and
## the failed build can no longer be mounted.
func _assert_failed_previous() -> void:
	var raw: Variant = _read_probe()
	if raw == null:
		_fail("the boot after a failed launch wrote no recovery file")
		return
	var doc: Dictionary = raw
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
	# This boot's own attempt must still have completed normally: recording a
	# previous failure may not cost the current launch its promotion.
	if str(doc.get("last_good")) != DevLog.VERSION:
		_fail("the recovering boot did not promote itself (last_good %s) — a launch that recovers is still a launch that worked" % str(doc.get("last_good")))
		return
	if not _save.real_save_untouched():
		_fail("the recovering boot touched the player's real save, vault or recovery ledger")
		return
	_begin_boot("torn")


## C. A torn ledger boots the game anyway, and is preserved rather than laundered.
func _assert_torn() -> void:
	# Reaching here at all means the world and the wanderer were built — the
	# degrade-never-block law held. What remains is that the evidence survived.
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
	var raw: Variant = _read_probe()
	if raw == null:
		_fail("the self-quarantined boot destroyed the recovery file")
		return
	var ledger := (raw as Dictionary).get("quarantined", []) as Array
	if not ledger.has(DevLog.VERSION):
		_fail(("the running build removed ITSELF from the quarantine ledger (%s) to record an "
			+ "attempt — quarantine is forward-only and a build may never launder its own "
			+ "failure away") % str(ledger))
		return
	if not _save.real_save_untouched():
		_fail("the self-quarantined boot touched the player's real save, vault or recovery ledger")
		return
	print(("TEST PASS — the boot-recovery ledger is live: a clean boot promotes and quarantines "
		+ "nothing, a marker left by a dead launch quarantines %s and refuses to re-mount it, "
		+ "and a torn or self-quarantined ledger still boots the game") % FAILED_VERSION)
	get_tree().quit(0)


## The probe parsed as JSON, or null when it is missing or unreadable.
func _read_probe() -> Variant:
	var path := _save.recovery_probe()
	if not FileAccess.file_exists(path):
		return null
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else null


func _fail(message: String) -> void:
	if _save != null:
		_save.end()
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _exit_tree() -> void:
	if _save != null:
		_save.end()
