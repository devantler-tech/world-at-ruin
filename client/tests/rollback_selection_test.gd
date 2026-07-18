extends Node
## Regression test for RollbackSelection (issue #95).
##
## This is the recovery half of self-update, and the ADR is explicit about why it
## must exist before the first overlay ships: "a pack that crashes at startup
## cannot recover itself; without this in place a single bad overlay would strand
## every client that received it."
##
## Every rule pinned here is a product law (no hard resets, forward-only, no
## stranding), and each is proven with an ISOLATED control so a red build names
## the law it broke:
##  1. QUARANTINE — a build that failed its boot health check is never selected
##     again, which is what breaks the boot loop.
##  2. REACHABLE — never roll back below the installed save: the target's
##     read_ceiling must cover the save schema AND its save_capability must cover
##     the save's (a same-schema expansion raises only capability).
##  3. RUNNABLE — never roll back to a build that cannot connect or cannot run:
##     its speaks_protocol must overlap the live range and the installed shell
##     must be inside its shell_compat window.
##  4. LOUD REFUSAL — when nothing qualifies the answer is no_eligible_target with
##     a reason, never a crash and never "just take the newest".
##
## Pure logic only — no scene, no save, no boot — so it is safe to run locally and
## deterministic in CI.
##
## Run: godot --headless --path client res://tests/rollback_selection_test.tscn

var _failed := false


