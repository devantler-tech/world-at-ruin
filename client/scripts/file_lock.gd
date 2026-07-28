class_name FileLock
## A cross-process write lock for a single persisted file.
##
## Every persisted contract in this client is a read-modify-write: load the
## document, merge one change, replace the file. Two processes doing that against
## the same path interleave — both read the same bytes, both merge their own
## change, and the slower rename silently discards the faster writer's record.
## Under the no-resets law that loss is permanent, so the write is taken under
## this lock.
##
## The lock is a DIRECTORY beside the file it guards, because
## [method DirAccess.make_dir_absolute] is `mkdir` — the one exclusive-create
## Godot exposes that fails with `ERR_ALREADY_EXISTS` rather than succeeding when
## the path is taken. A lock made from a file open would be check-then-act again,
## which is the very race being closed, so the SHAPE is load-bearing rather than
## an implementation detail.
##
## [b]Ownership is settled in one step at both ends.[/b] Holding the lock is a
## single property, established once on the way in and given up once on the way
## out — never by testing a marker and then acting on what the test said, which is
## the same race one level down:
##  - ACQUIRING builds the whole lock, stamp included, under a private name and
##    `rename`s it into place, so the shared path only ever holds a finished lock
##    and a slow acquirer can never write into someone else's (see
##    [method _publish_lock]);
##  - RELEASING renames the STAMP — not the lock — to a private name and verifies
##    the token there before deleting, so the lock never vacates its slot and no
##    third process can slip in while ownership is being decided (see
##    [method _release_exclusively]).
## Both use the technique [method _reclaim_if_abandoned] already relied on, applied
## to the two operations that previously did not.
##
## [b]Scope the guarantee precisely.[/b] A lock only excludes writers that TAKE
## it. It holds between lock-aware builds; it does nothing about:
##  - a build from before the lock existed, which knows nothing of this directory
##    and walks straight through it;
##  - a foreign writer — cloud sync, a backup agent, the player editing the file
##    by hand — which was never going to consult it.
## For both, each caller's own pre-rename recheck is what remains, and it narrows
## the window to the rename rather than closing it. So this lock removes lost
## updates between lock-aware builds now, and becomes a general guarantee only
## once every writer that can reach the file takes it.
##
## Failing to acquire is not an error the player should feel: callers degrade to
## session-only, which is this client's standing answer to doubt about persisted
## state. Contention must never block a boot.
##
## [b]This lock is CROSS-PROCESS, not cross-thread — call it from the main thread
## only.[/b] Exclusion between processes rests on `mkdir`, which is atomic for
## every caller; the per-process bookkeeping beside it does not share that
## property. [code]_held[/code] and [code]_tokens[/code] are Dictionaries that
## gain and lose keys on every acquire and release, and Godot does not permit one
## to be resized from one GDScript thread while another touches it — the result
## is corruption rather than a lost update. Every caller today (character store,
## progression vault, boot recovery) writes from the main thread, so the shipped
## contract is main-thread-only and the bookkeeping needs no Mutex. Should a
## writer ever move off the main thread, guarding those two Dictionaries with a
## Mutex is a precondition of that move, not a later hardening step.


## The lock's suffix, appended to the guarded file's own path.
const SUFFIX := ".lock"

## The ownership stamp inside the lock directory, naming the process that holds
## it. Written before the lock is published, never after — see
## [method _publish_lock].
##
## Its presence is deliberate — an EMPTY lock directory can be silently renamed
## over (measured), so a stamped lock is what makes a reclaimer's restore fail
## safely instead of overwriting a live holder. It also lets a holder prove the
## lock is still its own immediately before it replaces the guarded file.
const OWNER_FILE := "owner"

## Suffix for the uniquely-named directory a lock is BUILT in before it is
## published. Per-ATTEMPT, and private to this attempt: nothing else can name it,
## which is what lets the lock be assembled without any of it being visible at the
## shared path. See [method _publish_lock].
const STAGING_SUFFIX := ".staging-"

## Suffix for the uniquely-named directory an abandoned lock is renamed to while
## it is reclaimed. Per-ATTEMPT rather than per-process: see
## [method _reclaim_if_abandoned].
const RECLAIM_SUFFIX := ".reclaim-"

## Suffix for the uniquely-named name the ownership stamp is renamed to while its
## holder releases it. Applied to the STAMP, never to the lock directory — see
## [method _release_exclusively] for why the lock itself must not move. Distinct
## from [constant RECLAIM_SUFFIX] so a leftover says which pass abandoned it, and
## per-ATTEMPT for the same reason.
const RELEASE_SUFFIX := ".release-"

