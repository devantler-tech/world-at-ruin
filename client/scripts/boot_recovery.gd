class_name BootRecovery
## The immutable bootstrap's recovery MEMORY: the boot-attempt marker, the health
## checkpoint, and the persisted quarantine ledger (ADR
## `docs/design/distribution-and-self-update.md` child 2; #69 obligation 1; #186).
##
## [UpdateDecision] decides what to move FORWARD to and [RollbackSelection] decides
## what to fall BACK to — both are pure and deliberately own no state. This library
## is the missing third piece: it PRODUCES and PERSISTS the state those brains
## consume, so a pack that fails its boot is never re-mounted on the next launch.
## The ADR's reason this lives outside the replaceable tree: "a pack that crashes
## at startup cannot recover itself" — the shell, not the overlay, is the root of
## recovery.
##
## The lifecycle, run by the bootstrap on every launch:
##   1. [method load_state]    — read what previous launches recorded.
##   2. [method reconcile]     — a marker left from the LAST launch means that boot
##                               never reached its health checkpoint: the marked
##                               version is quarantined and the marker cleared.
##   3. …select / play…        — [method RollbackSelection.select] consumes
##                               `state.quarantined`.
##   4. [method begin_attempt] — before MOUNTING a staged pack: durably mark it.
##   5. [method promote]       — the boot reached the success checkpoint: clear the
##                               marker and record the build as last-good.
## Every transition returns a NEW state for [method save_state] to persist — the
## core is pure (no I/O, no clock, no scene tree), exactly like the two decision
## libraries, so every no-stranding guarantee is unit-testable with plain
## dictionaries. WHERE the health checkpoint sits in boot is the caller's statement
## (the in-client updater child owns that); this library only guarantees a launch
## that never made the statement quarantines the build it attempted.
##
## State shape — the persisted file is exactly this, as JSON:
## [codeblock]
## {
##     version: int,              # recovery schema; legacy shipped files without
##                                 # this field are v0 and remain readable forever
##     marker: null | String,      # version whose boot began but has not reached
##                                 # the checkpoint yet
##     quarantined: Array[String], # the RollbackSelection ledger — every version
##                                 # that failed its boot check
##     last_good: null | String,   # the newest version that reached the checkpoint
## }
## [/codeblock]
##
## The torn-state policies [RollbackSelection] deliberately leaves to the bootstrap
## are decided HERE, explicitly, and each states its trade:
##  - An UNREADABLE MARKER at reconcile is cleared LOUDLY with nothing recorded:
##    the failed build's identity is unknowable, and refusing forever would wedge
##    every future launch — the one outcome worse than an unrecorded failure.
##  - An UNREADABLE LEDGER with a pending failure is the "decided unrecoverable"
##    case [method RollbackSelection.recover_ledger] exists for: the failure
##    happening NOW is recorded and the unreadable history is discarded, loudly.
##  - An UNREADABLE OR NEWER DOCUMENT is PRESERVED, never laundered, and becomes
##    a read-only degraded state. New update attempts and writes refuse, because
##    the quarantine history cannot be trusted. Its quarantine view is nonetheless
##    a readable empty list so this recovery file cannot itself veto a retained
##    target that independently proves save, protocol and shell compatibility.
##    This deliberately chooses recoverability over treating every fallback as
##    failed: refusing all rollback guarantees stranding, while permitting one
##    still passes every product-law eligibility proof and leaves the suspect
##    bytes intact for a newer shell or reinstall to recover.

## First explicit schema. The unversioned shape already shipped and is treated as
## v0 forever; v1 adds only this field, so an older shell still reads every
## operational field and a newer shell can migrate v0 on its next real write.
const RECOVERY_VERSION := 1

## Runtime-only marker placed on a safe degraded view of unreadable/newer bytes.
## It is never persisted. Pure transition functions and save_state refuse it,
## while RollbackSelection sees the readable quarantine array it needs to keep
## recovery available.
const _READ_ONLY_KEY := "__recovery_read_only"


## Where the shipped bootstrap keeps the file. `main.gd` runs [method load_state]
## → [method reconcile] → [method save_state] against this path on every launch
## (#301), so a marker is acted on by the very next boot.
##
## MARKING ([method begin_attempt] / [method promote]) is still unwired, and
## deliberately so: its only honest subject is a staged pack, and approximating
## that with the RUNNING build is unrecoverable — an interrupted startup would
## quarantine the installed build, and since [method begin_attempt] refuses a
## quarantined version, no later successful boot could ever clear it. Those two
## belong to the pack-mount path in the in-client updater child.
const DEFAULT_PATH := "user://boot_recovery.json"

## Test seam, the same discipline as [CharacterStore] and [SaveVault]: a boot
## test must never read or write the player's real recovery ledger. Empty/unset
## means the shipped default — production never sets it.
const RECOVERY_PATH_ENV := "WAR_BOOT_RECOVERY_PATH"


