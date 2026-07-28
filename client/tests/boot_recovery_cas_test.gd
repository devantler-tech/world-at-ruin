extends Node
## Compare-and-swap test for the boot-recovery ledger's write path (issue #453).
##
## boot_recovery_lock_test pins what the write LOCK does; this pins what happens
## to the writers the lock cannot bind. A lock binds only writers that take it,
## so a retained pre-lock build, a rollback build, cloud sync, a backup agent and
## a hand edit all walk straight through it. Each replaces
## user://boot_recovery.json while a lock-aware shell holds a document it read
## before that write, and the reconcile-then-rename that follows discards the
## other writer's record without ever learning it existed.
##
## What is lost is not a respawn point. It is the evidence deciding whether a
## client rolls back — a quarantine entry or a pending marker — and quarantine is
## forward-only, so the loss lands at the least recoverable moment there is.
##
## The guard is a compare-and-swap on the document's own BYTES: record an
## identity when the ledger is read, verify the file still carries it immediately
## before the rename, refuse when it does not. It keys on what the file IS rather
## than on who cooperated, which is why it sees every writer above. The vault
## solved the identical problem in #386 and this ports its shape rather than
## inventing a second one.
##
## A foreign writer is simulated by writing the file directly with FileAccess and
## never taking the lock. That is not an approximation — a rollback build, a sync
## daemon and a hand edit all produce exactly that: different bytes, no lock. The
## code under test cannot tell the difference.
##
## What is pinned:
##  1. document_identity() is absent-vs-present, changes on any byte change, is
##     stable across re-reads, and never collides with either sentinel.
##  2. A foreign writer between read and rename is DETECTED: the write refuses
##     and the foreign document survives BYTE-INTACT.
##  3. The refusal is not vacuous — the identical call with a CURRENT identity
##     succeeds. Without this the whole file could pass by always refusing.
##  4. Detection covers the absent -> created direction too: a shell that read no
##     ledger must still refuse once one has appeared.
##  5. The refusal REASON distinguishes "someone else wrote" from "this build
##     cannot read the destination" and from lock contention. A caller that
##     cannot tell those apart cannot decide whether to retry.
##  6. Refusing is session-only degradation, never a boot blocker: the ledger
##     still READS, and it reads the foreign writer's document.
##  7. A refused write leaves no staging file behind.
##  8. save_state() without an expectation stays a deliberate blind replace, so
##     the first-boot and test-seed callers are unaffected.
##
## The production path's threading is pinned in boot_ledger_boot_test, not here.
## A helper that passes IDENTITY_UNCHECKED writes correctly whenever nothing
## races it, so every assertion in THIS file still passes while the guard is
## absent from the product — the same ablation that was measured slipping through
## the vault's end-to-end coverage. Only the real boot can tell the difference,
## which is why the expectation each production write ran under is asserted
## there, against the scene that actually calls save_state().
##
## RESIDUAL, stated rather than glossed: verify-then-rename is two operations, so
## the window shrinks to the rename syscall rather than closing. Closing it needs
## an OS-level lock held across the rename, which Godot does not expose. The gain
## is a DETECTED refusal in place of a silent lost update, which this file's law
## already handles: session-only, loud, never fatal.
##
## TWO PROPERTIES HERE ARE DELIBERATELY UNPINNED, and saying so is the point —
## both were ablated and both left every assertion in this file green:
##
##  - document_identity() answering IDENTITY_UNREADABLE on a hash failure.
##    Deleting that branch collapses it into IDENTITY_ABSENT and nothing fails,
##    because provoking a genuine hash failure needs filesystem conditions a test
##    cannot portably create. What IS pinned is the constant staying distinct
##    from ABSENT and UNCHECKED (case 1), which is the part with a reachable lost
##    update behind it — a first-boot write expecting absence must not match a
##    ledger that appeared but cannot be hashed. The vault carries the identical
##    gap for the identical reason.
##  - The caller capturing the identity BEFORE load_state rather than after.
##    Swapping those two lines also leaves everything green, because nothing
##    races the load inside one process, so both orders hash the same bytes.
##    Only a second process writing between the load and the capture separates
##    them. The ordering is load-bearing all the same — captured after, an
##    interleaved foreign write becomes the expectation while the transaction
##    still holds the old document — so it is guarded by the comment at the call
##    site in main.gd and by review, not by this file.
##
## Neither is a reason to trust the guard less; both are reasons not to read a
## green run here as covering more than it does.
##
## Everything runs against a throwaway path via WAR_BOOT_RECOVERY_PATH, so the
## player's own ledger is never touched — quarantine is forward-only, so a test
## that quarantined the real installed build could never be undone.
##
## Run: godot --headless --path client res://tests/boot_recovery_cas_test.tscn

const PROBE := "user://boot_recovery_cas_probe.json"

## A ledger a foreign writer leaves: valid, same-version, still readable. An
## unreadable one would be caught by the readability re-check and would prove
## nothing about the compare-and-swap.
const FOREIGN_BODY := '{"version": 1, "marker": null, "quarantined": ["0.9.9"], "last_good": null}'


