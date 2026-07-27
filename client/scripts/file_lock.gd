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


## The lock's suffix, appended to the guarded file's own path.
const SUFFIX := ".lock"

## The ownership stamp written inside the lock directory. Its presence is
## deliberate — an EMPTY lock directory can be silently renamed over (measured),
## so a stamped lock is what makes a reclaimer's restore fail safely instead of
## overwriting a live holder. It also lets a holder prove the lock is still its
## own immediately before it replaces the guarded file.
const OWNER_FILE := "owner"

## Suffix for the uniquely-named directory an abandoned lock is renamed to while
## it is reclaimed. Per-ATTEMPT rather than per-process: see
## [method _reclaim_if_abandoned].
const RECLAIM_SUFFIX := ".reclaim-"

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


## The lock directory guarding the file at `path`.
static func path_for(path: String) -> String:
	return path + SUFFIX


## The ownership stamp's path inside `lock`.
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
## `mkdir` decides the race: exactly one caller creates the directory and every
## other gets `ERR_ALREADY_EXISTS`, across threads and processes alike — among
## callers that take this lock at all (see the class docs: a pre-lock build does
## not).
static func acquire(path: String) -> bool:
	var lock := path_for(path)
	var depth := int(_held.get(lock, 0))
	if depth > 0:
		_held[lock] = depth + 1
		return true
	var absolute := ProjectSettings.globalize_path(lock)
	var err := DirAccess.make_dir_absolute(absolute)
	if err == ERR_ALREADY_EXISTS:
		# Someone holds it. Try to reclaim it if it is abandoned — but NEVER acquire
		# in the same pass, and refuse this write either way.
		#
		# Acquiring straight after a reclaim is what makes remove-then-create
		# unsound, and it is a real double-ownership bug rather than a theoretical
		# one: two processes both find the same stale lock, the first removes and
		# recreates it, and the second then removes THAT — a live lock — and
		# recreates it again, leaving both convinced they own the write. Keeping
		# acquisition to the single atomic mkdir below means the only way to hold
		# this lock is to have created it against an absent path, which exactly one
		# caller can ever do.
		_reclaim_if_abandoned(lock)
		push_error("FileLock: another process holds the write lock at %s — refusing to write" % lock)
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
	# Stamp ownership INSIDE the lock. Two things depend on the directory not being
	# empty: [method owns] can then prove this process is still the holder before
	# the destructive rename, and a reclaimer's restore is a rename onto a
	# non-empty directory, which fails safely instead of clobbering. (Measured:
	# renaming onto an EMPTY directory succeeds, so an empty lock would be
	# silently overwritable.)
	var token := "%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var stamped := _stamp_ownership(lock, token)
	if stamped == ERR_ALREADY_EXISTS:
		# Not the directory we created. Leave it alone — it belongs to whoever
		# stamped it — and refuse.
		push_error(
			"FileLock: the lock at %s was replaced while this process was acquiring it — refusing to write"
			% lock)
		return false
	if stamped != OK:
		push_error("FileLock: cannot stamp ownership into %s — refusing to write" % lock)
		DirAccess.remove_absolute(absolute)
		return false
	_held[lock] = 1
	_tokens[lock] = token
	return true


## Write `token` as the ownership stamp inside `lock`.
##
## Returns `ERR_ALREADY_EXISTS` when a stamp is already present, and writes
## NOTHING in that case. A directory reaching this point from [method acquire] is
## empty by construction — it was just created — so an existing stamp means this
## is a DIFFERENT directory: a process descheduled between its `mkdir` and its
## stamp for longer than the stale timeout has its empty lock reclaimed as
## abandoned, and another writer can then create and stamp a fresh lock at the
## same path. `FileAccess.WRITE` truncates, so stamping anyway would destroy that
## writer's token — making it abandon a write it legitimately owns — and record
## this process as the holder of a lock it never created.
##
## Split out so the refusal is reachable from a test. Driving it through
## [method acquire] cannot reach it: `mkdir` fails first when the directory
## exists, so an end-to-end case asserts a branch it never executes and passes
## with this guard deleted (measured).
static func _stamp_ownership(lock: String, token: String) -> int:
	if FileAccess.file_exists(owner_path(lock)):
		return ERR_ALREADY_EXISTS
	var owner := FileAccess.open(owner_path(lock), FileAccess.WRITE)
	if owner == null:
		return ERR_CANT_CREATE
	owner.store_string(token)
	owner.close()
	return OK


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
	var owner := FileAccess.open(owner_path(lock), FileAccess.READ)
	if owner == null:
		return false
	var recorded := owner.get_as_text()
	owner.close()
	return recorded == mine


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
	# Remove the directory ONLY while the stamp is still ours. A writer suspended
	# past the stale timeout can have its lock reclaimed and the freed path taken
	# by someone else; releasing unconditionally would then delete THAT writer's
	# lock and let a third process acquire while it is still mid-write — reopening
	# the lost-update race from the release path rather than the acquire path.
	# Checked before the bookkeeping is dropped, since owns() reads it.
	var still_ours := owns(path)
	_held.erase(lock)
	_tokens.erase(lock)
	if still_ours:
		remove_dir(lock)
	else:
		push_warning(
			"FileLock: the write lock at %s is no longer ours — leaving it for its holder" % lock)


## Drop every lock this process holds. FOR TESTS ONLY: one test drives several
## contention cases through a single throwaway path and has to get back to a
## known state between them.
static func clear_for_test() -> void:
	for lock: String in _held.keys():
		remove_dir(lock)
	_held.clear()
	_tokens.clear()
