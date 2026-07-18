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
	# The VERIFIED entry comes back, not just its version: a catalogue can hold
	# same-version duplicates with different artifact metadata, and re-resolving by
	# version could hand the bootstrap a different one than the one checked here.
	_check((picked["target"] as Dictionary)["version"] == "0.1.10", true, "select: the verified target itself is returned")
	_check((picked["target"] as Dictionary)["url"] == "https://updates.example/0.1.10.pck", true, "select: the returned target carries the verified artifact")
	(picked["target"] as Dictionary)["url"] = "https://tampered/x.pck"
	_check((RollbackSelection.select(catalog, _state())["target"] as Dictionary)["url"] == "https://updates.example/0.1.10.pck", true, "select: the returned target is a copy, not the catalogue entry")
	# A duplicate version carrying DIFFERENT metadata: whichever is chosen, the
	# returned tuple must be the one that was actually validated.
	var dupes: Array = [_target("0.1.10", 1, 7, 1, 1, "0.1.0", "0.1.999"), _target("0.1.10", 1, 7, 1, 1, "0.1.0", "0.1.999")]
	(dupes[1] as Dictionary)["url"] = "https://other.example/dupe.pck"
	var dup_pick := RollbackSelection.select(dupes, _state())
	_check(dup_pick["action"] == RollbackSelection.ROLLBACK, true, "select: a duplicated version still resolves")
	_check((dup_pick["target"] as Dictionary)["url"] in ["https://updates.example/0.1.10.pck", "https://other.example/dupe.pck"], true, "select: the returned artifact is one of the catalogue entries, named explicitly")
	_check(RollbackSelection.select([], _state()).has("target"), true, "select: a refusal carries the same shape (empty target)")
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
	var r1 := RollbackSelection.quarantine(q0, "0.1.10")
	_check(r1["ok"], true, "quarantine: a well-formed failure is recorded")
	var q1: Array = r1["ledger"]
	_check(q0.is_empty(), true, "quarantine: the input set is not mutated")
	_check(RollbackSelection.is_quarantined(q1, "0.1.10"), true, "quarantine: the broken build is recorded")
	var q2: Array = RollbackSelection.quarantine(q1, "0.1.9")["ledger"]
	_check(q2.size() == 2, true, "quarantine: a second failure is added")
	_check(RollbackSelection.is_quarantined(q2, "0.1.10"), true, "quarantine: FORWARD-ONLY — an earlier entry is never dropped")
	_check(RollbackSelection.quarantine(q2, "0.1.10")["ledger"].size() == 2, true, "quarantine: re-quarantining is idempotent")
	_check(RollbackSelection.is_quarantined(q2, "9.9.9"), false, "quarantine: an unknown version is not quarantined")
	if _failed:
		return

	# --- quarantine REFUSES rather than silently erasing failure evidence ---
	# The write side must not disagree with the read side: select() refuses on an
	# unreadable ledger, so quarantine() must not hand back a "cleaned" one. A caller
	# persisting that would erase the only record a build failed, and the next
	# select() would choose the known-broken build again.
	var bad_in := RollbackSelection.quarantine([42, "0.1.1"], "0.1.2")
	_check(bad_in["ok"], false, "quarantine: an unreadable EXISTING entry refuses, never silently dropped")
	_check((bad_in["ledger"] as Array).size() == 2, true, "quarantine: the refused ledger is returned unchanged, losing nothing")
	var bad_ver := RollbackSelection.quarantine(["0.1.1"], "")
	_check(bad_ver["ok"], false, "quarantine: an unreadable FAILED version refuses, never a silent no-op")
	_check(RollbackSelection.quarantine(["0.1.1"], "not-a-version")["ok"], false, "quarantine: a malformed boot-attempt marker refuses")
	# The marker is read from disk and can come back as a NON-STRING after a bad
	# write. A typed String parameter would make the caller error before reaching the
	# refusal — turning the fail-closed result the bootstrap needs into a crash, in
	# exactly the situation it is needed. It must refuse, not throw.
	for junk_marker: Variant in [null, 42, 1.5, [], {}, true]:
		var r := RollbackSelection.quarantine(["0.1.1"], junk_marker)
		_check(r["ok"], false, "quarantine: a non-string boot marker refuses cleanly rather than erroring")
		_check((r["ledger"] as Array).size() == 1, true, "quarantine: the existing record survives a junk marker")
	# The LEDGER itself has the same problem: read back from disk it can be null or
	# an object. A typed Array parameter would reject the call before the fail-closed
	# body could run — the same trap as the marker, one parameter over.
	for junk_ledger: Variant in [null, 42, "corrupt", {}, true]:
		var r := RollbackSelection.quarantine(junk_ledger, "0.1.2")
		_check(r["ok"], false, "quarantine: a non-Array ledger refuses cleanly rather than erroring")
	_check((bad_ver["ledger"] as Array).size() == 1, true, "quarantine: the existing record survives the refusal")
	if _failed:
		return

	# --- UNVERIFIABLE STATE FAILS CLOSED (Codex review, PR #98) ---
	# Every input below is a PROOF of eligibility. The tempting "conservative
	# default" for each is in fact maximally PERMISSIVE — an unknown save reads as
	# schema 0 so every target looks reachable; an unknown shell reads as "0.0.0" so
	# any window matches; an absent protocol range makes any target look connectable.
	# Each must therefore refuse, naming what could not be verified.
	var unverifiable: Array = [
		[{"protocol": {"min": 1, "max": 1}, "shell_version": "0.1.14"}, "an absent save block"],
		[{"save": "nonsense", "protocol": {"min": 1, "max": 1}, "shell_version": "0.1.14"}, "a non-Dictionary save block"],
		[{"save": {"capability": 7}, "protocol": {"min": 1, "max": 1}, "shell_version": "0.1.14"}, "a save with no schema"],
		[{"save": {"schema": 1}, "protocol": {"min": 1, "max": 1}, "shell_version": "0.1.14"}, "a save with no capability"],
		[{"save": {"schema": 1.5, "capability": 7}, "protocol": {"min": 1, "max": 1}, "shell_version": "0.1.14"}, "a fractional save schema"],
		[{"save": {"schema": 1, "capability": 7}, "protocol": {"min": 1, "max": 1}}, "an absent shell version"],
		[{"save": {"schema": 1, "capability": 7}, "protocol": {"min": 1, "max": 1}, "shell_version": "garbage"}, "a non-version shell version"],
		[{"save": {"schema": 1, "capability": 7}, "shell_version": "0.1.14"}, "an absent live protocol range"],
		[{"save": {"schema": 1, "capability": 7}, "protocol": {"min": 5, "max": 1}, "shell_version": "0.1.14"}, "an INVERTED live protocol range"],
		[{"save": {"schema": 1, "capability": 7}, "protocol": {"min": 1, "max": 1}, "shell_version": "0.1.14", "quarantined": "corrupt"}, "a malformed quarantine ledger"],
	]
	for case: Array in unverifiable:
		var st: Dictionary = case[0]
		var what: String = case[1]
		_check(RollbackSelection.select(catalog, st)["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, true, "fail-closed: %s is refused, never assumed" % what)
	if _failed:
		return

	# The inverted-range guard must be LOAD-BEARING, so this case needs a target
	# whose range is broad enough to spuriously "overlap" an inverted one: 0..9
	# against a malformed 5..1 satisfies the interval test in both directions and
	# would be selected on unverifiable connectivity data. (A narrow 1..1 target
	# fails the overlap test anyway, which would make this control vacuous.)
	var broad: Array = [_target("0.1.10", 1, 7, 0, 9, "0.1.0", "0.1.999")]
	var inverted := _state()
	inverted["protocol"] = {"min": 5, "max": 1}
	_check(RollbackSelection.select(broad, inverted)["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, true, "fail-closed: an inverted live range is refused even when a broad target range would 'overlap' it")
	_check(RollbackSelection.select(broad, _state())["action"] == RollbackSelection.ROLLBACK, true, "fail-closed is ISOLATED: that same broad target is eligible under a coherent range")
	if _failed:
		return

	# A malformed quarantine ledger must refuse even when a target would otherwise
	# qualify — reading it as "nothing quarantined" would reopen the boot loop.
	var corrupt_q := _state()
	corrupt_q["quarantined"] = {"0.1.10": true}
	_check(RollbackSelection.select(catalog, corrupt_q)["reason"].contains("quarantine"), true, "fail-closed: the refusal names the unreadable quarantine ledger")
	# ...while an ABSENT ledger is the legitimate first-boot state and still selects.
	var first_boot := _state()
	first_boot.erase("quarantined")
	_check(RollbackSelection.select(catalog, first_boot)["action"] == RollbackSelection.ROLLBACK, true, "fail-closed is ISOLATED: an absent ledger is first-boot, not corruption")
	if _failed:
		return

	# --- a real signed manifest may carry whole numbers as JSON floats ---
	# Rejecting 1.0 would degrade recovery to no_eligible_target while a perfectly
	# good target sits in the catalogue — a broken pack with no way back.
	var json_floats := _target("0.1.10", 1, 7, 1, 1, "0.1.0", "0.1.999")
	json_floats["read_ceiling"] = 1.0
	json_floats["save_capability"] = 7.0
	json_floats["speaks_protocol"] = {"min": 1.0, "max": 1.0}
	json_floats["size"] = 4096.0
	_check(RollbackSelection.select([json_floats], _state())["action"] == RollbackSelection.ROLLBACK, true, "json: integral floats (1.0) are accepted — a real manifest shape must stay recoverable")
	var fractional := _target("0.1.10", 1, 7, 1, 1, "0.1.0", "0.1.999")
	fractional["read_ceiling"] = 1.5
	_check(RollbackSelection.select([fractional], _state())["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, true, "json: a FRACTIONAL eligibility number is not a proof and is skipped")
	if _failed:
		return

	# --- unverifiable per-target metadata is skipped, never selected ---
	# Each of these would otherwise WIN the ordering (the version sorts highest) and
	# be handed to the bootstrap as a recovery target.
	var bad_meta: Array = [
		[_bad_version_target(), "a non-version target version (\"99.bad\")"],
		[_bad_compat_target(), "a non-version shell_compat bound (\"garbage\")"],
		[_inverted_compat_target(), "an inverted shell_compat window"],
		[_signed_compat_target(), "a SIGNED shell_compat floor (\"-1.0.0\") that every shell would clear"],
		[_signed_version_target(), "a SIGNED target version (\"-1.0.0\")"],
	]
	for case: Array in bad_meta:
		var entry: Dictionary = case[0]
		var what: String = case[1]
		var probe: Array = [entry, _target("0.1.2", 1, 7, 1, 1, "0.1.0", "0.1.999")]
		var got := RollbackSelection.select(probe, _state())
		_check(got["version"] == "0.1.2", true, "metadata: %s is skipped for the verifiable target" % what)
	if _failed:
		return

	# --- ROUND 2 (Codex, PR #98): the proofs I only half-verified ---

	# (1) A well-typed Array with MALFORMED ENTRIES is as dangerous as a malformed
	# container: every lookup misses, so the build that just failed is selected again.
	for bad_ledger: Variant in [[42], [{}], ["not-a-version"], [null]]:
		var st := _state()
		st["quarantined"] = bad_ledger
		_check(RollbackSelection.select(catalog, st)["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, true, "ledger: an unreadable ENTRY refuses, never reads as 'nothing quarantined'")
	if _failed:
		return

	# (2) Negative identifiers are malformed, not merely unusual: schema -1 makes
	# every target look able to read the save.
	var neg_save := _state()
	neg_save["save"] = {"schema": -1, "capability": 7}
	_check(RollbackSelection.select(catalog, neg_save)["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, true, "negative: a negative save schema is refused, not treated as verified")
	var neg_proto := _state()
	neg_proto["protocol"] = {"min": -5, "max": 9}
	_check(RollbackSelection.select(catalog, neg_proto)["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, true, "negative: a negative protocol bound is refused, not used to widen the range")
	var neg_target: Array = [_target("0.9.9", -1, 7, 1, 1, "0.1.0", "0.1.999"), _target("0.1.2", 1, 7, 1, 1, "0.1.0", "0.1.999")]
	_check(RollbackSelection.select(neg_target, _state())["version"] == "0.1.2", true, "negative: a target with a negative read_ceiling is skipped despite the higher version")
	if _failed:
		return

	# (3) Version ALIASING: the ledger and the catalogue may spell one build
	# differently. compare_versions calls these equal, so an exact-string check would
	# re-select the failed build under an alias.
	for alias: String in ["0.1.010", "0.1.10.0"]:
		var aliased: Array = [_target(alias, 1, 7, 1, 1, "0.1.0", "0.1.999")]
		var st_alias := _state()
		st_alias["quarantined"] = ["0.1.10"]
		_check(RollbackSelection.select(aliased, st_alias)["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, true, "alias: '%s' is still the quarantined 0.1.10 and is never re-selected" % alias)
	_check(RollbackSelection.is_quarantined(["0.1.10"], "0.1.010"), true, "alias: is_quarantined matches numerically, not by string")
	_check((RollbackSelection.quarantine(["0.1.10"], "0.1.010")["ledger"] as Array).size() == 1, true, "alias: quarantine does not accumulate aliases of one build")
	if _failed:
		return

	# (4) Eligibility is not enough — the bootstrap must be able to MOUNT it. Each of
	# these carries the highest version, so it would win the ordering if not skipped.
	# The signed cases are Godot API traps, verified empirically: a leading sign is
	# accepted by is_valid_hex_number() and is_valid_int(), so "-" plus 63 hex
	# characters is a 64-long "valid" digest, and "-1.0.0" is a "valid" version whose
	# floor every shell clears.
	var undeployable: Array = [
		["url", ""], ["url", 42],
		["url", "   "], ["url", "not-a-url"], ["url", "ftp://x/y.pck"],
		["url", "https://"], ["url", " https://x/y.pck"], ["url", "https://x/y .pck"],
		["url", "https:///bad.pck"], ["url", "https://?bad.pck"], ["url", "https://#bad.pck"],
		["url", "https://:443/bad.pck"], ["url", "https://@/bad.pck"], ["url", "https://user@:443/bad.pck"],
		["sha256", "abc"], ["sha256", "z".repeat(64)], ["sha256", 42],
		["sha256", "-" + "a".repeat(63)], ["sha256", "+" + "a".repeat(63)],
		["size", -1], ["size", "big"],
	]
	for case: Array in undeployable:
		var field: String = case[0]
		var bad_target := _target("0.9.9", 1, 7, 1, 1, "0.1.0", "0.1.999")
		bad_target[field] = case[1]
		var probe: Array = [bad_target, _target("0.1.2", 1, 7, 1, 1, "0.1.0", "0.1.999")]
		_check(RollbackSelection.select(probe, _state())["version"] == "0.1.2", true, "artifact: a bad '%s' makes the target undeployable and it is skipped" % field)
	if _failed:
		return

	# --- total function: junk input never crashes it ---
	_check(RollbackSelection.select([], {})["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, true, "total: an empty state refuses cleanly")
	# The CATALOGUE itself may be missing or not a list in a parsed manifest. A typed
	# Array parameter would reject the call before the refusal could be returned —
	# the THIRD instance of that trap in this file (after the boot marker and the
	# ledger), which is why it is now a shape to look for rather than a one-off.
	for junk_catalog: Variant in [null, 42, "targets", {}, true]:
		_check(RollbackSelection.select(junk_catalog, _state())["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, true, "total: a non-list rollback catalogue refuses cleanly rather than erroring")
	# ...and the STATE, the sibling parameter in the same signature. I fixed catalog
	# and missed this one, which is the fourth occurrence of the trap in this file.
	for junk_state: Variant in [null, 42, "state", [], true]:
		_check(RollbackSelection.select(catalog, junk_state)["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, true, "total: a non-dictionary recovery state refuses cleanly rather than erroring")
	if _failed:
		return

	# --- schema 0 is not a proof, even when explicitly supplied ---
	# Refusing an ABSENT save while accepting an explicit `{schema: 0}` would let the
	# exact value named as the dangerous default buy what a missing value cannot: with
	# schema 0 every target with a positive read_ceiling looks able to read the save.
	var zeroed := _state()
	zeroed["save"] = {"schema": 0, "capability": 0}
	_check(RollbackSelection.select(catalog, zeroed)["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, true, "zero: an explicit schema 0 is refused, not treated as verified")
	# ISOLATION: schema 1 with the same zero capability is a real save and selects.
	var lowest := _state()
	lowest["save"] = {"schema": 1, "capability": 0}
	_check(RollbackSelection.select(catalog, lowest)["action"] == RollbackSelection.ROLLBACK, true, "zero is ISOLATED: schema 1 with capability 0 is a real save and still selects")
	if _failed:
		return

	# --- the corrupt-ledger DEADLOCK has an explicit way out ---
	# select() refuses a torn ledger and quarantine() refuses to rewrite it; both are
	# right alone, but together they leave the bootstrap unable to record the current
	# failure OR pick a target. recover_ledger is the deliberate escape.
	var torn: Array = [42, "0.1.1"]
	_check(RollbackSelection.quarantine(torn, "0.1.10")["ok"], false, "deadlock: quarantine still refuses to rewrite a torn ledger")
	var stuck := _state()
	stuck["quarantined"] = torn
	_check(RollbackSelection.select(catalog, stuck)["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, true, "deadlock: select still refuses on a torn ledger")
	var recovered := RollbackSelection.recover_ledger("0.1.10")
	_check(recovered["ok"], true, "deadlock: recover_ledger provides the explicit way out")
	_check((recovered["ledger"] as Array).size() == 1, true, "deadlock: the fresh ledger holds only the current failure")
	_check(recovered["reason"].contains("DISCARDED"), true, "deadlock: the loss of history is stated loudly, never silent")
	# and the fresh ledger actually unsticks selection, still skipping the failed build
	var unstuck := _state()
	unstuck["quarantined"] = recovered["ledger"]
	var after := RollbackSelection.select(catalog, unstuck)
	_check(after["action"] == RollbackSelection.ROLLBACK, true, "deadlock: recovery lets selection proceed")
	_check(after["version"] == "0.1.9", true, "deadlock: the build that just failed is STILL skipped after recovery")
	_check(RollbackSelection.recover_ledger(42)["ok"], false, "deadlock: recovery from an unreadable marker is itself refused")
	_check(RollbackSelection.quarantine([42, "0.1.1", 42], "0.1.1")["ok"], false, "total: junk in the quarantine set refuses rather than collapsing silently")
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


## A target whose VERSION is not a version. `compare_versions` coerces "99.bad" to
## 99, so if it were not skipped it would win the ordering outright and hand the
## bootstrap a nonsense recovery name.
func _bad_version_target() -> Dictionary:
	var t := _target("0.1.2", 1, 7, 1, 1, "0.1.0", "0.1.999")
	t["version"] = "99.bad"
	return t


## A target whose shell_compat lower bound is not a version. It would compare as
## 0.0.0 — widening the very window it is supposed to prove — and its high version
## would win the ordering.
func _bad_compat_target() -> Dictionary:
	var t := _target("0.9.9", 1, 7, 1, 1, "0.1.0", "0.1.999")
	t["shell_compat"] = {"min": "garbage", "max": "0.1.999"}
	return t


## A target whose shell_compat window is inverted (min > max) — incoherent signed
## metadata, so it proves nothing and must be skipped rather than won on version.
func _inverted_compat_target() -> Dictionary:
	var t := _target("0.9.8", 1, 7, 1, 1, "0.1.0", "0.1.999")
	t["shell_compat"] = {"min": "0.2.0", "max": "0.1.0"}
	return t


## A target whose shell_compat FLOOR is signed. `is_valid_int` accepts "-1", so this
## would pass as a version and compare as a floor of -1 that every installed shell
## clears, turning an unproven target into a "runnable" one.
func _signed_compat_target() -> Dictionary:
	var t := _target("0.9.7", 1, 7, 1, 1, "0.1.0", "0.1.999")
	t["shell_compat"] = {"min": "-1.0.0", "max": "9.9.9"}
	return t


## A target with a SIGNED version component. The leading component is high so it
## WINS the ordering — a "-1.0.0" would sort below the good target and make this
## control vacuous, proving nothing about the guard.
func _signed_version_target() -> Dictionary:
	var t := _target("0.1.2", 1, 7, 1, 1, "0.1.0", "0.1.999")
	t["version"] = "9.-1.0"
	return t


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