## The active recovery-ledger path: the [constant RECOVERY_PATH_ENV] override
## when set, else the shipped default.
static func recovery_path() -> String:
	var override := OS.get_environment(RECOVERY_PATH_ENV)
	return override if not override.is_empty() else DEFAULT_PATH


## The legitimate first-boot state: nothing pending, nothing failed, nothing
## promoted yet.
static func fresh_state() -> Dictionary:
	return {
		"version": RECOVERY_VERSION,
		"marker": null,
		"quarantined": [],
		"last_good": null,
	}


## Durably mark `version` as attempting to boot, BEFORE it is mounted. If this
## launch never reaches [method promote], the next launch's [method reconcile]
## quarantines exactly this version.
##
## Refuses (state unchanged) when the state or version is unreadable, when another
## attempt is already pending — the bootstrap must reconcile at launch before
## beginning a new attempt, and silently overwriting a pending marker would erase
## the evidence of a failure — or when the candidate cannot be shown safe:
## [method RollbackSelection.is_quarantined] answers true both for a quarantined
## version and for an unreadable ledger, so a torn ledger refuses every candidate
## rather than re-admitting a known-broken build (fail closed, the file's rule).
##
## Parameters are untyped for the reason established across [RollbackSelection]:
## every input arrives from disk, and a typed parameter would crash before the
## fail-closed refusal could be returned.
static func begin_attempt(state: Variant, version: Variant) -> Dictionary:
	if state is not Dictionary:
		return _refuse(state, "refusing to begin a boot attempt — the recovery state is missing or is not a dictionary")
	var s := state as Dictionary
	if s.get(_READ_ONLY_KEY, false) == true:
		return _refuse(state, "refusing to begin a boot attempt while recovery memory is read-only — rollback remains available, but quarantine history must be repaired before mounting another update")
	var schema_error := _schema_error(s)
	if not schema_error.is_empty():
		return _refuse(state, "refusing to begin a boot attempt — %s" % schema_error)
	if not UpdateDecision.is_version(version):
		return _refuse(state, "refusing to begin a boot attempt for an unreadable version")
	var pending: Variant = s.get("marker")
	if pending != null:
		return _refuse(state, "refusing to begin a boot attempt while one is already pending (%s) — reconcile at launch must run first" % [str(pending)])
	# `quarantined` may be ABSENT (the legitimate first-boot state, mirroring
	# select()'s rule) but present-and-unreadable fails closed via is_quarantined.
	if RollbackSelection.is_quarantined(s.get("quarantined", []), version):
		return _refuse(state, "refusing to mount %s — it is quarantined, or the quarantine ledger cannot be read" % [str(version)])
	var out := s.duplicate(true)
	out["marker"] = str(version)
	return {"ok": true, "state": out, "reason": "boot attempt of %s recorded — promote() once the boot reaches its checkpoint" % [str(version)]}


## The running boot reached the success checkpoint: clear the pending marker and
## record `version` as last-good. Refuses when no attempt is pending, when the
## pending marker is unreadable (the next launch's [method reconcile] clears it),
## or when `version` is not the build the attempt recorded — matching is NUMERIC
## via [method UpdateDecision.compare_versions], so a promotion cannot be denied
## or misdirected by an alias spelling of the same build.
static func promote(state: Variant, version: Variant) -> Dictionary:
	if state is not Dictionary:
		return _refuse(state, "refusing to promote — the recovery state is missing or is not a dictionary")
	var s := state as Dictionary
	if s.get(_READ_ONLY_KEY, false) == true:
		return _refuse(state, "refusing to promote while recovery memory is read-only")
	var schema_error := _schema_error(s)
	if not schema_error.is_empty():
		return _refuse(state, "refusing to promote — %s" % schema_error)
	if not UpdateDecision.is_version(version):
		return _refuse(state, "refusing to promote an unreadable version")
	var pending: Variant = s.get("marker")
	if pending == null:
		return _refuse(state, "refusing to promote %s — no boot attempt is pending" % [str(version)])
	if not UpdateDecision.is_version(pending):
		return _refuse(state, "refusing to promote — the pending boot-attempt marker is unreadable; the next launch's reconcile clears it")
	if UpdateDecision.compare_versions(str(pending), str(version)) != 0:
		return _refuse(state, "refusing to promote %s — the pending attempt is %s" % [str(version), str(pending)])
	var out := s.duplicate(true)
	out["marker"] = null
	out["last_good"] = str(version)
	return {"ok": true, "state": out, "reason": "%s reached the boot checkpoint and is now last-good" % [str(version)]}


