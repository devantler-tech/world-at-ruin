extends Node
## Contention test for the save vault's cross-process write lock (issue #262).
##
## save_vault_test pins the vault's single-writer behaviour; this pins what
## happens when there is MORE than one writer. The race it closes is
## check-then-act across a read-modify-write: two differently-versioned clients
## sharing one user:// directory each read the same document, each merge their
## own change, and the slower rename silently discards the faster writer's
## progression. Under the no-resets law that loss is permanent.
##
## A competing process is simulated by creating the lock directory directly.
## That is not an approximation of contention — the lock IS a directory, so a
## directory created by anything is byte-for-byte what a real competing client
## leaves behind, and the code under test cannot tell the difference. The one
## thing left unproven is that two simultaneous mkdir calls resolve to a single
## winner, which is the operating system's atomicity guarantee rather than ours.
##
## What is pinned:
##  1. The lock is a DIRECTORY, and exclusive-create is what decides the race.
##  2. A held lock makes a write refuse — and leave the vault BYTE-INTACT.
##  3. Refusing is session-only degradation, never a boot blocker: the vault
##     still reads while another writer holds the lock.
##  4. The lock is released after a successful write, and after a failed one —
##     a leaked lock would wedge the vault for the whole stale timeout.
##  5. Reentrancy: persist_*() holds the lock across its whole read-modify-write
##     and still calls save_to(), which takes the same lock. This must not
##     self-deadlock.
##  6. Reclamation of an abandoned lock NEVER acquires in the same pass: it frees
##     the slot and refuses, and the next attempt acquires it. Reclaim-then-create
##     would let two processes each recreate the lock over the other and both
##     proceed as owners.
##  7. A live lock is never reclaimed, and a stamped foreign lock excludes a write.
##  8. The ownership stamp: a holder can prove the lock is still its own, and a
##     write refuses once the stamp is no longer ours instead of replacing the
##     vault behind the back of whoever holds it now.
##  9. The timeout seam refuses malformed and negative values, so the shipped
##     window can never be shortened by a bad environment variable.
##
## Everything runs against a throwaway path via WAR_VAULT_PATH, so the player's
## own user://vault.json is never touched (no-resets law).
##
## Run: godot --headless --path client res://tests/vault_lock_test.tscn

const PROBE := "user://vault_lock_probe.json"


