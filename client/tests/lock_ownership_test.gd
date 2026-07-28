extends Node
## Atomicity of the write lock's OWNERSHIP operations (issue #430).
##
## vault_lock_test and boot_recovery_lock_test pin what the lock does for its
## callers. This pins the two operations that decide who HOLDS it, both of which
## were check-then-act — the same race the lock exists to close, one level down:
##
##  - ACQUIRING created the lock empty and stamped it afterwards. An acquirer
##    descheduled in that gap past the stale timeout had its half-built lock
##    reclaimed and the slot retaken, and then stamped BY PATH — over the new
##    holder's token, recording itself as owner of a lock it never created.
##  - RELEASING asked [method FileLock.owns] and then deleted the directory. A
##    holder outliving the timeout could read its own token as valid and have the
##    lock reclaimed and retaken before the delete landed, destroying the
##    REPLACEMENT's lock and admitting a third writer.
##
## Both are now single steps the operating system settles: the lock is built
## complete under a private name and `rename`d into place, and the release
## `rename`s the STAMP aside — never the lock — to verify it.
##
## [b]What these cases can and cannot prove.[/b] That two SIMULTANEOUS renames
## resolve to one winner is the operating system's guarantee, not this code's, and
## no single-process test can observe it — the same limit vault_lock_test states
## about the lock directory. What IS provable, and what these cases pin, is that
## the code rests on those primitives rather than on an earlier observation: that
## a lock is never visible half-built, that a release moves the stamp and leaves
## the lock in place, and that its verdict comes from bytes rather than from this
## process's bookkeeping. Each case is written so that reverting its half of the
## fix fails it.
##
## Everything runs against a throwaway path, so the player's own save data is
## never touched (no-resets law).
##
## Run: godot --headless --path client res://tests/lock_ownership_test.tscn

const PROBE := "user://lock_ownership_probe.json"