## Run at every launch, BEFORE selecting or mounting anything: settle what the
## previous launch left behind. Returns
## `{ ok: bool, state: Dictionary, quarantined_version: String, reason: String }`
## where `quarantined_version` names the build recorded as failed ("" when none
## was).
##
## No pending marker → no-op. A pending marker means the previous launch mounted
## that version and never reached the checkpoint — a crash, a hang, or a kill —
## so it is recorded in the quarantine ledger and the marker cleared. The two torn
## states follow the policies in the class doc: an unreadable marker is cleared
## loudly with nothing recorded; an unreadable ledger holding back a REAL pending
## failure is replaced via [method RollbackSelection.recover_ledger], recording
## the current failure and loudly discarding the unreadable history.
static func reconcile(state: Variant) -> Dictionary:
	if state is not Dictionary:
		return {"ok": false, "state": state, "quarantined_version": "", "reason": "refusing to reconcile — the recovery state is missing or is not a dictionary"}
	var s := state as Dictionary
	var schema_error := _schema_error(s)
	if not schema_error.is_empty():
		return {"ok": false, "state": state, "quarantined_version": "", "reason": "refusing to reconcile — %s" % schema_error}
	var pending: Variant = s.get("marker")
	if pending == null:
		return {"ok": true, "state": s.duplicate(true), "quarantined_version": "", "reason": "no boot attempt was pending"}
	if not UpdateDecision.is_version(pending):
		var cleared := s.duplicate(true)
		cleared["marker"] = null
		return {"ok": true, "state": cleared, "quarantined_version": "", "reason": "a boot-attempt marker was present but unreadable — the failed build cannot be identified, so nothing was quarantined; marker cleared so launches are not wedged forever"}
	var failed := str(pending)
	var ledger: Variant = s.get("quarantined", [])
	var q := RollbackSelection.quarantine(ledger, failed)
	if q["ok"] as bool:
		var out := s.duplicate(true)
		out["marker"] = null
		out["quarantined"] = q["ledger"]
		return {"ok": true, "state": out, "quarantined_version": failed, "reason": "the previous launch of %s never reached its boot checkpoint — quarantined" % failed}
	# quarantine() refuses for exactly two causes, and the marker was verified a
	# version above — so the ledger is unreadable. A real failure is pending and
	# cannot be recorded: this is the decided-unrecoverable case recover_ledger
	# exists for, chosen here by predicate, never as a blind fallback.
	var r := RollbackSelection.recover_ledger(ledger, failed)
	if not (r["ok"] as bool):
		return {"ok": false, "state": state, "quarantined_version": "", "reason": "could not record the pending failure of %s: %s" % [failed, str(r["reason"])]}
	var recovered := s.duplicate(true)
	recovered["marker"] = null
	recovered["quarantined"] = r["ledger"]
	return {"ok": true, "state": recovered, "quarantined_version": failed, "reason": str(r["reason"])}