func _ready() -> void:
	_cleanup()
	OS.set_environment(SaveVault.VAULT_PATH_ENV, PROBE)

	# 1. The lock is a directory beside the vault. `mkdir` is the only atomic
	# exclusive-create Godot exposes; a plain file open would be check-then-act
	# again, so the SHAPE is load-bearing, not an implementation detail.
	var lock := FileLock.path_for(PROBE)
	if lock != PROBE + FileLock.SUFFIX:
		_fail("lock_path() did not sit beside the vault: %s" % lock)
		return
	if not SaveVault.persist_attunement(SaveVault.SHRINE_WARDENS):
		_fail("the first attunement did not persist")
		return
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("the lock directory survived a successful write — it would wedge the vault")
		return

	var baseline := _read(PROBE)
	if baseline.is_empty():
		_fail("the probe vault is empty after a successful attunement")
		return

	# 2. A competing writer holds the lock: the write must refuse rather than
	# interleave, and must not touch the file on its way out.
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not simulate a competing writer by taking the lock")
		return
	if SaveVault.persist_discoveries([SaveVault.DISCOVERY_STARTER_CAVE]):
		_fail("a discovery write SUCCEEDED while another writer held the lock — the race is open")
		return
	if _read(PROBE) != baseline:
		_fail("a refused write still modified the vault — it must be byte-intact")
		return
	if SaveVault.save_to(PROBE, SaveVault.empty()):
		_fail("a direct save_to() SUCCEEDED while another writer held the lock")
		return
	if _read(PROBE) != baseline:
		_fail("a refused direct save_to() still modified the vault")
		return

	# 3. Contention degrades to session-only; it never blocks a boot. Reading is
	# unaffected, which is what keeps a locked vault from stranding a player.
	var readable = SaveVault.load_saved()
	if readable is not Dictionary:
		_fail("the vault became unreadable while another writer held the lock — that blocks a boot")
		return
	if not SaveVault.is_attuned(readable, SaveVault.SHRINE_WARDENS):
		_fail("the readable vault lost its attunement under contention")
		return

	# 4. Release the competing hold; writes resume. This proves the refusal above
	# was the LOCK talking and not some unrelated failure that would have
	# refused anyway — without this the whole case could pass vacuously.
	DirAccess.remove_absolute(_abs(lock))
	if not SaveVault.persist_discoveries([SaveVault.DISCOVERY_STARTER_CAVE]):
		_fail("the write did not resume once the competing writer released the lock")
		return
	var after_release := _read(PROBE)
	if after_release == baseline:
		_fail("the resumed write did not actually change the vault")
		return
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("the lock leaked after the resumed write")
		return

	# 5. A FAILED write must release too. An invalid document is refused by
	# validate() deep inside the locked section, which is exactly the kind of
	# early return that leaks a lock when release is not on a single path.
	if SaveVault.save_to(PROBE, { "version": 1, "bogus_field": true }):
		_fail("save_to() accepted an invalid document")
		return
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("the lock LEAKED after a refused write — the vault would wedge until the timeout")
		return

	# 6. Reentrancy: persist_*() takes the lock, then calls save_to(), which
	# takes the same lock. If that nested acquire collided with our own
	# directory the write would refuse itself — a deadlock that is
	# indistinguishable from healthy contention, so it is pinned explicitly.
	if not SaveVault.persist_attunement(SaveVault.SHRINE_WARDENS):
		_fail("a reentrant persist -> save_to self-deadlocked on its own lock")
		return
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("the reentrant write left the lock behind — release unbalanced its acquire")
		return

	# 7. Stale recovery: a crashed process leaves a lock nobody will ever
	# release. With the timeout seamed to 0 the very next write may break it, so
	# a crash cannot wedge the vault forever.
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not simulate a crashed process's abandoned lock")
		return
	OS.set_environment(FileLock.STALE_ENV, "0")
	if FileLock.stale_seconds() != 0:
		_fail("the stale-timeout seam did not honour an explicit 0")
		return
	# A reclaiming pass deliberately does NOT acquire. Reclaim-then-acquire in one
	# pass is exactly what makes remove-then-create unsound: two processes find the
	# same abandoned lock, the first recreates it, the second removes THAT live lock
	# and recreates it again, and both believe they own the write. Keeping
	# acquisition to the single atomic mkdir means only an absent slot grants it.
	#
	# Asserted at the ACQUIRE level on purpose. Going through persist_attunement()
	# here is vacuous: a pass that wrongly acquires still fails further down on the
	# ownership guard, so the end-to-end call returns false either way and the
	# assertion would pass while the defect it names is present (measured — this
	# exact ablation slipped through the end-to-end form).
	if FileLock.acquire(PROBE):
		_fail("a reclaiming pass ACQUIRED the lock — reclaim and acquire must not share a pass")
		return
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("the abandoned lock was not reclaimed — a crash would wedge the vault permanently")
		return
	# The slot is free now, so the NEXT attempt acquires it cleanly. Recovery is
	# therefore one deferred write, not a permanently unwritable vault.
	if not SaveVault.persist_attunement(SaveVault.SHRINE_WARDENS):
		_fail("the write did not resume after the abandoned lock was reclaimed")
		return
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("the resumed write left the lock behind")
		return

	# 8. The seam fails SAFE. A malformed or negative value must fall back to the
	# shipped window rather than shorten it — a 0-second window in the field
	# would let any live writer be robbed mid-write, which is the one loss this
	# lock exists to prevent.
	for bad: String in ["", "-1", "abc", "3.5"]:
		OS.set_environment(FileLock.STALE_ENV, bad)
		if FileLock.stale_seconds() != FileLock.STALE_SECONDS:
			_fail("the stale seam accepted %s instead of falling back to the shipped window" % (
				"an empty value" if bad.is_empty() else "'%s'" % bad))
			return
	OS.set_environment(FileLock.STALE_ENV, "")

	# 9. A live lock is NOT stolen, re-checked END TO END now that the seam has
	# been exercised and reset. Case 2 already proves freshness is respected, and
	# ablating the staleness rule fails there first — so this is a restatement
	# rather than a uniquely-caught bug. It is kept because it is the only case
	# that exercises the restored window through real writes rather than through
	# lock_stale_seconds() alone, which is what case 8 checks.
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not take the lock for the freshness case")
		return
	if SaveVault.persist_attunement(SaveVault.SHRINE_WARDENS):
		_fail("a FRESH lock was broken — a live writer can be robbed mid-write")
		return
	if not DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("a FRESH lock was RECLAIMED — a live writer's lock must survive an attempt")
		return
	DirAccess.remove_absolute(_abs(lock))

	# 10. A STAMPED foreign lock refuses too. Cases 2 and 9 hold a bare directory,
	# which is what a holder looks like only for the instant between creating the
	# lock and stamping it; a settled holder's lock carries an ownership stamp, and
	# that is the shape a reclaimer's restore relies on to fail safely rather than
	# rename over a live lock.
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not take the lock for the stamped-holder case")
		return
	var stamp := FileAccess.open(lock + "/" + FileLock.OWNER_FILE, FileAccess.WRITE)
	if stamp == null:
		_fail("could not write a foreign ownership stamp")
		return
	stamp.store_string("999999-1")
	stamp.close()
	if SaveVault.persist_attunement(SaveVault.SHRINE_WARDENS):
		_fail("a stamped foreign lock did not exclude a write")
		return
	if _read(PROBE) == "":
		_fail("the vault vanished while a stamped foreign lock was held")
		return
	DirAccess.remove_absolute(_abs(lock + "/" + FileLock.OWNER_FILE))
	DirAccess.remove_absolute(_abs(lock))

	# 11. The ownership guard, driven directly. A holder stamps the lock and can
	# prove it still owns it; a stamp that has been replaced reads as NOT ours, so
	# the write aborts instead of replacing the vault while another process
	# legitimately holds the lock. That interleaving needs two real processes to
	# arise, so the guard is exercised at its own level rather than left as an
	# untested claim.
	if not FileLock.acquire(PROBE):
		_fail("could not acquire the lock for the ownership case")
		return
	if not FileLock.owns(PROBE):
		_fail("a freshly acquired lock did not read as owned by this process")
		return
	if not FileAccess.file_exists(lock + "/" + FileLock.OWNER_FILE):
		_fail("acquiring the lock did not stamp ownership into it")
		return
	var hijack := FileAccess.open(lock + "/" + FileLock.OWNER_FILE, FileAccess.WRITE)
	if hijack == null:
		_fail("could not overwrite the ownership stamp")
		return
	hijack.store_string("999999-2")
	hijack.close()
	if FileLock.owns(PROBE):
		_fail("a REPLACED ownership stamp still read as ours — a stolen lock would not be detected")
		return
	# And a write refuses while the lock is no longer ours, rather than replacing
	# the vault behind the back of whoever holds it now.
	var before_hijack := _read(PROBE)
	if SaveVault._save_to_locked(PROBE, SaveVault.empty()):
		_fail("a write proceeded while the lock was no longer ours")
		return
	if _read(PROBE) != before_hijack:
		_fail("a write that lost the lock still modified the vault")
		return
	# 12. Releasing a lock that is NO LONGER OURS must not delete it. A writer
	# suspended past the stale timeout can have its lock reclaimed and the freed
	# path taken by someone else; an unconditional release would then destroy THAT
	# writer's lock and let a third process acquire mid-write — the same
	# lost-update race, entered through the release path instead of the acquire
	# path. The hijacked stamp from case 11 is still in place, so this is exactly
	# the "someone else holds it now" state.
	FileLock.release(PROBE)
	if not DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("releasing a lock owned by someone else DELETED it — a third writer could acquire mid-write")
		return
	if not FileAccess.file_exists(lock + "/" + FileLock.OWNER_FILE):
		_fail("releasing a foreign-held lock stripped its ownership stamp")
		return
	# That lock was deliberately left behind, so free the slot by hand before the
	# next case — clear_locks_for_test() cannot, having no record of a lock this
	# process no longer holds.
	DirAccess.remove_absolute(_abs(lock + "/" + FileLock.OWNER_FILE))
	DirAccess.remove_absolute(_abs(lock))
	FileLock.clear_for_test()

	# 13. A releasing holder that STILL owns its lock does remove it — otherwise
	# case 12 could pass by never releasing anything at all.
	if not FileLock.acquire(PROBE):
		_fail("could not acquire the lock for the clean-release case")
		return
	FileLock.release(PROBE)
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("releasing a lock we still own left it behind")
		return

	# 14. A reclaimer that died between the rename and the delete leaves its
	# private copy behind, stamped and therefore non-empty. If reclaim targets were
	# keyed on the pid alone, the next process to inherit that pid would aim every
	# attempt at that surviving directory, the rename would always fail, and stale
	# recovery would be dead for the whole session. Build exactly that orphan and
	# prove reclamation still works around it.
	var orphan := "%s%s%d" % [lock, FileLock.RECLAIM_SUFFIX, OS.get_process_id()]
	if DirAccess.make_dir_absolute(_abs(orphan)) != OK:
		_fail("could not simulate a crashed reclaimer's leftover copy")
		return
	var orphan_stamp := FileAccess.open(orphan + "/" + FileLock.OWNER_FILE, FileAccess.WRITE)
	if orphan_stamp == null:
		_fail("could not stamp the orphaned reclaim copy")
		return
	orphan_stamp.store_string("dead-1")
	orphan_stamp.close()
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not simulate an abandoned lock alongside the orphan")
		return
	OS.set_environment(FileLock.STALE_ENV, "0")
	if FileLock.acquire(PROBE):
		_fail("a reclaiming pass ACQUIRED while an orphaned reclaim copy existed")
		return
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("a crashed reclaimer's leftover copy blocked all future stale recovery")
		return
	OS.set_environment(FileLock.STALE_ENV, "")

	_cleanup()
	OS.set_environment(SaveVault.VAULT_PATH_ENV, "")
	print("TEST PASS — vault write lock excludes a competing writer, reclaims without acquiring, releases on every path, refuses once the lock is no longer ours, and is never stolen while live")
	get_tree().quit(0)


