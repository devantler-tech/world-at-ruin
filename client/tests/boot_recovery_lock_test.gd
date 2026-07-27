extends Node
## Contention test for boot recovery's cross-process write lock (issue #379).
##
## boot_recovery_test pins the single-writer behaviour; this pins what happens
## when there is MORE than one writer. `user://boot_recovery.json` is the
## updater's memory of what happened during a boot, and it decides whether a
## client rolls back. Its persistence is a read-modify-write — reparse the
## destination, then rename over it — so two processes racing it can discard one
## writer's record. The two writers are not hypothetical: the updater and the
## game both exist today, and the moment they collide is mid-update, which is the
## least recoverable moment there is.
##
## A competing process is simulated by creating the lock directory directly. That
## is not an approximation of contention — the lock IS a directory, so one
## created by anything is byte-for-byte what a real competing client leaves
## behind, and the code under test cannot tell the difference. The one thing left
## unproven is that two simultaneous mkdir calls resolve to a single winner,
## which is the operating system's atomicity guarantee rather than ours.
##
## What is pinned:
##  1. A successful write leaves no lock behind — a leak would wedge recovery for
##     the whole stale timeout.
##  2. A held lock makes a write refuse, and leave the recovery file BYTE-INTACT.
##  3. Refusing is session-only degradation, never a boot blocker: recovery still
##     READS while another writer holds the lock. A client that cannot read this
##     file cannot decide whether to roll back, so this is the load-bearing one.
##  4. The lock is released after a REFUSED write, not only a successful one.
##  5. A stamped foreign lock refuses too — the state a real holder is in for all
##     but an instant.
##  6. A crashed process cannot wedge recovery permanently: an abandoned lock is
##     reclaimed WITHOUT acquiring in the same pass, and the next write succeeds.
##  7. A live lock is never stolen, so a writer cannot be robbed mid-write.
##
## Everything runs against a throwaway path via WAR_BOOT_RECOVERY_PATH, so the
## player's own user://boot_recovery.json is never touched (no-resets law).
##
## Run: godot --headless --path client res://tests/boot_recovery_lock_test.tscn

const PROBE := "user://boot_recovery_lock_probe.json"


