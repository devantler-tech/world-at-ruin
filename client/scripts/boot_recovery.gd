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
##     version: absent | int,     # absence is shipped v0; new and changed state
##                                 # uses v1, which retained v0.51.1 can read
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

## Maximum schema this shell can READ. The unversioned shape is treated as v0
## forever; v1 adds only this field. The retained v0.51.1 app reads v1 and is the
## standing rollback target that permits this shell to originate it.
const RECOVERY_VERSION := 1

## Schema originated by first boot and the next real write of legacy v0 state.
## Kept separate from [constant RECOVERY_VERSION] so the next migration can
## expand its reader without accidentally activating its writer.
const WRITE_VERSION := 1

## Runtime-only marker placed on a safe degraded view of unreadable/newer bytes.
## It is never persisted. Pure transition functions and save_state refuse it,
## while RollbackSelection sees the readable quarantine array it needs to keep
## recovery available.
const _READ_ONLY_KEY := "__recovery_read_only"

## Paths refused at least once this session. Refusal attaches to the path, not
## only the returned Dictionary: reconstructing fresh state, deleting the file,
## or replacing it from another shell must not turn refused evidence writable.
## Restarting is the deliberate point at which the shell re-examines the path.
static var _refused_paths: Dictionary = {}


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

## Compatibility alias for the shared private-staging prefix. Existing callers
## may inspect it, while [PrivateStaging] remains its single declaration.
const WRITE_TMP_SUFFIX := PrivateStaging.WRITE_TMP_SUFFIX

## The identity of a recovery path that holds no file. Distinct from
## [constant IDENTITY_UNCHECKED]: "absent" is a real state to compare against,
## and a first boot that read nothing must still refuse if a ledger appeared
## meanwhile carrying a quarantine record.
const IDENTITY_ABSENT := ""

## The identity of a ledger that is PRESENT but could not be hashed.
##
## Distinct from [constant IDENTITY_ABSENT] because collapsing the two turns a
## refusal into a lost update: a shell that read nothing expects absence, and a
## ledger that appeared since but cannot be hashed would compare equal to that
## expectation. A write never proceeds against this value on either side.
const IDENTITY_UNREADABLE := "?"

## The opt-out for [method save_state]: replace whatever is there.
##
## A single `*` can never collide with a real identity — those are SHA-256 hex —
## nor with [constant IDENTITY_ABSENT], so "no expectation" stays distinguishable
## from "expected nothing". It exists for callers that never read the ledger
## first; every read-modify-write passes a real identity instead.
const IDENTITY_UNCHECKED := "*"


## The expectation the most recent [method save_state] call ran under.
##
## FOR TESTS ONLY, and it exists because the thing it pins cannot otherwise be
## observed. The reconcile transaction is protected only if it threads a REAL
## identity; a caller passing [constant IDENTITY_UNCHECKED] instead still writes
## correctly whenever nothing races it, so an end-to-end assertion — and even a
## replay of the caller's own sequence — passes while the protection is gone.
## That exact ablation was measured slipping through both for [SaveVault].
## Landing a foreign write INSIDE a live call needs a second process, so what the
## call ran under is recorded here instead, and `boot_ledger_boot_test` asserts
## it against the real booted scene.
static var _last_write_expectation: String = IDENTITY_UNCHECKED


## The active recovery-ledger path: the [constant RECOVERY_PATH_ENV] override
## when set, else the shipped default.
static func recovery_path() -> String:
	var override := OS.get_environment(RECOVERY_PATH_ENV)
	return override if not override.is_empty() else DEFAULT_PATH


