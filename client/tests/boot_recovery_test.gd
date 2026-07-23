extends Node
## Regression test for BootRecovery (issue #186): the bootstrap's recovery memory —
## boot-attempt marker, health checkpoint, persisted quarantine ledger.
##
## The ADR is explicit about why this exists: "a pack that crashes at startup
## cannot recover itself; without this in place a single bad overlay would strand
## every client that received it." Each law is pinned with an ISOLATED control so
## a red build names the law it broke:
##  1. CRASH LOOP — a launch that never reaches the checkpoint quarantines exactly
##     the attempted version at the next launch's reconcile, and that version is
##     never selected or re-mounted again.
##  2. PROMOTED LAUNCH — a boot that reaches the checkpoint quarantines nothing.
##  3. FAIL CLOSED — unreadable state, versions, markers and ledgers refuse; a
##     torn ledger refuses every candidate rather than re-admitting one.
##  4. TORN-STATE POLICY — an unreadable marker clears loudly recording nothing;
##     an unreadable ledger holding back a REAL failure is replaced, recording the
##     current failure and loudly discarding the unreadable history.
##  5. PERSISTENCE — round-trips through a throwaway probe file; a missing file is
##     first boot; a corrupt file loads fail-closed; junk state is never written.
##
## File I/O touches ONLY throwaway probe files under user:// (never the player's
## save, which this suite does not open at all).
##
## Run: godot --headless --path client res://tests/boot_recovery_test.tscn

const PROBE := "user://boot_recovery_probe.json"

var _failed := false