## How long a lock may go unreleased before another process may break it.
##
## Generous on purpose. The two failure directions are not symmetric:
##  - reclaiming a lock a LIVE process still holds reopens the exact interleaving
##    this lock exists to prevent, and the state it loses is permanent;
##  - waiting out a lock whose owner really did die costs one deferred write,
##    which the next attempt makes.
## So the window is far longer than any real critical section.
const STALE_SECONDS := 300

## Test-only override for [constant STALE_SECONDS]. A test sets 0 so an
## abandoned lock is immediately stale and the recovery path can be proven
## without sleeping. Production never sets it, and malformed or negative values
## fall through to the shipped window — see [method stale_seconds].
const STALE_ENV := "WAR_LOCK_STALE_SECONDS"

## Lock path -> this process's reentrancy depth. Reentrancy matters because a
## caller's outer helper takes the lock across its whole read-modify-write and
## then calls the inner save, which takes the same lock; without a depth count
## that nested acquire would refuse itself, and a self-deadlock is
## indistinguishable from healthy contention.
static var _held: Dictionary = {}

## Lock path -> the ownership token this process stamped into it.
static var _tokens: Dictionary = {}

## The staging path the last [method _publish_lock] assembled a lock in, or ""
## when that pass never got as far as building one.
##
## The acquire-side twin of [member _last_release_private], and there for the same
## reason: after [method acquire] returns, a lock built IN PLACE and a lock
## published whole are indistinguishable — both leave a stamped directory at the
## shared path. They differ only in whether a half-built lock was ever visible
## there, which one process cannot observe. So the seam asserts that acquisition
## went through the staging path, which is the property the fix actually is.
static var _last_publish_staging: String = ""

## The private path the last [method _release_exclusively] renamed a lock to
## before verifying it, or "" when that pass never got as far as a rename.
##
## Exists SOLELY so a test can prove [method release] actually goes through the
## private copy, and is the same seam — for the same reason — as
## `SaveVault._last_write_expectation`. Single-threaded, a release that deletes
## the SHARED directory after an ownership check is indistinguishable by outcome
## from one that renames first and verifies the copy: both leave an owned lock
## deleted and a foreign lock intact, because the bytes compared are the same
## bytes. They differ only when another process substitutes the directory in
## between, which no single-process test can stage. Measured: with `release()`
## reverted to check-then-act and this seam absent, every other case in
## lock_ownership_test still passed. So the wiring is asserted directly rather
## than inferred from behaviour it cannot produce.
static var _last_release_private: String = ""


## The lock directory guarding the file at `path`.
static func path_for(path: String) -> String:
	return path + SUFFIX


## The ownership claim's directory inside `lock`.
static func owner_path(lock: String) -> String:
	return lock + "/" + OWNER_FILE


## The stale-lock timeout: the [constant STALE_ENV] override when it is a
## non-negative integer, else the shipped default. Unset and malformed both fall
## through to the default, so the window can never be shortened by accident — a
## 0-second window in the field would let any live writer be robbed mid-write.
static func stale_seconds() -> int:
	var raw := OS.get_environment(STALE_ENV)
	if raw.is_valid_int():
		var seconds := int(raw)
		if seconds >= 0:
			return seconds
	return STALE_SECONDS


## Take the cross-process write lock guarding `path`.
##
## The lock is PUBLISHED whole — built complete under a private name and moved
## into place in one step — so the shared path only ever holds a finished lock and
## exactly one caller can put it there. Among callers that take this lock at all
## (see the class docs: a pre-lock build does not).
static func acquire(path: String) -> bool:
	var lock := path_for(path)
	var depth := int(_held.get(lock, 0))
	if depth > 0:
		_held[lock] = depth + 1
		return true
	var token := "%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var err := _publish_lock(lock, token)
	if err == ERR_ALREADY_EXISTS:
		# Someone holds it. Try to reclaim it if it is abandoned — but NEVER acquire
		# in the same pass, and refuse this write either way.
		#
		# Acquiring straight after a reclaim is what makes remove-then-create
		# unsound, and it is a real double-ownership bug rather than a theoretical
		# one: two processes both find the same stale lock, the first removes and
		# recreates it, and the second then removes THAT — a live lock — and
		# recreates it again, leaving both convinced they own the write. Keeping
		# acquisition to the single atomic publish below means the only way to hold
		# this lock is to have moved a finished one onto an absent path, which
		# exactly one caller can ever do.
		_reclaim_if_abandoned(lock)
		# WARNING, not error: losing the race is the design working. The class docs
		# above call contention expected and non-player-facing, and issue #379's own
		# scenario — the updater writing while the game runs — makes this the normal
		# path rather than a fault. Logging it at error level would bury the genuine
		# environment faults just below (an uncreatable lock, an unstampable owner)
		# under routine noise, and those are the ones worth waking up for. The
		# lost-lock case at release() already reports at this level for the same reason.
		push_warning("FileLock: another process holds the write lock at %s — refusing to write" % lock)
		return false
	if err != OK:
		# Anything else is an environment fault, not contention — an unwritable or
		# missing parent directory, say. Both refuse the write, but reporting them
		# as contention would send whoever reads this log hunting a race that is
		# not happening.
		push_error(
			"FileLock: cannot create the write lock at %s (error %d) — refusing to write"
			% [lock, err])
		return false
	_held[lock] = 1
	_tokens[lock] = token
	return true