## The legitimate first-boot state: nothing pending, nothing failed, nothing
## promoted yet.
static func fresh_state() -> Dictionary:
	return {
		"version": WRITE_VERSION,
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


## Read the persisted recovery state. Returns
## `{ ok: bool, state: Dictionary, path_was_missing: bool, reason: String }`.
## `path_was_missing` is decided by this read, so first-boot callers never rely on
## a stale existence check made before loading. A missing file is the legitimate
## first boot and loads as [method fresh_state] with `ok` true. The shipped
## unversioned shape is legacy v0 and remains v0 in memory without losing a
## field. A parseable v1 file must carry exactly the four documented keys; a
## missing or unknown key, malformed/newer version, or invalid JSON returns `ok`
## false with a read-only degraded state. That state preserves the suspect bytes,
## refuses writes and new attempts, but keeps rollback selection available as
## decided in the class doc. Present operational VALUES load as they are:
## per-value trust is judged by the fail-closed consumers, not sanitised away at
## load time.
static func load_state(path: String) -> Dictionary:
	if _refused_paths.has(path):
		return _degraded_load(
			path,
			"recovery path %s was already refused this session — it remains read-only until restart, while an independently-compatible retained rollback remains available" % path)
	if not FileAccess.file_exists(path):
		return {
			"ok": true,
			"state": fresh_state(),
			"path_was_missing": true,
			"reason": "no recovery file at %s — first boot" % path,
		}
	var text := FileAccess.get_file_as_string(path)
	# JSON.parse_string logs an engine ERROR for expected corrupt-input tests.
	# The instance parser reports the same failure as data, keeping a safe
	# degradation loud through our reason without polluting every normal test run.
	var json := JSON.new()
	if json.parse(text) != OK:
		return _degraded_load(
			path,
			"recovery file at %s is unreadable — bytes preserved read-only; new updates are refused, but an independently-compatible retained rollback remains available" % path)
	var parsed: Variant = json.data
	if parsed is not Dictionary:
		return _degraded_load(
			path,
			"recovery file at %s is unreadable — bytes preserved read-only; new updates are refused, but an independently-compatible retained rollback remains available" % path)
	var p := parsed as Dictionary
	if not (p.has("marker") and p.has("quarantined") and p.has("last_good")):
		return _degraded_load(
			path,
			"recovery file at %s is missing required keys — bytes preserved read-only; new updates are refused, but rollback remains available" % path)
	var schema: Variant = p.get("version", 0)
	if p.has("version") and (
			not UpdateDecision.is_int_id(schema)
			or int(schema) < 1
			or int(schema) > RECOVERY_VERSION):
		return _degraded_load(
			path,
			"recovery file at %s declares unsupported schema %s (this shell reads through v%d) — bytes preserved read-only; new updates are refused, but rollback remains available"
			% [path, str(schema), RECOVERY_VERSION])
	var allowed := {"marker": true, "quarantined": true, "last_good": true}
	if p.has("version"):
		allowed["version"] = true
	for key: String in p:
		if not allowed.has(key):
			return _degraded_load(
				path,
				"recovery file at %s carries unknown field '%s' without a readable schema — bytes preserved read-only; new updates are refused, but rollback remains available"
				% [path, key])
	return {
		"ok": true,
		"state": {
			"version": int(schema),
			"marker": p.get("marker"),
			"quarantined": p.get("quarantined"),
			"last_good": p.get("last_good"),
		},
		"path_was_missing": false,
		"reason": "recovery state loaded from %s" % path,
	}


## Persist `state` to `path`, atomically (private staging file + rename, the
## [CharacterStore] pattern — a crash mid-write must never tear the only copy of
## the failure history). When `only_if_missing` is true, refuse if another shell
## or cloud-sync writer created the destination after [method load_state]
## observed first boot. Returns `{ ok: bool, reason: String }`.
##
## Refuses to write any state the read side would refuse to trust: an unreadable
## marker, ledger ([method RollbackSelection.is_readable_ledger] — the same
## predicate select() trusts, so write and read can never diverge) or last-good.
## Writing junk into a well-formed file would LAUNDER corruption into evidence,
## which is exactly how a recorded failure gets erased.
##
## Held under the cross-process write lock ([FileLock]), because this whole
## function is a read-modify-write and the two writers that race it — the updater
## and the game — both exist today. Without the lock, two of them reparse the
## same document, each merges its own record, and the slower rename discards the
## other's. What that loses is not a respawn point: it is the evidence deciding
## whether a client rolls back, lost at the least recoverable moment there is.
##
## Contention refuses the write rather than blocking, which is this file's
## standing law — persistence may degrade, but it may never stop a boot. Reads
## take no lock at all, so a held lock can never prevent a rollback decision.
##
## `expected_identity` is a compare-and-swap on the document's own bytes (#453),
## the backstop for every writer the lock cannot bind. Pass the value
## [method document_identity] returned BEFORE [method load_state] read the
## ledger; pass [constant IDENTITY_UNCHECKED] for a deliberate blind replace.
static func save_state(
		path: String,
		state: Variant,
		only_if_missing: bool = false,
		expected_identity: String = IDENTITY_UNCHECKED) -> Dictionary:
	_last_write_expectation = expected_identity
	if not FileLock.acquire(path):
		return {"ok": false, "reason": "refusing to persist recovery state to %s because another writer holds its write lock" % path}
	var result := _save_state_locked(path, state, only_if_missing, expected_identity)
	FileLock.release(path)
	return result


## The identity of the document at `path`: the SHA-256 of its bytes, or
## [constant IDENTITY_ABSENT] when no file is there.
##
## Keyed on WHAT THE FILE IS rather than on who cooperated, which is the whole
## reason this exists alongside the lock. A lock binds only writers that take it,
## so a retained pre-lock build, a rollback build, cloud sync, a backup agent and
## a hand edit all walk straight through it — but every one of them changes the
## bytes, so every one of them is visible here.
##
## Content-hashed rather than size-plus-mtime on purpose: mtime has
## filesystem-dependent granularity, sync tools routinely preserve it, and a
## same-size edit is exactly the shape a merged quarantine ledger has.
static func document_identity(path: String) -> String:
	if not FileAccess.file_exists(path):
		return IDENTITY_ABSENT
	var sha := FileAccess.get_sha256(path)
	# get_sha256() returns an EMPTY string on failure, and empty is exactly
	# IDENTITY_ABSENT. Collapsing the two would be a lost update rather than a
	# refusal: a shell that read no ledger expects absence, and a ledger that has
	# appeared since but cannot be hashed would compare EQUAL to that expectation
	# and be replaced. A file that is there but unreadable is its own answer, and
	# one that never matches anything.
	if sha.is_empty():
		return IDENTITY_UNREADABLE
	return sha


## The staging file this attempt commits from — PRIVATE to one write.
##
## The shared `boot_recovery.json.tmp` this replaced is a name any other process
## can derive. A writer that never took the lock — a retained or rollback build
## from before [FileLock] existed, a sync agent, a second install — opens that
## same deterministic path and truncates the staged document after it was
## serialised. `path` itself is untouched, so [method can_write], the
## `only_if_missing` re-check and the ownership proof all pass, and the rename
## then commits THEIR partial bytes over the quarantine ledger while reporting
## success. What that loses is the evidence deciding whether a client rolls back.
##
## The read-back compare below narrows this and does not close it: it catches a
## truncation landing BEFORE the compare, never one landing between the compare
## and the rename. A per-attempt name removes the sharing instead of trying to
## detect it — a writer that never cooperated cannot name the file we commit
## from.
##
## Process id plus a process-start nonce, monotonic ticks, and a process-local
## attempt sequence, matching [method SaveVault._write_tmp_path] and
## [method CharacterStore._write_tmp_path].
static func _write_tmp_path(path: String) -> String:
	return PrivateStaging.write_path(path)


## Remove staging files abandoned by a crashed writer.
##
## A per-attempt name cannot be reclaimed by simply being overwritten the way one
## fixed `boot_recovery.json.tmp` was, so without this a hard crash mid-write
## would leak a file into user:// on every occurrence.
##
## LOCK-gated like [method SaveVault._sweep_abandoned_writes], NOT age-gated like
## [method CharacterStore._sweep_abandoned_writes]. Which of the two a writer owes
## is decided by SHIPPING ORDER, not by taste, and getting it wrong deletes a live
## write. An unconditional sweep is safe only while every build that can create a
## file carrying this prefix also takes the lock.
##
## Here that holds: the lock shipped FIRST (#422) and private staging arrives after
## it (#442), so no released build stages through this prefix without holding the
## lock. [method save_state] is the only writer and holds it across the whole
## staging window, so anything found here is finished or dead. The character store
## is the mirror image — private staging shipped first (#434), its lock after
## (#423) — so retained builds from that window stage through its prefix while
## taking no lock, and only an age floor can tell those apart from a crash. That
## is why its floor stays even once it holds the lock, and why importing it here
## would delay reclamation without adding a guarantee.
##
## ⚠️ The one residual, the same wall the ownership proof documents: a holder that
## has outlived the stale timeout can be reclaimed, so its stage may be swept
## while it still exists. That writer's own read-back compare then fails and it
## abandons the write — a degraded write, never a torn file, which is this file's
## standing trade.
##
## Scoped to WRITE_TMP_SUFFIX deliberately. A foreign writer's plain
## `boot_recovery.json.tmp` carries no per-attempt stamp and is none of our
## business — deleting a file another client is mid-write on is the kind of
## cross-writer damage this whole area exists to avoid.
static func _sweep_abandoned_writes(path: String) -> void:
	# Unconditional is safe HERE because the lock shipped before private
	# staging, and this call runs while the only writer holds that lock.
	PrivateStaging.sweep(
		path,
		func(_candidate: String) -> bool: return true)


## save_state()'s body, with the write lock already held. Split out so
## acquisition and release live on ONE path each: GDScript has no `defer`, and a
## lock leaked down any of the many early-return branches below would wedge
## recovery for the whole stale timeout.
##
## The staging sweep and the staging write both live HERE rather than in
## [method save_state], because the lock is what makes the sweep safe.
static func _save_state_locked(
		path: String,
		state: Variant,
		only_if_missing: bool,
		expected_identity: String = IDENTITY_UNCHECKED) -> Dictionary:
	if state is not Dictionary:
		return {"ok": false, "reason": "refusing to persist recovery state that is not a dictionary"}
	var s := state as Dictionary
	if s.get(_READ_ONLY_KEY, false) == true:
		return {"ok": false, "reason": "refusing to overwrite unreadable or newer recovery evidence with a degraded in-memory state"}
	if _refused_paths.has(path):
		return {"ok": false, "reason": "refusing to overwrite recovery path %s because it was refused earlier this session" % path}
	if only_if_missing and FileAccess.file_exists(path):
		return {"ok": false, "reason": "refusing to initialize recovery path %s because another writer created it after the first-boot load" % path}
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
	# Loading never churns a historical document in memory. A successful real
	# write is the explicit migration boundary: legacy v0 becomes the baked
	# writer schema, while already-newer readable state keeps its own schema.
	var schema := maxi(int(s.get("version", 0)), WRITE_VERSION)
	var to_write := {
		"marker": null if marker == null else str(marker),
		"quarantined": entries,
		"last_good": null if last_good == null else str(last_good),
	}
	if schema > 0:
		to_write["version"] = schema
	var payload := JSON.stringify(to_write, "  ")
	_sweep_abandoned_writes(path)
	var tmp_path := _write_tmp_path(path)
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
	# Re-check the destination IMMEDIATELY before replacement. A valid state may
	# have been captured before another shell or cloud sync landed a future or
	# corrupt document. The state-local marker cannot see that change; the
	# path-latched read does. This catches a destination this build cannot READ;
	# a foreign document that reads perfectly well is caught by the
	# compare-and-swap below instead.
	if only_if_missing and FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_path))
		return {"ok": false, "reason": "refusing to initialize recovery path %s because another writer created it during the first-boot write" % path}
	if not can_write(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_path))
		return {"ok": false, "reason": "refusing to replace %s because its current recovery document is unreadable or newer" % path}
	# Prove we are STILL the lock's holder. A reclaimer that misjudged this live
	# lock as abandoned would have moved it away, and another writer could then
	# hold it legitimately. Replacing the record while that is true is the one
	# outcome the lock exists to prevent, so a lost lock abandons the write.
	#
	# ⚠️ Point-in-time, and it cannot be made otherwise here — the same wall the
	# vault documents. A holder that has already outlived the stale timeout can be
	# reclaimed between this returning true and the rename below. Closing that
	# needs an OS-level lock held ACROSS the rename (`flock` or equivalent), and
	# Godot's FileAccess/DirAccess expose none. What bounds it: the timeout is far
	# longer than any real critical section, the interval is a single syscall, and
	# the readability recheck above still refuses to replace a document this shell
	# cannot read — so the catastrophic case stays closed even when a lost update
	# between same-version writers slips through.
	if not FileLock.owns(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_path))
		return {"ok": false, "reason": "refusing to replace %s because this process no longer holds its write lock" % path}
	# Compare-and-swap on the document's own BYTES, last before the rename so the
	# window is as small as this file can make it (#453).
	#
	# Everything above binds only writers that COOPERATE — the lock excludes other
	# BootRecovery writers, the ownership stamp proves we still hold it. None of it
	# sees a writer that never took the lock: a retained pre-lock build, a rollback
	# build, cloud sync, a backup agent, a hand edit. Those replace the ledger, and
	# this process — holding a document it read before they wrote — would reconcile
	# onto a stale base and rename their quarantine record away without ever
	# learning it existed. Quarantine is forward-only, so that loss is permanent.
	#
	# The readability re-check above does not catch it: it refuses a document this
	# build cannot READ, and a same-version write from a foreign writer reads
	# perfectly well. Only the bytes tell them apart.
	if expected_identity != IDENTITY_UNCHECKED:
		var actual := document_identity(path)
		# An unreadable identity on EITHER side is never a match, even against
		# itself: two different unhashable files would otherwise compare equal and
		# one would be replaced by the other.
		var unreadable := (
			actual == IDENTITY_UNREADABLE or expected_identity == IDENTITY_UNREADABLE)
		if unreadable or actual != expected_identity:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_path))
			# Worded to stay distinguishable from the readability refusal above and
			# from lock contention: those three need different responses, and a
			# caller handed one undifferentiated failure cannot choose between them.
			return {"ok": false, "reason": "refusing to replace %s because its recovery document changed under this write — another writer replaced it after this shell read it" % path}
	var err := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(tmp_path), ProjectSettings.globalize_path(path))
	if err != OK:
		return {"ok": false, "reason": "atomic replace of %s failed (%d)" % [path, err]}
	return {"ok": true, "reason": "recovery state persisted to %s" % path}