func _ready() -> void:
	# --- newest ELIGIBLE target wins (and 0.1.9 < 0.1.10, not lexically) ---
	var catalog: Array = [
		_target("0.1.9", 1, 7, 1, 1, "0.1.0", "0.1.999"),
		_target("0.1.10", 1, 7, 1, 1, "0.1.0", "0.1.999"),
		_target("0.1.2", 1, 7, 1, 1, "0.1.0", "0.1.999"),
	]
	var picked := RollbackSelection.select(catalog, _state())
	_check(picked["action"] == RollbackSelection.ROLLBACK, true, "select: an eligible target is chosen")
	_check(picked["version"] == "0.1.10", true, "select: the NEWEST eligible target wins (0.1.9 < 0.1.10 numerically)")
	if _failed:
		return

	# --- CONTROL 1: QUARANTINE — the broken build is never re-selected ---
	# Identical catalog, but the newest failed its boot health check: recovery must
	# fall to the next-newest rather than loop on the broken pack.
	var state_q := _state()
	state_q["quarantined"] = ["0.1.10"]
	var after_q := RollbackSelection.select(catalog, state_q)
	_check(after_q["action"] == RollbackSelection.ROLLBACK, true, "control 1: recovery still succeeds")
	_check(after_q["version"] == "0.1.9", true, "control 1: the quarantined build is skipped for the next-newest")
	if _failed:
		return

	# --- CONTROL 2a: REACHABLE — never roll back below the save SCHEMA ---
	# The only target reads schema 1, but the player's save is schema 2.
	var too_old: Array = [_target("0.1.10", 1, 7, 1, 1, "0.1.0", "0.1.999")]
	var state_s2 := _state()
	state_s2["save"] = {"schema": 2, "capability": 7}
	var refused_schema := RollbackSelection.select(too_old, state_s2)
	_check(refused_schema["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, true, "control 2a: a target below the save read-ceiling is refused, not selected")
	_check(refused_schema["version"] == "", true, "control 2a: no version is named")
	_check(refused_schema["reason"].contains("runnable and reachable"), true, "control 2a: the refusal explains itself")
	if _failed:
		return

	# --- CONTROL 2b: REACHABLE — never roll back below the save CAPABILITY ---
	# Same schema, but a same-schema content expansion raised the save's capability
	# past what this build understands. Checking schema alone would strand it.
	var state_cap := _state()
	state_cap["save"] = {"schema": 1, "capability": 9}
	_check(RollbackSelection.select(too_old, state_cap)["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, true, "control 2b: a target below the save capability is refused (schema alone is not enough)")
	# and it IS selected once the capability fits — proving 2b is the only blocker
	_check(RollbackSelection.select(too_old, _state())["action"] == RollbackSelection.ROLLBACK, true, "control 2b is ISOLATED: the same target is eligible when the capability fits")
	if _failed:
		return

	# --- CONTROL 3a: RUNNABLE — a protocol-disjoint target cannot connect ---
	# It speaks 1..1; the live tier now accepts only 5..6. No overlap.
	var old_protocol: Array = [_target("0.1.10", 1, 7, 1, 1, "0.1.0", "0.1.999")]
	var state_p := _state()
	state_p["protocol"] = {"min": 5, "max": 6}
	_check(RollbackSelection.select(old_protocol, state_p)["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, true, "control 3a: a protocol-disjoint target is refused")
	# a target whose range OVERLAPS the live range is fine (2..7 vs 5..6)
	var overlapping: Array = [_target("0.1.10", 1, 7, 2, 7, "0.1.0", "0.1.999")]
	_check(RollbackSelection.select(overlapping, state_p)["action"] == RollbackSelection.ROLLBACK, true, "control 3a is ISOLATED: an overlapping protocol range is accepted")
	if _failed:
		return

	# --- CONTROL 3b: RUNNABLE — the installed shell must be inside shell_compat ---
	var needs_new_shell: Array = [_target("0.1.10", 1, 7, 1, 1, "0.2.0", "0.2.999")]
	_check(RollbackSelection.select(needs_new_shell, _state())["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, true, "control 3b: a target needing a newer shell is refused")
	var too_new_shell: Array = [_target("0.1.10", 1, 7, 1, 1, "0.0.1", "0.0.9")]
	_check(RollbackSelection.select(too_new_shell, _state())["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, true, "control 3b: a target whose shell window has been outgrown is refused")
	if _failed:
		return

	# --- an empty catalogue refuses loudly rather than crashing ---
	var empty := RollbackSelection.select([], _state())
	_check(empty["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, true, "empty: an empty catalogue refuses loudly")
	_check(empty["reason"].contains("no well-formed target"), true, "empty: the reason names the empty catalogue")
	if _failed:
		return

	# --- a malformed entry is SKIPPED, never fatal: recovery still succeeds ---
	# One bad entry must not deny the player a recovery another entry can provide.
	var mixed: Array = [
		"not-a-dictionary",
		{"version": "0.1.99"}, # missing every capability field — unprovable, so skipped
		_target("0.1.10", 1, 7, 1, 1, "0.1.0", "0.1.999"),
	]
	var survived := RollbackSelection.select(mixed, _state())
	_check(survived["action"] == RollbackSelection.ROLLBACK, true, "malformed: a bad entry never denies a good recovery")
	_check(survived["version"] == "0.1.10", true, "malformed: the well-formed target is the one chosen")
	# the incomplete entry is never trusted even though its version is the newest
	_check(survived["version"] != "0.1.99", true, "malformed: an entry missing capability data is never trusted")
	if _failed:
		return

	# --- an all-malformed catalogue refuses, naming that it found nothing usable ---
	var junk_only := RollbackSelection.select(["x", 42, {}], _state())
	_check(junk_only["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, true, "malformed: an all-junk catalogue refuses loudly")
	_check(junk_only["reason"].contains("no well-formed target"), true, "malformed: the reason distinguishes 'nothing usable' from 'nothing eligible'")
	if _failed:
		return

	# --- a missing/malformed live protocol range is refused, never assumed open ---
	var no_proto := _state()
	no_proto.erase("protocol")
	_check(RollbackSelection.select(catalog, no_proto)["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, true, "protocol: an absent live range is refused, never treated as 'anything goes'")
	if _failed:
		return

	# --- quarantine is forward-only and never mutates its input ---
	var q0: Array = []
	var q1 := RollbackSelection.quarantine(q0, "0.1.10")
	_check(q0.is_empty(), true, "quarantine: the input set is not mutated")
	_check(RollbackSelection.is_quarantined(q1, "0.1.10"), true, "quarantine: the broken build is recorded")
	var q2 := RollbackSelection.quarantine(q1, "0.1.9")
	_check(q2.size() == 2, true, "quarantine: a second failure is added")
	_check(RollbackSelection.is_quarantined(q2, "0.1.10"), true, "quarantine: FORWARD-ONLY — an earlier entry is never dropped")
	var q3 := RollbackSelection.quarantine(q2, "0.1.10")
	_check(q3.size() == 2, true, "quarantine: re-quarantining is idempotent")
	_check(RollbackSelection.quarantine(q2, "").size() == 2, true, "quarantine: an empty version is ignored")
	_check(RollbackSelection.is_quarantined(q2, "9.9.9"), false, "quarantine: an unknown version is not quarantined")
	if _failed:
		return

	# --- total function: junk input never crashes it ---
	_check(RollbackSelection.select([], {})["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, true, "total: an empty state refuses cleanly")
	_check(RollbackSelection.select(catalog, {"save": "nonsense", "protocol": {"min": 1, "max": 1}, "shell_version": "0.1.14"})["action"] == RollbackSelection.ROLLBACK, true, "total: a nonsense save block falls back to the most conservative save (schema 0), never a crash")
	# An ABSENT shell version is the conservative "0.0.0", which fails every real
	# shell_compat window — an unverifiable shell is never assumed compatible.
	_check(RollbackSelection.select(catalog, {"save": {"schema": 1, "capability": 7}, "protocol": {"min": 1, "max": 1}})["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, true, "total: an absent shell version is never assumed compatible")
	_check(RollbackSelection.quarantine([42, "0.1.1", 42], "0.1.1").size() == 1, true, "total: junk in the quarantine set is dropped and duplicates collapse")
	if _failed:
		return

	print("TEST PASS — rollback selection holds (newest eligible; quarantine breaks the boot loop; never below the save; never unrunnable; loud refusal)")
	get_tree().quit(0)


## A well-formed catalogue entry, as published in the signed manifest's
## `rollback_targets`.
func _target(version: String, read_ceiling: int, save_capability: int, speaks_min: int, speaks_max: int, shell_min: String, shell_max: String) -> Dictionary:
	return {
		"version": version,
		"url": "https://updates.example/%s.pck" % version,
		"sha256": "0000000000000000000000000000000000000000000000000000000000000000",
		"size": 0,
		"read_ceiling": read_ceiling,
		"save_capability": save_capability,
		"speaks_protocol": {"min": speaks_min, "max": speaks_max},
		"shell_compat": {"min": shell_min, "max": shell_max},
	}


## The baseline client/world state: save schema 1 capability 7, live tier accepts
## protocol 1..1, shell 0.1.14 installed, nothing quarantined.
func _state() -> Dictionary:
	return {
		"save": {"schema": 1, "capability": 7},
		"protocol": {"min": 1, "max": 1},
		"shell_version": "0.1.14",
		"quarantined": [],
	}


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