func _ready() -> void:
	_cleanup()
	OS.set_environment(BootRecovery.RECOVERY_PATH_ENV, PROBE)

	var lock := FileLock.path_for(PROBE)
	if lock != PROBE + FileLock.SUFFIX:
		_fail("the lock did not sit beside the recovery file: %s" % lock)
		return

	# 1. A successful write releases the lock. Recovery persists on the boot path,
	# so a leaked lock would refuse every later write for the stale timeout — the
	# updater would stop recording what happened to it.
	var first := BootRecovery.save_state(PROBE, BootRecovery.fresh_state())
	if not first.get("ok", false):
		_fail("the first recovery write did not persist: %s" % first.get("reason", ""))
		return
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("the lock survived a successful write — it would wedge recovery")
		return

	var baseline := _read(PROBE)
	if baseline.is_empty():
		_fail("the probe recovery file is empty after a successful write")
		return

	# 2. A competing writer holds the lock: the write must refuse rather than
	# rename over the record. Compared BYTE-WISE — a rewrite that happened to
	# round-trip to the same document would still have discarded whatever the
	# other writer put there in between, and comparing parsed states would hide
	# exactly that.
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not simulate a competing writer's lock")
		return
	var contended := BootRecovery.save_state(
		PROBE, BootRecovery.begin_attempt(BootRecovery.fresh_state(), "v9.9.9"))
	if contended.get("ok", false):
		_fail("a write proceeded while another writer held the lock — the record can be discarded")
		return
	if _read(PROBE) != baseline:
		_fail("a refused write still modified the recovery file")
		return

	# 3. Contention degrades to session-only and NEVER blocks a boot. A client
	# that cannot read this file cannot decide whether to roll back, so a lock
	# must not make recovery unreadable — only unwritable.
	var readable := BootRecovery.load_state(PROBE)
	if not readable.get("ok", false):
		_fail("a held write lock made recovery UNREADABLE — a client could not decide to roll back")
		return

	# 4. The refused write released nothing it did not take, and took nothing it
	# did not release: the foreign lock is still there, and no second one appeared.
	if not DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("a refused write DELETED the competing writer's lock")
		return
	DirAccess.remove_absolute(_abs(lock))
	FileLock.clear_for_test()

	# 5. A STAMPED foreign lock refuses too. Case 2 holds a bare directory, which
	# is what a holder looks like only for the instant between creating the lock
	# and stamping it; a real holder is stamped for the whole of its write.
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not create the lock for the stamped-foreign case")
		return
	var stamp := FileAccess.open(FileLock.owner_path(lock), FileAccess.WRITE)
	if stamp == null:
		_fail("could not stamp the foreign lock")
		return
	stamp.store_string("someone-else-1")
	stamp.close()
	var stamped := BootRecovery.save_state(PROBE, BootRecovery.fresh_state())
	if stamped.get("ok", false):
		_fail("a write proceeded while a STAMPED foreign lock was held")
		return
	if _read(PROBE) != baseline:
		_fail("a write refused by a stamped foreign lock still modified the recovery file")
		return
	FileLock.remove_dir(lock)
	FileLock.clear_for_test()

	# 6. Stale recovery: a crashed process leaves a lock nobody will ever release.
	# With the timeout seamed to 0 the very next attempt may break it, so a crash
	# cannot make recovery permanently unwritable — the acceptance criterion this
	# file's law turns on.
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not simulate a crashed process's abandoned lock")
		return
	OS.set_environment(FileLock.STALE_ENV, "0")
	# Asserted at the ACQUIRE level deliberately. Going through save_state() here
	# is vacuous: a pass that wrongly acquires still fails further down on the
	# ownership guard, so the end-to-end call refuses either way and the assertion
	# would pass while the defect it names is present.
	if FileLock.acquire(PROBE):
		_fail("a reclaiming pass ACQUIRED the lock — reclaim and acquire must not share a pass")
		return
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("the abandoned lock was not reclaimed — a crash would wedge recovery permanently")
		return
	# The slot is free now, so the NEXT write acquires it cleanly. Recovery from a
	# crashed writer is one deferred write, not a permanently unwritable file.
	var resumed := BootRecovery.save_state(PROBE, BootRecovery.fresh_state())
	if not resumed.get("ok", false):
		_fail("the write did not resume after the abandoned lock was reclaimed: %s" % resumed.get("reason", ""))
		return
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("the resumed write left the lock behind")
		return
	OS.set_environment(FileLock.STALE_ENV, "")

	# 7. A live lock is never stolen. The stale window is restored, so this holder
	# is fresh: breaking it would rob a writer mid-write, which is the one loss
	# this lock exists to prevent.
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not take the lock for the freshness case")
		return
	if BootRecovery.save_state(PROBE, BootRecovery.fresh_state()).get("ok", false):
		_fail("a FRESH lock was broken — a live writer can be robbed mid-write")
		return
	if not DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("a FRESH lock was RECLAIMED — a live writer's lock must survive an attempt")
		return
	DirAccess.remove_absolute(_abs(lock))
	FileLock.clear_for_test()

	# 8. The ownership guard on the write path. Acquiring is not enough on its
	# own: a holder that outlives the stale timeout can have its lock reclaimed
	# and the freed slot taken by someone else, and replacing the record then is
	# the exact loss the lock exists to prevent. That interleaving needs two real
	# processes to arise, so it is driven here by replacing the stamp under a lock
	# this process legitimately holds.
	#
	# Asserted END TO END through save_state(). The nested acquire is reentrant
	# and succeeds, so what refuses the write is the ownership check alone —
	# ablating it makes this case, and only this case, pass a write through.
	var held := _read(PROBE)
	if not FileLock.acquire(PROBE):
		_fail("could not acquire the lock for the ownership case")
		return
	if not FileLock.owns(PROBE):
		_fail("a freshly acquired lock did not read as owned by this process")
		return
	var hijack := FileAccess.open(FileLock.owner_path(lock), FileAccess.WRITE)
	if hijack == null:
		_fail("could not overwrite the ownership stamp")
		return
	hijack.store_string("999999-2")
	hijack.close()
	var lost := BootRecovery.save_state(
		PROBE, BootRecovery.begin_attempt(BootRecovery.fresh_state(), "v8.8.8"))
	if lost.get("ok", false):
		_fail("a write proceeded while the lock was no longer ours — a stolen lock goes undetected")
		return
	if _read(PROBE) != held:
		_fail("a write that lost the lock still modified the recovery file")
		return
	FileLock.release(PROBE)
	_cleanup()

	# 9. The TRANSACTION boundary. Serializing only the final replace does not
	# close the race: two shells can each load the same ledger BEFORE either takes
	# the lock, then acquire in turn, and the second's write discards the first's
	# quarantine record. So the caller runs its whole load → reconcile → write
	# under `with_lock`, and the property that makes that work is that the body
	# does not run at all when the lock is unavailable.
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not simulate a competing writer for the transaction case")
		return
	# Single-cell ARRAYS, not plain locals. A GDScript lambda captures locals by
	# VALUE, so `ran = true` inside the body would update the closure's own copy
	# and the assertion here would read false whatever the body did — an
	# assertion that cannot fail. Arrays are reference types, so mutating an
	# element is visible to this scope. (Measured: the plain-local form passed
	# case 9 and failed case 10 for exactly this reason.)
	var ran := [false]
	if FileLock.with_lock(PROBE, func() -> void: ran[0] = true):
		_fail("with_lock reported success while another writer held the lock")
		return
	if ran[0]:
		_fail("with_lock ran its body under a foreign lock — a load would read state it may not write")
		return
	DirAccess.remove_absolute(_abs(lock))
	FileLock.clear_for_test()

	# 10. And it releases afterwards, so a transaction cannot wedge the ledger for
	# the stale timeout. Checked with a body that itself writes, since the nested
	# acquire inside save_state is exactly the reentrancy this depends on.
	var observed := [false, false]
	var ran_body := FileLock.with_lock(PROBE, func() -> void:
		observed[0] = DirAccess.dir_exists_absolute(_abs(lock))
		observed[1] = BootRecovery.save_state(PROBE, BootRecovery.fresh_state()).get("ok", false))
	if not ran_body:
		_fail("with_lock could not take a free lock")
		return
	if not observed[0]:
		_fail("the lock was not held while the transaction body ran")
		return
	if not observed[1]:
		_fail("a nested save_state inside with_lock self-deadlocked on its own lock")
		return
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("with_lock leaked the lock — the ledger would wedge until the timeout")
		return

	# 11. Stamping never writes OVER an existing owner file. A process descheduled
	# between its mkdir and its stamp can have that empty lock reclaimed and the
	# slot retaken by another writer; truncating that writer's token would make it
	# abandon a write it owns while recording us as holder of a lock we never
	# created.
	#
	# Driven at the STAMP level on purpose. Going through acquire() cannot reach
	# this guard at all — `mkdir` fails first when the directory exists, so the
	# end-to-end form asserts a branch it never executes and passes with the guard
	# deleted (measured). Same reasoning as vault_lock_test's ownership case.
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not create the lock for the stamp-clobber case")
		return
	var foreign := FileAccess.open(FileLock.owner_path(lock), FileAccess.WRITE)
	if foreign == null:
		_fail("could not stamp the replacement lock")
		return
	foreign.store_string("replacement-1")
	foreign.close()
	if FileLock._stamp_ownership(lock, "resumed-acquirer") != ERR_ALREADY_EXISTS:
		_fail("stamping a lock that already carried another writer's token was not refused")
		return
	var stamp_after := FileAccess.open(FileLock.owner_path(lock), FileAccess.READ)
	if stamp_after == null:
		_fail("the replacement writer's ownership stamp was deleted")
		return
	var stamp_text := stamp_after.get_as_text()
	stamp_after.close()
	if stamp_text != "replacement-1":
		_fail("a resumed acquirer OVERWROTE the replacement writer's stamp: %s" % stamp_text)
		return
	# And it DOES stamp a genuinely empty lock, so case 11 cannot pass by refusing
	# everything.
	FileLock.remove_dir(lock)
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not create an empty lock for the positive stamp case")
		return
	if FileLock._stamp_ownership(lock, "mine-1") != OK:
		_fail("stamping an empty lock was refused")
		return
	FileLock.remove_dir(lock)

	_cleanup()
	OS.set_environment(BootRecovery.RECOVERY_PATH_ENV, "")
	print("TEST PASS — boot recovery's write lock excludes a competing writer, leaves the record byte-intact, never blocks a read, releases on every path, and recovers from an abandoned lock without stealing a live one")
	get_tree().quit(0)


func _fail(message: String) -> void:
	_cleanup()
	OS.set_environment(BootRecovery.RECOVERY_PATH_ENV, "")
	OS.set_environment(FileLock.STALE_ENV, "")
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _exit_tree() -> void:
	_cleanup()


func _abs(path: String) -> String:
	return ProjectSettings.globalize_path(path)


## The recovery file's bytes, or "" when absent. Byte comparison is deliberate: a
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


func _cleanup() -> void:
	FileLock.clear_for_test()
	BootRecovery.clear_refusals_for_test()
	var lock := FileLock.path_for(PROBE)
	FileLock.remove_dir(lock)
	# Reclaim copies carry a per-ATTEMPT suffix, so they cannot be reconstructed by
	# name — scan the directory for the prefix instead.
	var parent := lock.get_base_dir()
	var reclaim_prefix := lock.get_file() + FileLock.RECLAIM_SUFFIX
	for entry: String in DirAccess.get_directories_at(parent):
		if entry.begins_with(reclaim_prefix):
			FileLock.remove_dir(parent.path_join(entry))
	for path: String in [PROBE, PROBE + ".tmp"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(_abs(path))