func _ready() -> void:
	_cleanup()
	OS.set_environment(BootRecovery.RECOVERY_PATH_ENV, PROBE)

	# 1. The identity primitive itself. Everything below compares two of these, so
	# a constant-valued or always-empty identity would make every later case pass
	# while detecting nothing.
	if BootRecovery.document_identity(PROBE) != BootRecovery.IDENTITY_ABSENT:
		_fail("an absent ledger did not report the absent identity")
		return
	var seeded := BootRecovery.save_state(PROBE, BootRecovery.fresh_state())
	if not (seeded["ok"] as bool):
		_fail("the first ledger write did not persist — %s" % str(seeded["reason"]))
		return
	var first := BootRecovery.document_identity(PROBE)
	if first == BootRecovery.IDENTITY_ABSENT:
		_fail("a present ledger reported the absent identity")
		return
	if first == BootRecovery.IDENTITY_UNCHECKED:
		_fail("a real identity collided with the opt-out sentinel — the CAS would silently never run")
		return
	if first == BootRecovery.IDENTITY_UNREADABLE:
		_fail("a readable ledger reported the unreadable identity")
		return
	if BootRecovery.document_identity(PROBE) != first:
		_fail("the identity of an unchanged ledger was not stable — every write would refuse")
		return
	# The three sentinels must stay pairwise distinct. Collapsing ABSENT and
	# UNREADABLE is a lost update rather than a refusal: a shell that read no
	# ledger expects absence, and a ledger that has appeared since but cannot be
	# hashed would compare EQUAL to that expectation and be replaced.
	if BootRecovery.IDENTITY_ABSENT == BootRecovery.IDENTITY_UNREADABLE:
		_fail("the absent and unreadable identities are the same value — an unhashable ledger would be overwritten by a first-boot write")
		return
	if BootRecovery.IDENTITY_UNCHECKED == BootRecovery.IDENTITY_ABSENT:
		_fail("the opt-out sentinel collides with the absent identity — 'no expectation' would be indistinguishable from 'expected nothing'")
		return

	# A byte change must move it. A quarantine entry merges into the document, so
	# this is a same-version, same-shape, still-readable write — exactly the case
	# the readability re-check cannot see and only the bytes distinguish.
	var quarantined := BootRecovery.fresh_state()
	quarantined["quarantined"] = ["0.1.2"]
	var second_write := BootRecovery.save_state(PROBE, quarantined, false, first)
	if not (second_write["ok"] as bool):
		_fail("a write presenting the current identity refused — %s" % str(second_write["reason"]))
		return
	var second := BootRecovery.document_identity(PROBE)
	if second == first:
		_fail("the identity did not change when the ledger's bytes did — a foreign write would compare equal and be overwritten")
		return

	# 2. A foreign writer lands between this shell's read and its rename. `second`
	# is the identity this shell read; the foreign bytes are what is on disk now.
	if not _foreign_write(PROBE, FOREIGN_BODY):
		_fail("could not simulate a foreign writer")
		return
	var foreign_bytes := _read(PROBE)
	var promoted := BootRecovery.fresh_state()
	promoted["last_good"] = "1.0.0"
	var stale := BootRecovery.save_state(PROBE, promoted, false, second)
	if stale["ok"] as bool:
		_fail("a write presenting a STALE identity overwrote a foreign writer's ledger — the quarantine evidence is lost")
		return
	if _read(PROBE) != foreign_bytes:
		_fail("the refused write still modified the ledger — the bytes must be left exactly as the foreign writer left them")
		return

	# 5. The refusal must be attributable. "Someone else wrote" is retryable after
	# a fresh read; "this build cannot read the destination" is not, and lock
	# contention is a third outcome again. A caller handed one undifferentiated
	# failure cannot choose between them.
	var stale_reason := str(stale["reason"])
	if not stale_reason.contains("changed under this write"):
		_fail("the compare-and-swap refusal does not name what happened — a caller cannot tell it from an unreadable destination; got: %s" % stale_reason)
		return
	if stale_reason.contains("unreadable or newer"):
		_fail("the compare-and-swap refusal is worded as an unreadable/newer destination — the two outcomes are indistinguishable to a caller")
		return
	if stale_reason.contains("write lock"):
		_fail("the compare-and-swap refusal is worded as lock contention — the two outcomes are indistinguishable to a caller")
		return

	# 7. A refused write leaves no staging file. Staging names carry a per-attempt
	# stamp and are never reclaimed by being overwritten, so a refusal branch that
	# forgets to remove its stage leaks a file on every occurrence.
	var leftovers := _staging_leftovers()
	if not leftovers.is_empty():
		_fail("a refused compare-and-swap left %d staging file(s) behind: %s" % [leftovers.size(), str(leftovers)])
		return

	# 6. Refusing is session-only degradation. The ledger must still READ — a
	# guard that could wedge a boot would be the very thing recovery exists to
	# prevent — and it must read the FOREIGN writer's document, not ours.
	var after := BootRecovery.load_state(PROBE)
	if not (after["ok"] as bool):
		_fail("the ledger stopped reading after a refused write — recovery memory must never block a boot")
		return
	var after_state: Dictionary = after["state"]
	if not (after_state.get("quarantined", []) as Array).has("0.9.9"):
		_fail("the ledger did not read back the foreign writer's document after the refusal")
		return

	# 3. The refusal is not vacuous: the SAME call, with the identity the ledger
	# actually carries now, must succeed. Without this the file passes by always
	# refusing, which detects nothing and blocks every real write.
	var current := BootRecovery.document_identity(PROBE)
	var fresh_write := BootRecovery.save_state(PROBE, promoted, false, current)
	if not (fresh_write["ok"] as bool):
		_fail("a write presenting the CURRENT identity refused — the guard rejects every write, not just racing ones: %s" % str(fresh_write["reason"]))
		return
	var settled := BootRecovery.load_state(PROBE)
	if not (settled["ok"] as bool) or (settled["state"] as Dictionary).get("last_good") != "1.0.0":
		_fail("the accepted write did not reach disk")
		return

	# 4. The absent -> created direction. A shell that loaded no ledger expects
	# absence; another writer creating one before its rename must refuse, or first
	# boot silently discards a document that already carried a quarantine record.
	_remove(PROBE)
	if BootRecovery.document_identity(PROBE) != BootRecovery.IDENTITY_ABSENT:
		_fail("a removed ledger did not report the absent identity")
		return
	if not _foreign_write(PROBE, FOREIGN_BODY):
		_fail("could not simulate a writer creating the ledger after a first-boot read")
		return
	var appeared_bytes := _read(PROBE)
	var first_boot := BootRecovery.save_state(
		PROBE, BootRecovery.fresh_state(), false, BootRecovery.IDENTITY_ABSENT)
	if first_boot["ok"] as bool:
		_fail("a first-boot write overwrote a ledger that appeared after its read")
		return
	if _read(PROBE) != appeared_bytes:
		_fail("the refused first-boot write still modified the ledger that had appeared")
		return

	# 8. save_state() without an expectation is still a blind whole-document
	# replace. The sentinel is the opt-out for callers that never read first, and
	# it must remain usable — a CAS applied silently to every write would break
	# every seed and the existing lock and staging suites.
	var blind := BootRecovery.save_state(PROBE, BootRecovery.fresh_state())
	if not (blind["ok"] as bool):
		_fail("save_state() no longer performs a blind replace — %s" % str(blind["reason"]))
		return
	var blanked := BootRecovery.load_state(PROBE)
	if not (blanked["ok"] as bool) or not ((blanked["state"] as Dictionary).get("quarantined", []) as Array).is_empty():
		_fail("the blind replace did not take effect")
		return

	_cleanup()
	OS.set_environment(BootRecovery.RECOVERY_PATH_ENV, "")
	print("TEST PASS — boot-recovery writes compare-and-swap on the ledger's bytes, so a writer that never took the lock is detected and refused instead of silently overwritten")
	get_tree().quit(0)