## Read the persisted recovery state. A missing file is the legitimate first boot
## and loads as [method fresh_state] with `ok` true. The shipped unversioned shape
## is legacy v0 and is expanded in memory to v1 without losing a field. A parseable
## v1 file must carry exactly the four documented keys; a missing or unknown key,
## malformed/newer version, or invalid JSON returns `ok` false with a read-only
## degraded state. That state preserves the suspect bytes, refuses writes and new
## attempts, but keeps rollback selection available as decided in the class doc.
## Present operational VALUES load as they are: per-value trust is judged by the
## fail-closed consumers, not sanitised away at load time.
static func load_state(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": true, "state": fresh_state(), "reason": "no recovery file at %s — first boot" % path}
	var text := FileAccess.get_file_as_string(path)
	# JSON.parse_string logs an engine ERROR for expected corrupt-input tests.
	# The instance parser reports the same failure as data, keeping a safe
	# degradation loud through our reason without polluting every normal test run.
	var json := JSON.new()
	if json.parse(text) != OK:
		return _degraded_load(
			"recovery file at %s is unreadable — bytes preserved read-only; new updates are refused, but an independently-compatible retained rollback remains available" % path)
	var parsed: Variant = json.data
	if parsed is not Dictionary:
		return _degraded_load(
			"recovery file at %s is unreadable — bytes preserved read-only; new updates are refused, but an independently-compatible retained rollback remains available" % path)
	var p := parsed as Dictionary
	if not (p.has("marker") and p.has("quarantined") and p.has("last_good")):
		return _degraded_load(
			"recovery file at %s is missing required keys — bytes preserved read-only; new updates are refused, but rollback remains available" % path)
	var schema: Variant = p.get("version", 0)
	if p.has("version") and (
			not UpdateDecision.is_int_id(schema)
			or int(schema) < 1
			or int(schema) > RECOVERY_VERSION):
		return _degraded_load(
			"recovery file at %s declares unsupported schema %s (this shell reads through v%d) — bytes preserved read-only; new updates are refused, but rollback remains available"
			% [path, str(schema), RECOVERY_VERSION])
	var allowed := {"marker": true, "quarantined": true, "last_good": true}
	if p.has("version"):
		allowed["version"] = true
	for key: String in p:
		if not allowed.has(key):
			return _degraded_load(
				"recovery file at %s carries unknown field '%s' without a readable schema — bytes preserved read-only; new updates are refused, but rollback remains available"
				% [path, key])
	return {
		"ok": true,
		"state": {
			"version": RECOVERY_VERSION,
			"marker": p.get("marker"),
			"quarantined": p.get("quarantined"),
			"last_good": p.get("last_good"),
		},
		"reason": "recovery state loaded from %s" % path,
	}


## Persist `state` to `path`, atomically (temp file + rename, the
## [CharacterStore] pattern — a crash mid-write must never tear the only copy of
## the failure history). Returns `{ ok: bool, reason: String }`.
##
## Refuses to write any state the read side would refuse to trust: an unreadable
## marker, ledger ([method RollbackSelection.is_readable_ledger] — the same
## predicate select() trusts, so write and read can never diverge) or last-good.
## Writing junk into a well-formed file would LAUNDER corruption into evidence,
## which is exactly how a recorded failure gets erased.
static func save_state(path: String, state: Variant) -> Dictionary:
	if state is not Dictionary:
		return {"ok": false, "reason": "refusing to persist recovery state that is not a dictionary"}
	var s := state as Dictionary
	if s.get(_READ_ONLY_KEY, false) == true:
		return {"ok": false, "reason": "refusing to overwrite unreadable or newer recovery evidence with a degraded in-memory state"}
	var schema_error := _schema_error(s)
	if not schema_error.is_empty():
		return {"ok": false, "reason": "refusing to persist recovery state — %s" % schema_error}
	var marker: Variant = s.get("marker")
	if marker != null and not UpdateDecision.is_version(marker):
		return {"ok": false, "reason": "refusing to persist an unreadable boot-attempt marker — a well-formed file holding junk would erase the pending attempt on the next read"}
	var ledger: Variant = s.get("quarantined", [])
	if not RollbackSelection.is_readable_ledger(ledger):
		return {"ok": false, "reason": "refusing to persist an unreadable quarantine ledger — a well-formed file holding junk would erase recorded failures on the next read"}
	var last_good: Variant = s.get("last_good")
	if last_good != null and not UpdateDecision.is_version(last_good):
		return {"ok": false, "reason": "refusing to persist an unreadable last-good version"}
	var entries: Array[String] = []
	for raw: Variant in (ledger as Array):
		entries.append(str(raw))
	var to_write := {
		"version": RECOVERY_VERSION,
		"marker": null if marker == null else str(marker),
		"quarantined": entries,
		"last_good": null if last_good == null else str(last_good),
	}
	var payload := JSON.stringify(to_write, "  ")
	var tmp_path := path + ".tmp"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "reason": "cannot write %s" % tmp_path}
	file.store_string(payload)
	file.close()
	# Verify the bytes actually landed BEFORE they replace the only copy of the
	# failure history: a short write (full disk, I/O error) would otherwise rename
	# a truncated file over valid state and report success.
	if FileAccess.get_file_as_string(tmp_path) != payload:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_path))
		return {"ok": false, "reason": "read-back of %s did not match what was written — refusing to replace the recovery state with a torn file" % tmp_path}
	var err := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(tmp_path), ProjectSettings.globalize_path(path))
	if err != OK:
		return {"ok": false, "reason": "atomic replace of %s failed (%d)" % [path, err]}
	return {"ok": true, "reason": "recovery state persisted to %s" % path}


## Empty means a state belongs to a schema this shell understands. Absence is
## legacy v0 and remains valid forever; explicit schemas start at v1.
static func _schema_error(state: Dictionary) -> String:
	if not state.has("version"):
		return ""
	var version: Variant = state.get("version")
	if not UpdateDecision.is_int_id(version) or int(version) < 1:
		return "recovery schema is missing or malformed"
	if int(version) > RECOVERY_VERSION:
		return "recovery schema v%d is newer than this shell understands (v%d)" % [
			int(version), RECOVERY_VERSION]
	return ""


static func _degraded_load(reason: String) -> Dictionary:
	var state := fresh_state()
	state[_READ_ONLY_KEY] = true
	return {"ok": false, "state": state, "reason": reason}


static func _refuse(state: Variant, reason: String) -> Dictionary:
	# Hand back what was given, never a substitute — the rule established by
	# RollbackSelection.quarantine(): a refusal that swaps the value makes the
	# next function in the chain reason about a state that was never there.
	return {"ok": false, "state": state, "reason": reason}