func _ready() -> void:
	_cleanup()
	var lock := FileLock.path_for(PROBE)

	# 1. A lock is never visible half-built. The moment it exists at the shared
	# path it already carries its stamp, which is what stops a reclaimer treating a
	# live acquirer's lock as abandoned and what stops a resumed acquirer stamping
	# over a replacement holder. Building in place cannot give this: there the lock
	# is empty for as long as the acquirer takes to write the stamp.
	if not FileLock.acquire(PROBE):
		_fail("could not acquire the lock for the publication case")
		return
	if not DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("acquiring did not put a lock at the shared path")
		return
	if not FileAccess.file_exists(FileLock.owner_path(lock)):
		_fail("the published lock carries no ownership stamp — it was built in place")
		return
	if not FileLock.owns(PROBE):
		_fail("a freshly acquired lock did not read as owned by this process")
		return
	if not _private_copies(lock).is_empty():
		_fail("acquiring left its staging directory behind: %s" % ", ".join(_private_copies(lock)))
		return
	# 1b. And acquire() is WIRED to publication — asserted directly, because the end
	# state cannot carry it. A lock built IN PLACE also ends up stamped at the
	# shared path, so every assertion above passes either way; the two differ only
	# in whether a half-built lock was ever visible, which one process cannot see.
	var staged := FileLock._last_publish_staging
	if staged.is_empty():
		_fail("acquire() built the lock IN PLACE — it was visible half-built")
		return
	if not staged.begins_with(lock + FileLock.STAGING_SUFFIX):
		_fail("acquire() staged the lock at an unexpected path: %s" % staged)
		return
	if DirAccess.dir_exists_absolute(_abs(staged)):
		_fail("the staging directory outlived the publish: %s" % staged)
		return

	# 2. A published lock is NON-EMPTY, so it cannot be renamed over. This is what
	# a reclaimer's restore relies on to fail safely rather than displace a live
	# holder, and what stops a rival publishing over one. Measured: renaming onto
	# an EMPTY directory succeeds, which is exactly why the stamp ships with the
	# lock rather than after it.
	var rival := lock + ".rival"
	if DirAccess.make_dir_absolute(_abs(rival)) != OK:
		_fail("could not build a rival directory for the non-empty case")
		return
	if DirAccess.rename_absolute(_abs(rival), _abs(lock)) == OK:
		_fail("a published lock was RENAMED OVER — a live holder can be displaced")
		return
	DirAccess.remove_absolute(_abs(rival))
	FileLock.release(PROBE)

	# 3. A second publisher LOSES and changes nothing. Driven at the publish level:
	# acquire() refuses earlier for its own reasons, so an end-to-end case asserts a
	# branch it never executes and would pass with this guard gone (measured on
	# #422, and the reason #430 exists at all).
	if FileLock._publish_lock(lock, "winner-1") != OK:
		_fail("publishing onto a free slot was refused")
		return
	if FileLock._publish_lock(lock, "loser-2") != ERR_ALREADY_EXISTS:
		_fail("a SECOND publish succeeded — two writers would both believe they hold the lock")
		return
	if FileLock._recorded_token(lock) != "winner-1":
		_fail("the losing publish overwrote the winner's token: %s" % FileLock._recorded_token(lock))
		return
	if not _private_copies(lock).is_empty():
		_fail("the losing publish left its staging directory behind")
		return
	FileLock.remove_dir(lock)

	# 4. A retained OLDER build and this one still exclude each other. The on-disk
	# shape is deliberately unchanged, so this is not a migration — but it is the
	# property that would break silently if a later change moved the stamp, so it is
	# pinned rather than assumed.
	#
	# 4a. An older build's plain `mkdir` acquire is refused by a published lock.
	if FileLock._publish_lock(lock, "current-build-1") != OK:
		_fail("could not publish a lock for the older-build case")
		return
	if DirAccess.make_dir_absolute(_abs(lock)) != ERR_ALREADY_EXISTS:
		_fail("an older build's mkdir did not see this build's lock")
		return
	FileLock.remove_dir(lock)

	# 4b. And an EMPTY lock still excludes this build, which `rename` alone would
	# not give: it fails onto a non-empty directory but REPLACES an empty one
	# (measured). An empty lock is what an older build leaves while it stamps, and
	# it is also what every caller's own contention tests construct, so publishing
	# must refuse it rather than move it aside.
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not simulate an older build's half-built lock")
		return
	if FileLock._publish_lock(lock, "current-build-2") != ERR_ALREADY_EXISTS:
		_fail("publishing DISPLACED an empty lock — a bare lock stopped excluding a writer")
		return
	if FileAccess.file_exists(FileLock.owner_path(lock)):
		_fail("a refused publish stamped the older build's lock anyway")
		return
	if FileLock.acquire(PROBE):
		_fail("acquire() took a slot an older build was still building in")
		return
	if not _private_copies(lock).is_empty():
		_fail("the refused publish left its staging directory behind")
		return
	DirAccess.remove_absolute(_abs(lock))
	FileLock.clear_for_test()

	# 5. RELEASE MOVES THE STAMP, NEVER THE LOCK. Taking the whole lock aside would
	# empty the shared slot for the length of the check — and a lock that is briefly
	# absent is one a third process can acquire, so a stale former holder releasing
	# after its lock had been retaken would vacate the CURRENT holder's slot, admit a
	# third writer, then delete the displaced lock. Asserted structurally, because
	# that interleaving needs three processes: the seam must name a path under the
	# STAMP, not under the lock.
	if FileLock._publish_lock(lock, "holder-9") != OK:
		_fail("could not publish the lock for the stamp-aside case")
		return
	FileLock.clear_for_test()
	FileLock._release_exclusively(lock, "holder-9")
	var moved := FileLock._last_release_private
	if moved.is_empty():
		_fail("release moved nothing aside — it deleted the shared directory outright")
		return
	if not moved.begins_with(FileLock.owner_path(lock) + FileLock.RELEASE_SUFFIX):
		_fail("release moved the LOCK aside rather than its stamp (%s) — the slot was vacated" % moved)
		return
	# 5b. And it decides from the bytes it moved, not from this process's
	# bookkeeping: `clear_for_test()` above emptied the token table, so a release
	# that consulted owns() would have read NOT ours and left the lock behind.
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("release did not remove a lock carrying OUR token — the verdict came from bookkeeping")
		return
	if not _private_copies(lock).is_empty():
		_fail("release left its moved stamp behind: %s" % ", ".join(_private_copies(lock)))
		return

	# 6. And it REFUSES when the token is not ours, restoring the stamp rather than
	# deleting a lock this process does not hold. Without this, case 5 could pass by
	# deleting unconditionally — the very bug being closed.
	if FileLock._publish_lock(lock, "someone-else-3") != OK:
		_fail("could not publish the lock for the foreign-release case")
		return
	FileLock._release_exclusively(lock, "not-ours-4")
	if not DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("release DELETED a lock owned by someone else — a third writer could acquire mid-write")
		return
	if FileLock._recorded_token(lock) != "someone-else-3":
		_fail("a refused release damaged the holder's stamp: %s" % FileLock._recorded_token(lock))
		return
	if not _private_copies(lock).is_empty():
		_fail("a refused release left the moved stamp behind — it would shadow the real one")
		return
	FileLock.remove_dir(lock)

	# 7. Releasing when there is no stamp to move creates nothing and deletes
	# nothing. A missing stamp means the lock was already released or reclaimed, and
	# reconstructing one would hand ownership to a process that does not hold it.
	FileLock._release_exclusively(lock, "vanished-5")
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("releasing an absent lock CREATED one")
		return
	if not _private_copies(lock).is_empty():
		_fail("releasing an absent lock left a private copy behind")
		return

	# 8. release() is WIRED to that path — asserted directly, because no outcome can
	# carry it. Cases 5-7 drive _release_exclusively() themselves, and a plain
	# acquire/release only shows that an owned lock ends up deleted, which a release
	# that checks ownership and then deletes the shared directory does too:
	# single-threaded the two compare the same bytes and differ only when another
	# process substitutes the directory in between. Measured — with release()
	# reverted to check-then-act, every other case here still passed.
	if not FileLock.acquire(PROBE):
		_fail("could not acquire the lock for the release-wiring case")
		return
	FileLock.release(PROBE)
	var used := FileLock._last_release_private
	if used.is_empty():
		_fail("release() never moved the stamp aside — it deleted the SHARED directory")
		return
	if not used.begins_with(FileLock.owner_path(lock) + FileLock.RELEASE_SUFFIX):
		_fail("release() moved an unexpected path aside: %s" % used)
		return
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("releasing a lock we still own left it behind")
		return
	if not _private_copies(lock).is_empty():
		_fail("a balanced acquire/release left a private copy behind")
		return

	_cleanup()
	print("TEST PASS — the lock is published whole so it is never half-built, a second publisher loses without touching it, and release moves only the stamp so the slot is never vacated")
	get_tree().quit(0)


