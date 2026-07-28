extends Node
## Atomicity of the write lock's OWNERSHIP operations (issue #430).
##
## vault_lock_test and boot_recovery_lock_test pin what the lock does for their
## own callers. This pins the two operations that decide who HOLDS it, both of
## which were check-then-act — the same race the lock itself exists to close, one
## level down:
##
##  - CLAIMING tested for an ownership marker and then created it. Two acquirers
##    reaching that gap could both see no marker and both write their token, and
##    if each then read its own token back before the other overwrote it, two
##    processes entered the same guarded read-modify-write.
##  - RELEASING asked [method FileLock.owns] and then deleted the directory. A
##    holder outliving the stale timeout could read its own token as valid and
##    have the lock reclaimed and retaken before the delete landed — destroying
##    the REPLACEMENT's lock and admitting a third writer.
##
## Both are now decided by a primitive the operating system serializes: `mkdir`
## for the claim, `rename` for the release.
##
## [b]What these cases can and cannot prove.[/b] The final step — that two
## SIMULTANEOUS `mkdir` or `rename` calls resolve to exactly one winner — is the
## operating system's guarantee, not this code's, and no single-process test can
## observe it (the same limit vault_lock_test states about the lock directory).
## What is provable, and what these cases pin, is that the code RESTS on those
## primitives rather than on an earlier observation: the claim's shape is an
## exclusive-create, and the release's verdict comes from bytes read on a private
## copy no other process can name rather than from this process's bookkeeping.
## Each case below is written so that reverting its half of the fix fails it.
##
## Everything runs against a throwaway path, so the player's own save data is
## never touched (no-resets law).
##
## Run: godot --headless --path client res://tests/lock_ownership_test.tscn

const PROBE := "user://lock_ownership_probe.json"