## Build a complete lock for `token` privately, then publish it at `lock` in ONE
## step. Returns `ERR_ALREADY_EXISTS` when the slot was taken, leaving it untouched.
##
## [b]Publishing whole is what makes ownership atomic, and building in place cannot
## be made to work.[/b] `mkdir` alone is atomic, but a lock created empty and
## stamped afterwards is only half-built at the shared path in between, and every
## later step addresses it BY PATH. An acquirer descheduled past the stale timeout
## in that gap has its empty lock reclaimed as abandoned and the slot retaken; when
## it resumes, the path it stamps is a DIFFERENT directory — so it overwrites the
## new holder's token and records itself as owner of a lock it never created, and
## if that holder has just passed [method owns], both are inside the guarded write.
## Nothing added after the fact fixes that, because the flaw is the window itself.
##
## So the lock is assembled under a name no other process can derive and moved into
## place by `rename`, which the operating system settles for exactly one caller:
## onto an absent path it succeeds, and onto a non-empty directory it fails
## (measured). A published lock always carries its stamp, so a rival's publish
## finds a non-empty target and loses. There is no moment at which a partial lock
## is visible, and a slow acquirer can only ever win or lose the rename — never
## corrupt a lock that is not its own.
##
## [b]This is also why the on-disk shape is unchanged from the pre-atomic build.[/b]
## Atomicity comes from the rename, not from the stamp's shape, so `owner` stays a
## plain file and a retained older client and a current one still exclude each
## other exactly as before: an older build's `mkdir` is refused by a published
## lock, and its half-built empty lock is refused by the guard below rather than
## moved aside. Neither can hold the lock while the other writes.
static func _publish_lock(lock: String, token: String) -> int:
	var staging := "%s%s%d-%d" % [
		lock, STAGING_SUFFIX, OS.get_process_id(), Time.get_ticks_usec()]
	var staging_absolute := ProjectSettings.globalize_path(staging)
	_last_publish_staging = ""
	var err := DirAccess.make_dir_absolute(staging_absolute)
	if err != OK:
		return err
	# Recorded once the staging directory really exists, so the seam names a build
	# that happened rather than one this pass merely intended.
	_last_publish_staging = staging
	var owner := FileAccess.open(staging + "/" + OWNER_FILE, FileAccess.WRITE)
	if owner == null:
		DirAccess.remove_absolute(staging_absolute)
		return ERR_CANT_CREATE
	owner.store_string(token)
	owner.close()
	# Refuse rather than displace ANY lock already at the slot, including an EMPTY
	# one. `rename` fails onto a non-empty directory but REPLACES an empty one
	# (measured), and an empty lock is exactly what a build predating this shape
	# leaves while it stamps — so without this, publishing would move that build's
	# lock out from under it and a bare lock directory would stop excluding a
	# writer at all, which is the behaviour every caller has shipped against.
	#
	# This is a REFUSAL filter, never a grant, and that is what keeps it from being
	# check-then-act: it can only ever turn a success into a refusal. The rename
	# below still decides the race on its own, so a lock appearing in the gap costs
	# at most one deferred write — and the build it belonged to refuses in turn,
	# reading this build's published stamp as already present.
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(lock)):
		remove_dir(staging)
		return ERR_ALREADY_EXISTS
	if DirAccess.rename_absolute(staging_absolute, ProjectSettings.globalize_path(lock)) == OK:
		return OK
	# The slot is taken. Read as contention rather than as an environment fault:
	# the parent directory was demonstrably writable a moment ago, since the
	# staging directory and its stamp were both created in it.
	remove_dir(staging)
	return ERR_ALREADY_EXISTS


## The ownership token recorded in `lock`, or "" when there is none to read.
static func _recorded_token(lock: String) -> String:
	return _token_at(owner_path(lock))