func _fail(message: String) -> void:
	_cleanup()
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _exit_tree() -> void:
	_cleanup()


func _abs(path: String) -> String:
	return ProjectSettings.globalize_path(path)


## Every leftover staging/reclaim/release copy belonging to `lock`. All three
## carry a per-ATTEMPT suffix and so cannot be reconstructed by name — the
## directory is scanned by PREFIX instead, which is also what stops these
## assertions passing vacuously. The release suffix is applied to the STAMP, which
## lives inside the lock, so it is matched separately.
func _private_copies(lock: String) -> Array[String]:
	var found: Array[String] = []
	var parent := lock.get_base_dir()
	for entry: String in DirAccess.get_directories_at(parent):
		for suffix: String in [FileLock.STAGING_SUFFIX, FileLock.RECLAIM_SUFFIX]:
			if entry.begins_with(lock.get_file() + suffix):
				found.append(parent.path_join(entry))
	if DirAccess.dir_exists_absolute(_abs(lock)):
		for entry: String in DirAccess.get_files_at(lock):
			if entry.begins_with(FileLock.OWNER_FILE + FileLock.RELEASE_SUFFIX):
				found.append(lock.path_join(entry))
	return found


func _cleanup() -> void:
	FileLock.clear_for_test()
	var lock := FileLock.path_for(PROBE)
	for stray: String in _private_copies(lock):
		DirAccess.remove_absolute(_abs(stray))
		FileLock.remove_dir(stray)
	FileLock.remove_dir(lock)
	DirAccess.remove_absolute(_abs(lock + ".rival"))
	DirAccess.remove_absolute(_abs(lock))
	if FileAccess.file_exists(PROBE):
		DirAccess.remove_absolute(_abs(PROBE))