func _ready() -> void:
	_cleanup()
	var lock := FileLock.path_for(PROBE)

	# 1. The ownership claim is a DIRECTORY, and that shape is the whole fix.
	# `mkdir` is the one exclusive-create Godot exposes; a claim made by testing
	# for a file and then opening it is check-then-act by construction, so no
	# assertion about its outcome could distinguish a correct claim from a racy
	# one. The shape is what makes the race unreachable, so the shape is what is
	# pinned — exactly as vault_lock_test pins the lock itself being a directory.
	if not FileLock.acquire(PROBE):
		_fail("could not acquire the lock for the claim-shape case")
		return
	if not DirAccess.dir_exists_absolute(_abs(FileLock.owner_path(lock))):
		_fail("the ownership claim is not a directory — a file claim is check-then-act again")
		return
	if FileAccess.file_exists(FileLock.owner_path(lock)):
		_fail("the ownership claim is a FILE — exclusive-create cannot decide the race")
		return
	if not FileAccess.file_exists(FileLock.token_path(lock)):
		_fail("the claim's winner did not write its token")
		return
	if not FileLock.owns(PROBE):
		_fail("a freshly acquired lock did not read as owned by this process")
		return

	# 2. A lock whose claim is taken is NON-EMPTY, which is what makes a
	# reclaimer's restore fail safely instead of renaming over a live holder.
	# Measured: renaming onto an empty directory succeeds.
	var rival := lock + ".rival"
	if DirAccess.make_dir_absolute(_abs(rival)) != OK:
		_fail("could not build a rival directory for the non-empty case")
		return
	if DirAccess.rename_absolute(_abs(rival), _abs(lock)) == OK:
		_fail("a claimed lock was RENAMED OVER — a live holder can be displaced")
		return
	DirAccess.remove_absolute(_abs(rival))
	FileLock.release(PROBE)

	# 3. The claim refuses a second taker and leaves the winner's token intact.
	# Driven at the claim level: acquire() cannot reach it, because `mkdir` on the
	# LOCK fails first when the directory exists, so an end-to-end case asserts a
	# branch it never executes (measured on #422).
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not create a bare lock for the second-taker case")
		return
	if FileLock._claim_ownership(lock, "winner-1") != OK:
		_fail("the first claim on an unclaimed lock was refused")
		return
	if FileLock._claim_ownership(lock, "loser-2") != ERR_ALREADY_EXISTS:
		_fail("a SECOND claim succeeded — two writers would both believe they hold the lock")
		return
	if FileLock._recorded_token(lock) != "winner-1":
		_fail("the losing claim overwrote the winner's token: %s" % FileLock._recorded_token(lock))
		return
	FileLock.remove_dir(lock)

	# 4. Cross-version, the claim fails CLOSED in both directions. A build predating
	# this shape writes `owner` as a FILE; this one makes it a DIRECTORY. Neither
	# may read the other's claim as its own, or two writers proceed against one
	# file — the mismatch must cost a deferred write, not a lost update.
	#
	# 4a. This build meeting an OLD claim: `mkdir` over an existing file is refused,
	# and the token beneath it cannot be read, so owns() is false either way.
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not create a lock for the old-format case")
		return
	var legacy := FileAccess.open(FileLock.owner_path(lock), FileAccess.WRITE)
	if legacy == null:
		_fail("could not write an old-format ownership stamp")
		return
	legacy.store_string("old-build-1")
	legacy.close()
	if FileLock._claim_ownership(lock, "new-build-1") != ERR_ALREADY_EXISTS:
		_fail("this build CLAIMED a lock an older build already held")
		return
	if FileLock._recorded_token(lock) != "":
		_fail("an old-format stamp was read as a token by this build")
		return
	if FileLock.acquire(PROBE):
		_fail("acquire() took a lock an older build already held")
		return
	DirAccess.remove_absolute(_abs(FileLock.owner_path(lock)))
	DirAccess.remove_absolute(_abs(lock))
	FileLock.clear_for_test()

	# 4b. An OLD build meeting THIS claim. The old code's two reads are replayed
	# verbatim — file_exists() to decide whether a stamp is present, and
	# FileAccess.open() to write or read it. Both must come back empty-handed
	# against a directory claim, or the old build would stamp over a live holder.
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not create a lock for the new-format case")
		return
	if FileLock._claim_ownership(lock, "new-build-2") != OK:
		_fail("could not take the claim for the new-format case")
		return
	if FileAccess.file_exists(FileLock.owner_path(lock)):
		_fail("an old build would see this claim as a stamp FILE it may overwrite")
		return
	if FileAccess.open(FileLock.owner_path(lock), FileAccess.WRITE) != null:
		_fail("an old build could OVERWRITE this build's claim — both would hold the lock")
		return
	if FileAccess.open(FileLock.owner_path(lock), FileAccess.READ) != null:
		_fail("an old build could read this claim as its own ownership stamp")
		return
	if FileLock._recorded_token(lock) != "new-build-2":
		_fail("the claim's own token did not survive the old-build reads")
		return
	FileLock.remove_dir(lock)

	# 5. RELEASE decides from the bytes on a PRIVATE copy, not from this process's
	# bookkeeping. This is the case that separates the fix from what it replaced:
	# the old release asked owns(), which reads the in-process token table, so with
	# that table cleared it returned false and the lock was left behind. Reading
	# the token off the renamed copy instead is what makes the verdict describe the
	# directory being deleted rather than something observed earlier.
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not create a lock for the private-verify case")
		return
	if FileLock._claim_ownership(lock, "holder-9") != OK:
		_fail("could not claim the lock for the private-verify case")
		return
	FileLock.clear_for_test()
	FileLock._release_exclusively(lock, "holder-9")
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("release did not remove a lock carrying OUR token — the verdict came from bookkeeping")
		return
	if not _private_copies(lock).is_empty():
		_fail("release left its private copy behind: %s" % ", ".join(_private_copies(lock)))
		return

	# 6. And it REFUSES when the token is not ours — restoring the lock rather than
	# deleting a directory this process does not hold. Without this case 5 could
	# pass by deleting unconditionally, which is the very bug being closed.
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not create a lock for the foreign-release case")
		return
	if FileLock._claim_ownership(lock, "someone-else-3") != OK:
		_fail("could not claim the lock for the foreign-release case")
		return
	FileLock._release_exclusively(lock, "not-ours-4")
	if not DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("release DELETED a lock owned by someone else — a third writer could acquire mid-write")
		return
	if FileLock._recorded_token(lock) != "someone-else-3":
		_fail("a refused release damaged the holder's token: %s" % FileLock._recorded_token(lock))
		return
	if not _private_copies(lock).is_empty():
		_fail("a refused release left its private copy behind — it would shadow the real lock")
		return
	FileLock.remove_dir(lock)

	# 7. Releasing a lock that is already GONE creates nothing and deletes nothing.
	# The rename fails, and there is no path on which a missing lock may be
	# reconstructed at the shared name — that would hand a lock to a process that
	# does not hold one.
	FileLock._release_exclusively(lock, "vanished-5")
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("releasing an absent lock CREATED one")
		return
	if not _private_copies(lock).is_empty():
		_fail("releasing an absent lock left a private copy behind")
		return

	# 8. The full release path still balances a real acquire, so cases 5-7 cannot
	# pass against a release() that never reaches _release_exclusively() at all.
	if not FileLock.acquire(PROBE):
		_fail("could not acquire the lock for the end-to-end release case")
		return
	FileLock.release(PROBE)
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("releasing a lock we still own left it behind")
		return
	if not _private_copies(lock).is_empty():
		_fail("a balanced acquire/release left a private copy behind")
		return

	_cleanup()
	print("TEST PASS — ownership is claimed by exclusive-create and released on a privately-renamed copy, refusing a second claimant and a foreign release, and failing closed against both stamp formats")
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


## Every leftover reclaim/release copy of `lock`. Both carry a per-ATTEMPT suffix
## and so cannot be reconstructed by name — the directory is scanned by PREFIX
## instead, which is also what stops these assertions passing vacuously.
func _private_copies(lock: String) -> Array[String]:
	var found: Array[String] = []
	var parent := lock.get_base_dir()
	for entry: String in DirAccess.get_directories_at(parent):
		for suffix: String in [FileLock.RECLAIM_SUFFIX, FileLock.RELEASE_SUFFIX]:
			if entry.begins_with(lock.get_file() + suffix):
				found.append(parent.path_join(entry))
	return found


func _cleanup() -> void:
	FileLock.clear_for_test()
	var lock := FileLock.path_for(PROBE)
	FileLock.remove_dir(lock)
	# An old-format stamp is a FILE at the claim's path; remove_dir() unlinks the
	# claim as a directory, so clear both shapes or a failed case leaks into the next.
	DirAccess.remove_absolute(_abs(FileLock.owner_path(lock)))
	DirAccess.remove_absolute(_abs(lock))
	DirAccess.remove_absolute(_abs(lock + ".rival"))
	for dead: String in _private_copies(lock):
		FileLock.remove_dir(dead)
	if FileAccess.file_exists(PROBE):
		DirAccess.remove_absolute(_abs(PROBE))
