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
## [b]Ownership is decided by that same primitive, at both ends.[/b] Holding the
## lock is one property, and it is established once on the way in and settled once
## on the way out — never by testing a marker and then acting on what the test
## said, which is the same race one level down:
##  - CLAIMING is a `mkdir` of the ownership directory inside the lock, so exactly
##    one acquirer can ever win it (see [method _claim_ownership]);
##  - RELEASING renames the lock to a private path and verifies the token on that
##    copy before deleting it, so no other process can substitute the directory
##    between the check and the delete (see [method _release_exclusively]).
## Both are the technique [method _reclaim_if_abandoned] already used, applied to
## the two operations that previously did not.
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

## The ownership claim inside the lock directory — itself a DIRECTORY, for the
## same reason the lock is one: `mkdir` is the only atomic exclusive-create Godot
## exposes, so exactly one caller can ever claim ownership of a given lock.
##
## Its presence is deliberate — an EMPTY lock directory can be silently renamed
## over (measured), so a claimed lock is what makes a reclaimer's restore fail
## safely instead of overwriting a live holder. It also lets a holder prove the
## lock is still its own immediately before it replaces the guarded file.
const OWNER_DIR := "owner"

## The token file the claim's winner writes INSIDE [constant OWNER_DIR]. The
## claim and the token are two steps on purpose: the claim is what must be
## atomic, and a token written after it is only ever written by the one caller
## that won. A winner that dies between the two leaves a claim with no token,
## which [method owns] reads as NOT ours — the write is refused rather than
## taken on an unproven claim.
const TOKEN_FILE := "token"

## Suffix for the uniquely-named directory an abandoned lock is renamed to while
## it is reclaimed. Per-ATTEMPT rather than per-process: see
## [method _reclaim_if_abandoned].
const RECLAIM_SUFFIX := ".reclaim-"

## Suffix for the uniquely-named directory a lock is renamed to while it is
## RELEASED. Distinct from [constant RECLAIM_SUFFIX] so a leftover copy says which
## pass abandoned it, and per-ATTEMPT for the same reason: see
## [method _release_exclusively].
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


## The lock directory guarding the file at `path`.
static func path_for(path: String) -> String:
	return path + SUFFIX


## The ownership claim's directory inside `lock`.
static func owner_path(lock: String) -> String:
	return lock + "/" + OWNER_DIR


## The ownership token's path inside `lock`'s claim.
static func token_path(lock: String) -> String:
	return owner_path(lock) + "/" + TOKEN_FILE


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
	# Claim ownership INSIDE the lock. Two things depend on the directory not being
	# empty: [method owns] can then prove this process is still the holder before
	# the destructive rename, and a reclaimer's restore is a rename onto a
	# non-empty directory, which fails safely instead of clobbering. (Measured:
	# renaming onto an EMPTY directory succeeds, so an empty lock would be
	# silently overwritable.)
	var token := "%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var claimed := _claim_ownership(lock, token)
	if claimed == ERR_ALREADY_EXISTS:
		# Not the directory we created. Leave it alone — it belongs to whoever
		# claimed it — and refuse.
		push_error(
			"FileLock: the lock at %s was replaced while this process was acquiring it — refusing to write"
			% lock)
		return false
	if claimed != OK:
		push_error("FileLock: cannot claim ownership of %s — refusing to write" % lock)
		# remove_dir(), not remove_absolute(): the claim directory may have been
		# created before the token write failed, and a directory holding an entry
		# cannot be removed in one call (measured) — a bare remove would leave the
		# lock behind and wedge the file for the whole stale timeout.
		remove_dir(lock)
		return false
	_held[lock] = 1
	_tokens[lock] = token
	return true