## The token written at `stamp`, or "" when it cannot be read.
##
## Absent, unreadable and empty all read as "" — which no live holder's token can
## equal, so every one of them means NOT ours.
static func _token_at(stamp: String) -> String:
	var owner := FileAccess.open(stamp, FileAccess.READ)
	if owner == null:
		return ""
	var recorded := owner.get_as_text()
	owner.close()
	return recorded


## Run `body` with `path`'s write lock held, releasing it on every exit path.
## Returns false — without calling `body` at all — when the lock could not be
## taken.
##
## This is what makes a whole read-modify-write one transaction. Locking only the
## final replace is not enough: two writers can each load the same document
## BEFORE either takes the lock, then acquire in turn, and the second still
## discards the first's change. The lock has to span load → merge → save, and
## because GDScript has no `defer`, a caller bracketing that itself would leak
## the lock down any early return in between.
static func with_lock(path: String, body: Callable) -> bool:
	if not acquire(path):
		return false
	body.call()
	release(path)
	return true


## Whether this process is still the recorded holder of `path`'s lock.
##
## Checked immediately before the guarded file is replaced. If a reclaimer
## misjudged our live lock as abandoned and moved it away, the safe response is
## to abandon the write rather than replace the file while another writer
## believes it holds the lock. Absent directory, absent stamp and foreign stamp
## all read as NOT ours.
static func owns(path: String) -> bool:
	var lock := path_for(path)
	var mine: String = _tokens.get(lock, "")
	if mine.is_empty():
		return false
	return _recorded_token(lock) == mine


## Reclaim `lock` when it was abandoned by a dead process. Never acquires it.
##
## Reclamation is serialized by RENAME, not by remove: renaming a directory
## succeeds for exactly one caller and fails for every other once the source is
## gone (measured), so only one process can ever be reclaiming a given lock. The
## winner then owns a uniquely-named copy nobody else can touch, which is the only
## place a timestamp can be re-read without racing.
##
## The re-read is an IDENTITY check, not another staleness check: it must be the
## exact timestamp that was judged stale. A lock replaced between the judgement
## and the rename is a different, live lock, and mtime survives a rename
## (measured), so an exact match is what distinguishes them.
static func _reclaim_if_abandoned(lock: String) -> void:
	var observed := int(FileAccess.get_modified_time(lock))
	if observed <= 0:
		return
	if int(Time.get_unix_time_from_system()) - observed < stale_seconds():
		return
	# A per-ATTEMPT target, not a per-process one. A reclaimer that dies between the
	# rename and the delete leaves its private copy behind, and because that copy
	# holds a stamp it is non-empty — so a later rename onto the same name fails.
	# Keying only on the pid would then permanently disable stale recovery for
	# whichever process next inherits that pid: every attempt would target the same
	# surviving directory and fail, leaving that client unable to persist for the
	# whole session even though the lock really was abandoned.
	var dead := "%s%s%d-%d" % [
		lock, RECLAIM_SUFFIX, OS.get_process_id(), Time.get_ticks_usec()]
	var dead_absolute := ProjectSettings.globalize_path(dead)
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(lock), dead_absolute) != OK:
		return
	if int(FileAccess.get_modified_time(dead)) != observed:
		# Not the directory that was judged abandoned — a live holder replaced it in
		# the gap. Put it back; the restore fails rather than clobbers when the slot
		# is occupied by a stamped lock, and if it cannot be restored the copy is
		# dropped rather than left to shadow the real one.
		if DirAccess.rename_absolute(dead_absolute, ProjectSettings.globalize_path(lock)) == OK:
			return
		push_warning("FileLock: could not restore a live write lock at %s" % lock)
		remove_dir(dead)
		return
	push_warning("FileLock: reclaimed an abandoned write lock at %s" % lock)
	remove_dir(dead)


## Delete a lock directory and its ownership stamp. A directory holding a file
## cannot be removed in one call (measured), so the stamp goes first.
static func remove_dir(lock: String) -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(owner_path(lock)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(lock))


## Release one level of this process's lock for `path`, removing the directory
## when the outermost holder lets go. Releasing a lock we do not hold is a no-op
## rather than an error: it must be safe to call on any failure path without
## first proving acquisition got that far.
static func release(path: String) -> void:
	var lock := path_for(path)
	var depth := int(_held.get(lock, 0))
	if depth <= 0:
		return
	if depth > 1:
		_held[lock] = depth - 1
		return
	# Remove the directory ONLY while the claim is still ours — and decide that
	# ATOMICALLY. A writer suspended past the stale timeout can have its lock
	# reclaimed and the freed path taken by someone else; releasing unconditionally
	# would then delete THAT writer's lock and let a third process acquire while it
	# is still mid-write — reopening the lost-update race from the release path
	# rather than the acquire path.
	#
	# Reading the token and then deleting is not enough, because those are two
	# steps: a holder that has outlived the timeout can read its own token as still
	# valid and have the lock reclaimed and replaced before the delete lands, so the
	# delete destroys the REPLACEMENT's lock. Rename is what serializes it — see
	# [method _release_exclusively].
	var mine: String = _tokens.get(lock, "")
	_held.erase(lock)
	_tokens.erase(lock)
	_release_exclusively(lock, mine)