func _fail(message: String) -> void:
	_cleanup()
	OS.set_environment(SaveVault.VAULT_PATH_ENV, "")
	OS.set_environment(FileLock.STALE_ENV, "")
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _exit_tree() -> void:
	_cleanup()


func _abs(path: String) -> String:
	return ProjectSettings.globalize_path(path)


## The vault's bytes, or "" when absent. Byte comparison is deliberate: a
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
	SaveVault.clear_refusals_for_test()
	var lock := FileLock.path_for(PROBE)
	DirAccess.remove_absolute(_abs(lock + "/" + FileLock.OWNER_FILE))
	DirAccess.remove_absolute(_abs(lock))
	# Reclaim copies carry a per-ATTEMPT suffix, so they cannot be reconstructed by
	# name — scan the directory for the prefix instead.
	var parent := lock.get_base_dir()
	var reclaim_prefix := lock.get_file() + FileLock.RECLAIM_SUFFIX
	for entry: String in DirAccess.get_directories_at(parent):
		if entry.begins_with(reclaim_prefix):
			var dead := parent.path_join(entry)
			DirAccess.remove_absolute(_abs(dead + "/" + FileLock.OWNER_FILE))
			DirAccess.remove_absolute(_abs(dead))
	for path: String in [PROBE, PROBE + ".tmp"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(_abs(path))