func _ready() -> void:
	_cleanup_probe()

	# --- LIFECYCLE: attempt → promote → reconcile is clean ---
	var fresh := BootRecovery.fresh_state()
	var begun := BootRecovery.begin_attempt(fresh, "0.2.0")
	_check(begun["ok"] as bool, true, "lifecycle: a fresh attempt is accepted")
	_check((begun["state"] as Dictionary)["marker"] == "0.2.0", true, "lifecycle: the marker records the attempted version")
	_check(fresh["marker"] == null, true, "lifecycle: the input state is not mutated (pure core)")
	var promoted := BootRecovery.promote(begun["state"], "0.2.0")
	_check(promoted["ok"] as bool, true, "lifecycle: reaching the checkpoint promotes")
	_check((promoted["state"] as Dictionary)["marker"] == null, true, "lifecycle: promotion clears the marker")
	_check((promoted["state"] as Dictionary)["last_good"] == "0.2.0", true, "lifecycle: promotion records last-good")
	var settled := BootRecovery.reconcile(promoted["state"])
	_check(settled["ok"] as bool, true, "control 2 (PROMOTED LAUNCH): reconcile after a promoted boot succeeds")
	_check(str(settled["quarantined_version"]) == "", true, "control 2 (PROMOTED LAUNCH): a promoted boot quarantines nothing")
	_check(((settled["state"] as Dictionary)["quarantined"] as Array).is_empty(), true, "control 2 (PROMOTED LAUNCH): the ledger stays empty")
	if _failed:
		return

	# --- CONTROL 1: CRASH LOOP — the unreached marker quarantines the build ---
	# The previous launch mounted 0.2.0 and never promoted; this launch reconciles.
	var crashed: Dictionary = begun["state"]
	var recon := BootRecovery.reconcile(crashed)
	_check(recon["ok"] as bool, true, "crash loop: reconcile settles the unreached marker")
	_check(str(recon["quarantined_version"]) == "0.2.0", true, "crash loop: exactly the attempted version is recorded as failed")
	var after: Dictionary = recon["state"]
	_check(after["marker"] == null, true, "crash loop: the marker is cleared once recorded")
	_check(RollbackSelection.is_quarantined(after["quarantined"], "0.2.0"), true, "crash loop: the failed version is quarantined")
	# Reconciling again is a no-op — the failure is recorded once, not re-counted.
	var again := BootRecovery.reconcile(after)
	_check(again["ok"] as bool, true, "crash loop: a second reconcile is a clean no-op")
	_check(str(again["quarantined_version"]) == "", true, "crash loop: a second reconcile records nothing new")
	# Defense in depth: the quarantined build is refused at the mount gate too.
	var remount := BootRecovery.begin_attempt(after, "0.2.0")
	_check(remount["ok"] as bool, false, "crash loop: the quarantined build is refused at begin_attempt")
	_check(BootRecovery.begin_attempt(after, "0.2.0.0")["ok"] as bool, false, "crash loop: an alias spelling of the quarantined build is refused too")
	# Cross-lib (AC4): RollbackSelection.select never picks the quarantined build.
	var catalog: Array = [_target("0.2.0"), _target("0.1.0")]
	var pick := RollbackSelection.select(catalog, _select_state(after["quarantined"]))
	_check(pick["action"] == RollbackSelection.ROLLBACK, true, "crash loop: an eligible fallback is still found")
	_check(str(pick["version"]) == "0.1.0", true, "crash loop: select falls back PAST the quarantined build, never onto it")
	if _failed:
		return

	# --- CONTROL 3: FAIL CLOSED — junk refuses, state stays as given ---
	_check(BootRecovery.begin_attempt(null, "0.2.0")["ok"] as bool, false, "fail closed: begin_attempt refuses a missing state")
	_check(BootRecovery.begin_attempt(BootRecovery.fresh_state(), "not-a-version")["ok"] as bool, false, "fail closed: begin_attempt refuses an unreadable version")
	var pending_state: Dictionary = begun["state"]
	var double := BootRecovery.begin_attempt(pending_state, "0.3.0")
	_check(double["ok"] as bool, false, "fail closed: a second attempt while one is pending is refused")
	_check((double["state"] as Dictionary)["marker"] == "0.2.0", true, "fail closed: the refusal hands back the state it was given")
	var torn_ledger := {"marker": null, "quarantined": "junk", "last_good": null}
	_check(BootRecovery.begin_attempt(torn_ledger, "0.3.0")["ok"] as bool, false, "fail closed: a torn ledger refuses EVERY candidate (nothing can be shown safe)")
	_check(BootRecovery.promote(BootRecovery.fresh_state(), "0.2.0")["ok"] as bool, false, "fail closed: promote with no pending attempt is refused")
	_check(BootRecovery.promote(pending_state, "0.9.9")["ok"] as bool, false, "fail closed: promoting a DIFFERENT build than attempted is refused")
	_check(BootRecovery.promote(pending_state, "0.2.0.0")["ok"] as bool, true, "fail closed: an alias spelling of the SAME build promotes (numeric matching, as the ledger)")
	_check(BootRecovery.reconcile("junk")["ok"] as bool, false, "fail closed: reconcile refuses a non-dictionary state")
	if _failed:
		return

	# --- CONTROL 4a: TORN MARKER — cleared loudly, nothing recorded ---
	var torn_marker := {"marker": 42, "quarantined": ["0.1.5"], "last_good": null}
	var tm := BootRecovery.reconcile(torn_marker)
	_check(tm["ok"] as bool, true, "torn marker: reconcile proceeds rather than wedging every launch")
	_check((tm["state"] as Dictionary)["marker"] == null, true, "torn marker: the unreadable marker is cleared")
	_check(str(tm["quarantined_version"]) == "", true, "torn marker: nothing is recorded — the failed build cannot be identified")
	_check((tm["state"] as Dictionary)["quarantined"] == Array(["0.1.5"]), true, "torn marker: the readable ledger is preserved untouched")
	_check(str(tm["reason"]).is_empty(), false, "torn marker: the loss is stated loudly, never silent")

	# --- CONTROL 4b: TORN LEDGER + REAL FAILURE — recover, recording the failure ---
	var torn_both := {"marker": "0.4.0", "quarantined": ["garbage", 7], "last_good": null}
	var tb := BootRecovery.reconcile(torn_both)
	_check(tb["ok"] as bool, true, "torn ledger: a REAL pending failure forces the explicit recovery")
	_check(str(tb["quarantined_version"]) == "0.4.0", true, "torn ledger: the current failure is recorded")
	_check((tb["state"] as Dictionary)["quarantined"] == Array(["0.4.0"]), true, "torn ledger: the fresh ledger holds exactly the current failure")
	_check("DISCARDED" in str(tb["reason"]), true, "torn ledger: the discarded history is stated loudly")

	# --- CONTROL 4c: TORN LEDGER, NO FAILURE — preserved, never laundered ---
	var tq := BootRecovery.reconcile(torn_ledger)
	_check(tq["ok"] as bool, true, "torn ledger, idle: reconcile with nothing pending is a no-op")
	_check((tq["state"] as Dictionary)["quarantined"] == "junk", true, "torn ledger, idle: the unreadable ledger is preserved as evidence, not repaired")
	_check(BootRecovery.save_state(PROBE, tq["state"])["ok"] as bool, false, "torn ledger, idle: save_state refuses to launder it into a well-formed file")
	if _failed:
		return

	# --- CONTROL 5: PERSISTENCE — round-trip, first boot, corrupt file ---
	var missing := BootRecovery.load_state(PROBE)
	_check(missing["ok"] as bool, true, "persistence: a missing file is the legitimate first boot")
	_check((missing["state"] as Dictionary).get("version", -1) == 1, true, "persistence: first boot starts on recovery schema v1")
	_check((missing["state"] as Dictionary)["quarantined"] == Array([]), true, "persistence: first boot starts with an empty ledger")
	var saved := BootRecovery.save_state(PROBE, after)
	_check(saved["ok"] as bool, true, "persistence: a readable state persists")
	_check(FileAccess.file_exists(PROBE + ".tmp"), false, "persistence: no temp file is left behind (atomic write)")
	var loaded := BootRecovery.load_state(PROBE)
	_check(loaded["ok"] as bool, true, "persistence: the persisted state loads back")
	var lstate: Dictionary = loaded["state"]
	_check(lstate.get("version", -1) == 1, true, "persistence: the recovery schema version round-trips")
	_check(lstate["marker"] == null, true, "persistence: marker round-trips")
	_check(lstate["last_good"] == after["last_good"], true, "persistence: last-good round-trips")
	_check(RollbackSelection.is_quarantined(lstate["quarantined"], "0.2.0"), true, "persistence: the quarantine survives the round-trip — the boot loop stays broken across launches")
	_check(RollbackSelection.is_readable_ledger(lstate["quarantined"]), true, "persistence: the loaded ledger is readable by the selection side")
	# A corrupt file must load read-only and preserve its evidence, but it must
	# not turn the recovery mechanism into the reason no fallback can boot.
	var raw := FileAccess.open(PROBE, FileAccess.WRITE)
	raw.store_string("{ not json")
	raw.close()
	var corrupt := BootRecovery.load_state(PROBE)
	_check(corrupt["ok"] as bool, false, "persistence: a corrupt file loads with ok=false, loudly")
	_check(RollbackSelection.is_quarantined((corrupt["state"] as Dictionary)["quarantined"], "0.5.0"), false, "persistence: unreadable recovery memory does not declare every retained fallback quarantined")
	var corrupt_pick := RollbackSelection.select([_target("0.5.0")], _select_state((corrupt["state"] as Dictionary)["quarantined"]))
	_check(corrupt_pick["action"] == RollbackSelection.ROLLBACK, true, "persistence: a corrupt recovery file cannot block an otherwise-safe rollback")
	_check(BootRecovery.begin_attempt(corrupt["state"], "0.5.0")["ok"] as bool, false, "persistence: read-only degraded state refuses NEW update attempts")
	_check(BootRecovery.save_state(PROBE, corrupt["state"])["ok"] as bool, false, "persistence: the corrupt evidence is never overwritten with a well-formed lie")
	_check(BootRecovery.save_state(PROBE, {"marker": 42, "quarantined": [], "last_good": null})["ok"] as bool, false, "persistence: a junk marker is refused at write time")
	# A PARSEABLE file missing keys is torn, not "empty": save_state never writes
	# less than all three, so defaulting an absent ledger to [] (or an absent
	# marker to "nothing pending") would erase recorded evidence (Codex P2, #191).
	raw = FileAccess.open(PROBE, FileAccess.WRITE)
	raw.store_string("{}")
	raw.close()
	var keyless := BootRecovery.load_state(PROBE)
	_check(keyless["ok"] as bool, false, "persistence: a parseable file missing its keys loads as corrupt, never as an empty history")
	_check(BootRecovery.begin_attempt(keyless["state"], "0.5.0")["ok"] as bool, false, "persistence: candidates stay refused after a keyless load")
	raw = FileAccess.open(PROBE, FileAccess.WRITE)
	raw.store_string(JSON.stringify({"marker": null, "last_good": null}))
	raw.close()
	_check(BootRecovery.load_state(PROBE)["ok"] as bool, false, "persistence: a file missing only the ledger key is corrupt — absent history is not empty history")
	if _failed:
		return

	_cleanup_probe()
	print("TEST PASS — boot recovery holds (crash loop broken, promoted boot clean, fail closed, torn-state policies, persistence)")
	get_tree().quit(0)


## A minimal eligible rollback-catalogue entry for `version`, matching the state
## `_select_state` describes (save schema 1 / capability 1, protocol 1..1, shell
## inside the window).
func _target(version: String) -> Dictionary:
	return {
		"version": version,
		"url": "https://updates.example/%s.pck" % version,
		"sha256": "a".repeat(64),
		"size": 0,
		"read_ceiling": 1,
		"save_capability": 1,
		"speaks_protocol": {"min": 1, "max": 1},
		"shell_compat": {"min": "0.1.0", "max": "0.1.999"},
	}


func _select_state(quarantined: Variant) -> Dictionary:
	return {
		"save": {"schema": 1, "capability": 1},
		"protocol": {"min": 1, "max": 1},
		"shell_version": "0.1.14",
		"quarantined": quarantined,
	}


func _cleanup_probe() -> void:
	for leftover in [PROBE, PROBE + ".tmp"]:
		if FileAccess.file_exists(leftover):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(leftover))


func _check(actual: bool, expected: bool, label: String) -> void:
	if _failed:
		return
	if actual != expected:
		_fail("%s — expected %s, got %s" % [label, expected, actual])


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