func _fail(message: String) -> void:
	_cleanup()
	OS.set_environment(BootRecovery.RECOVERY_PATH_ENV, "")
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _exit_tree() -> void:
	_cleanup()


func _abs(path: String) -> String:
	return ProjectSettings.globalize_path(path)


## Replace the ledger WITHOUT taking the lock and without going through
## BootRecovery — a pre-lock retained build, a rollback build, cloud sync, a
## backup agent or a hand edit. The document is valid and same-version on
## purpose: an unreadable one would be caught by the readability re-check, and
## would prove nothing about the compare-and-swap.
func _foreign_write(path: String, body: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(body)
	file.close()
	return true


## The ledger's bytes, or "" when absent. Byte comparison is deliberate: a
## refused write must leave the file untouched, and comparing parsed documents
## would hide a rewrite that happened to round-trip to the same state.
func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text


func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(_abs(path))


## Every staging file beside the probe. Staging paths carry a per-attempt stamp,
## so they cannot be reconstructed by name — scan the directory for the prefix.
func _staging_leftovers() -> Array:
	var parent := PROBE.get_base_dir()
	var prefix := PROBE.get_file() + BootRecovery.WRITE_TMP_SUFFIX
	var found: Array = []
	for entry: String in DirAccess.get_files_at(parent):
		if entry.begins_with(prefix):
			found.append(parent.path_join(entry))
	return found


func _cleanup() -> void:
	FileLock.clear_for_test()
	BootRecovery.clear_refusals_for_test()
	var lock := FileLock.path_for(PROBE)
	DirAccess.remove_absolute(_abs(lock + "/" + FileLock.OWNER_FILE))
	DirAccess.remove_absolute(_abs(lock))
	for path: String in [PROBE, PROBE + ".tmp"]:
		_remove(path)
	for leftover: String in _staging_leftovers():
		_remove(leftover)