## Claim ownership of `lock` for `token`, atomically.
##
## Returns `ERR_ALREADY_EXISTS` when the claim is already taken, and writes
## NOTHING in that case. A directory reaching this point from [method acquire] is
## empty by construction — it was just created — so an existing claim means this
## is a DIFFERENT directory: a process descheduled between its `mkdir` and its
## claim for longer than the stale timeout has its empty lock reclaimed as
## abandoned, and another writer can then create and claim a fresh lock at the
## same path. Claiming anyway would destroy that writer's token — making it
## abandon a write it legitimately owns — and record this process as the holder
## of a lock it never created.
##
## [b]The claim is a `mkdir`, not a file write, and that is the whole point.[/b]
## Testing for the marker and then creating it is check-then-act: two acquirers
## reaching the gap above can BOTH see no claim, both write their token, and both
## then read their own token back if the reads interleave with the writes — two
## processes inside the same guarded read-modify-write, which is exactly the lost
## update this lock exists to prevent. `DirAccess.make_dir_absolute` is `mkdir`,
## the one exclusive-create Godot exposes that fails with `ERR_ALREADY_EXISTS`
## rather than succeeding when the path is taken (measured), so the winner is
## decided by the operating system in a single step and the loser cannot mistake
## itself for the holder. The token is written after, by the one caller that won.
##
## [b]Cross-version, this fails CLOSED in both directions[/b] — both measured on
## 4.7.1. A build predating this shape writes `owner` as a FILE and reads it with
## `FileAccess`; a build carrying it makes `owner` a DIRECTORY:
##  - old build meeting a new claim: `FileAccess.open(<dir>, WRITE)` returns null,
##    so it refuses; `file_exists(<dir>)` is false and `open(<dir>, READ)` is
##    null, so [method owns] is false and its write refuses too;
##  - new build meeting an old claim: `mkdir` over an existing FILE returns
##    `ERR_ALREADY_EXISTS`, so it refuses, and the token beneath it cannot be
##    opened, so [method owns] is false.
## Neither can read the other's claim as its own, so the mismatch costs a
## deferred write — degrading to session-only, this client's standing answer to
## doubt about persisted state — rather than admitting two writers.
##
## Split out so the refusal is reachable from a test. Driving it through
## [method acquire] cannot reach it: `mkdir` fails first when the directory
## exists, so an end-to-end case asserts a branch it never executes and passes
## with this guard deleted (measured).
static func _claim_ownership(lock: String, token: String) -> int:
	var err := DirAccess.make_dir_absolute(ProjectSettings.globalize_path(owner_path(lock)))
	if err != OK:
		# ERR_ALREADY_EXISTS is a lost race; anything else is an environment fault.
		# Both refuse, and neither may write a token into a claim it does not hold.
		return err
	var owner := FileAccess.open(token_path(lock), FileAccess.WRITE)
	if owner == null:
		return ERR_CANT_CREATE
	owner.store_string(token)
	owner.close()
	return OK


## The ownership token recorded in `lock`, or "" when there is none to read.
##
## Absent claim, absent token and an unreadable token all read as "" — which no
## live holder's token can equal, so every one of them means NOT ours.
static func _recorded_token(lock: String) -> String:
	var owner := FileAccess.open(token_path(lock), FileAccess.READ)
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


## Delete a lock directory, its ownership claim and the token inside it. A
## directory holding an entry cannot be removed in one call (measured), so the
## three levels come off innermost-first: token, then claim, then lock.
static func remove_dir(lock: String) -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(token_path(lock)))
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
## Same primitive and same shape as [method _reclaim_if_abandoned], for the same
## reason: renaming a directory succeeds for exactly one caller and fails for
## every other once the source is gone (measured), so the winner ends up holding a
## uniquely-named copy nobody else can reach. Verifying the token on THAT copy
## cannot race — no other process can substitute the directory in between, because
## no other process can name it.
##
## The check-then-act this replaces was the release-path mirror of the acquire
## path's: this file already used rename correctly when reclaiming and not when
## releasing, so ownership was a half-guarded property rather than one.
static func _release_exclusively(lock: String, mine: String) -> void:
	if mine.is_empty():
		# Never acquired, or already released. Nothing of ours to remove, and
		# guessing would delete a lock belonging to whoever holds it now.
		return
	# Per-ATTEMPT, exactly as reclaim targets are: a release that dies after the
	# rename leaves its private copy behind, and keying on the pid alone would aim
	# every later attempt from an inheritor of that pid at the same surviving
	# directory.
	var private := "%s%s%d-%d" % [
		lock, RELEASE_SUFFIX, OS.get_process_id(), Time.get_ticks_usec()]
	var private_absolute := ProjectSettings.globalize_path(private)
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(lock), private_absolute) != OK:
		# Already gone, or another process is moving it. Either way it is not ours
		# to delete, and there is nothing left to leak.
		push_warning(
			"FileLock: could not take the write lock at %s aside to release it — leaving it" % lock)
		return
	if _recorded_token(private) == mine:
		remove_dir(private)
		return
	# Not ours. Put it back for whoever holds it now — the restore fails rather
	# than clobbers when the slot has been taken again, since a claimed lock is
	# non-empty (measured).
	push_warning(
		"FileLock: the write lock at %s is no longer ours — leaving it for its holder" % lock)
	if DirAccess.rename_absolute(private_absolute, ProjectSettings.globalize_path(lock)) == OK:
		return
	# The slot is occupied by a newer lock, so this copy is an orphan that would
	# otherwise shadow the real one. Drop it rather than leave it behind.
	push_warning("FileLock: could not restore a write lock at %s that is not ours" % lock)
	remove_dir(private)


## Drop every lock this process holds. FOR TESTS ONLY: one test drives several
## contention cases through a single throwaway path and has to get back to a
## known state between them.
static func clear_for_test() -> void:
	for lock: String in _held.keys():
		remove_dir(lock)
	_held.clear()
	_tokens.clear()