## Delete `lock` only if it still carries `mine`, deciding the two atomically.
##
## Rename is the serializer, exactly as in [method _reclaim_if_abandoned]: it
## succeeds for one caller and fails for every other once the source is gone
## (measured), so the winner ends up holding a uniquely-named stamp nobody else can
## reach, and reading the token off THAT cannot race.
##
## [b]It is the STAMP that moves, never the lock directory.[/b] Taking the whole
## lock aside would empty the shared path for the length of the check, and a lock
## that is briefly absent is a lock a third process can acquire — so a stale former
## holder releasing after its lock had already been reclaimed and retaken would
## vacate the CURRENT holder's slot, let a third in, then fail to put it back and
## delete it, leaving two processes inside the guarded write. That is the same lost
## update this lock exists to prevent, so a release must never vacate a slot it may
## not own.
##
## Moving only the stamp keeps the lock directory present and non-empty throughout,
## which closes that off completely (all measured):
##  - a rival's publish sees a non-empty target and fails, and an older build's
##    `mkdir` sees the directory and fails, so NOBODY can acquire while the stamp
##    is aside;
##  - therefore nothing can create a stamp at the shared name, so the restore below
##    cannot collide and cannot clobber;
##  - a concurrent holder's [method owns] finds no stamp and reads NOT ours, so it
##    refuses its write rather than proceeding — the safe direction.
##
## A process dying between the rename and the delete leaves its stamp behind under
## a per-ATTEMPT name, exactly as a dying reclaimer does: no later pass targets it,
## and the lock it belonged to is reclaimable on the normal stale path.
static func _release_exclusively(lock: String, mine: String) -> void:
	# Cleared FIRST, on every path including the early returns below. Left set, the
	# seam would still name the previous pass's stamp and a later assertion about
	# this one would pass without this pass having renamed anything.
	_last_release_private = ""
	if mine.is_empty():
		# Never acquired, or already released. Nothing of ours to remove, and
		# guessing would delete a lock belonging to whoever holds it now.
		return
	var aside := "%s%s%d-%d" % [
		owner_path(lock), RELEASE_SUFFIX, OS.get_process_id(), Time.get_ticks_usec()]
	var aside_absolute := ProjectSettings.globalize_path(aside)
	if DirAccess.rename_absolute(
			ProjectSettings.globalize_path(owner_path(lock)), aside_absolute) != OK:
		# No stamp to take aside: the lock was already released, or reclaimed out
		# from under us. Either way it is not ours to delete.
		push_warning(
			"FileLock: no ownership stamp to release at %s — leaving the lock alone" % lock)
		return
	# Recorded only once the rename SUCCEEDED, so the seam names a stamp that really
	# exists rather than one this pass merely intended to move.
	_last_release_private = aside
	if _token_at(aside) == mine:
		DirAccess.remove_absolute(aside_absolute)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(lock))
		return
	# Not ours. Put it back for whoever holds it now. Nothing can have taken the
	# name in the meantime — publishing and `mkdir` both need the lock directory to
	# be absent or empty, and it has been present and non-empty throughout.
	push_warning(
		"FileLock: the write lock at %s is no longer ours — leaving it for its holder" % lock)
	if DirAccess.rename_absolute(
			aside_absolute, ProjectSettings.globalize_path(owner_path(lock))) == OK:
		return
	# Unreachable by the argument above; if the filesystem says otherwise, drop the
	# stamp rather than leave it shadowing the lock it came from.
	push_warning("FileLock: could not restore an ownership stamp at %s that is not ours" % lock)
	DirAccess.remove_absolute(aside_absolute)


## Drop every lock this process holds. FOR TESTS ONLY: one test drives several
## contention cases through a single throwaway path and has to get back to a
## known state between them.
static func clear_for_test() -> void:
	for lock: String in _held.keys():
		remove_dir(lock)
	_held.clear()
	_tokens.clear()
	# Cleared too, so a later case cannot read a previous case's rename as its own
	# and pass without the production path having run at all.
	_last_publish_staging = ""
	_last_release_private = ""