## Empty means a state belongs to a schema this shell understands. Absence or
## explicit in-memory 0 is legacy v0 and remains valid forever; persisted
## explicit schemas start at v1.
static func _schema_error(state: Dictionary) -> String:
	if not state.has("version"):
		return ""
	var version: Variant = state.get("version")
	if not UpdateDecision.is_int_id(version) or int(version) < 0:
		return "recovery schema is missing or malformed"
	if int(version) > RECOVERY_VERSION:
		return "recovery schema v%d is newer than this shell understands (v%d)" % [
			int(version), RECOVERY_VERSION]
	return ""


## Whether `path` is safe to replace right now. Every refusal is latched for the
## process lifetime, and an existing destination is parsed again immediately
## before rename so a future/corrupt replacement cannot be overwritten.
static func can_write(path: String) -> bool:
	if _refused_paths.has(path):
		return false
	if not FileAccess.file_exists(path):
		return true
	return load_state(path)["ok"] as bool


## Forget latched refusals. FOR TESTS ONLY: boot_ledger_boot_test simulates
## several process restarts by replacing main.tscn inside one Godot process, so
## its probe-path latch must reset at the boundary a real restart would provide.
## Production never calls this; the refusal deliberately survives until exit.
static func clear_refusals_for_test() -> void:
	_refused_paths.clear()


static func _degraded_load(path: String, reason: String) -> Dictionary:
	_refused_paths[path] = true
	var state := fresh_state()
	state[_READ_ONLY_KEY] = true
	return {"ok": false, "state": state, "path_was_missing": false, "reason": reason}


static func _refuse(state: Variant, reason: String) -> Dictionary:
	# Hand back what was given, never a substitute — the rule established by
	# RollbackSelection.quarantine(): a refusal that swaps the value makes the
	# next function in the chain reason about a state that was never there.
	return {"ok": false, "state": state, "reason": reason}
