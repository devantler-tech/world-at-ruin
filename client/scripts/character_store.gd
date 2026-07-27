class_name CharacterStore
## Saves and loads the player's character recipe (user://character.json).
##
## The recipe on disk is player state, so the no-resets law applies in full:
## it is versioned, name-keyed, and forward-only — every client that ever
## shipped must keep reading every recipe it ever wrote. Reading is delegated
## to CharacterFactory's validation (a newer-versioned recipe is refused
## loudly, never half-applied).
##
## Two seams keep tests off the player's real save (the no-resets law forbids a
## test stranding a character):
##  - save_to/load_from take an explicit path, so a test can exercise the exact
##    save/load logic against a throwaway file (character_persistence_test).
##  - save_path() resolves the location the whole-game path (save_recipe /
##    load_saved / exists / clear) reads, so a BOOT test that must go through
##    the game's own first-run path can point the game at a throwaway file by
##    setting WAR_SAVE_PATH before the scene loads. Shipped, the override is
##    unset and the path is the default below — the seam is inert in production.

const DEFAULT_PATH := "user://character.json"

## Environment override for the active save path. Empty/unset means "use the
## shipped default" — production never sets it; boot tests and a developer
## running the suite on a machine with a played save point it at a temp file.
const SAVE_PATH_ENV := "WAR_SAVE_PATH"

## Where an OLDER client's boot tests parked the real save while exercising the
## first-run creator. Those tests cleared user://character.json and restored it
## from here on the next run — so a run killed in between left the only copy
## here. This client's tests no longer do that (they redirect via the seam
## above), which means nothing would ever restore a copy stranded before the
## upgrade. recover_legacy_backup() closes that one-time migration gap.
const LEGACY_TEST_BACKUP := "user://character.json.test-backup"

## Prefix for the private staging file a write commits from. What follows it is a
## per-attempt unique stamp, so no two writers — and no two attempts — ever stage
## through the same path (see [method _write_tmp_path]).
const WRITE_TMP_SUFFIX := ".tmp-"

## How long an abandoned staging file must have sat UNCHANGED before this build
## reclaims it (see [method _sweep_abandoned_writes]).
##
## The vault sweeps with no age floor at all, and copying that here would be
## wrong: its sweep runs while HOLDING the cross-process write lock, so no other
## lock-aware writer can be inside its staging window and anything it finds is
## provably finished or dead. The character store has no such lock (#423 is
## blocked on the lock extraction in #422), so an age floor is what replaces the
## lock's proof — a staging file younger than this may be a live write by a
## second client, and deleting it would corrupt exactly the concurrent writer
## this change exists to protect.
##
## The failure directions are lopsided and point the same way as the vault's
## quarantine window: sweeping too eagerly destroys another client's in-flight
## character write, while sweeping too late leaves one stale file in user:// for
## one more launch. So this errs long on purpose. It is a liveness HEURISTIC
## about whether some writer is still working, exactly like
## [constant SaveVault.QUARANTINE_MIN_AGE_SECONDS], and it is not a mechanism for
## making reclamation prompt. A write completes in milliseconds; anything still
## present five minutes later is not in flight.
const WRITE_TMP_MIN_AGE_SECONDS := 300

## Test-only override for [constant WRITE_TMP_MIN_AGE_SECONDS], mirroring
## [constant SaveVault.QUARANTINE_MIN_AGE_ENV]. Production never sets it; a test
## sets 0 so a just-written stage is immediately eligible. Unset, empty,
## non-integer and negative values all keep the shipped default, so the window
## can never be SHORTENED by a malformed value — the direction that could destroy
## another client's write.
const WRITE_TMP_MIN_AGE_ENV := "WAR_CHARACTER_WRITE_TMP_MIN_AGE_SECONDS"


## The active save path: the WAR_SAVE_PATH override when set, else the shipped
## default. Resolved fresh each call so a test can redirect the game before it
## boots; inert (returns DEFAULT_PATH) whenever the override is empty.
static func save_path() -> String:
	var override := OS.get_environment(SAVE_PATH_ENV)
	return override if not override.is_empty() else DEFAULT_PATH


static func exists() -> bool:
	return FileAccess.file_exists(save_path())


## Paths whose recipe this build refused to accept, latched for the life of the
## process. A refusal is recorded rather than re-derived from the file's current
## state, because the file can change under us: cloud sync, a second client, or
## the player deleting it can all make a refused recipe vanish mid-session.
## Re-deriving would then answer "no character here", and the first-run creator
## would write a fresh one that syncs back over the character it just refused to
## read — exactly what refusing was protecting.
##
## Once refused, always refused. Restarting is the deliberate act that re-examines
## the file, and by then whichever build owns that recipe has had its chance to run.
static var _refused: Dictionary = {}


## Latch `path` as refused, log why, and return null.
##
## EVERY rejection of an existing file latches here, not only the ones reached
## through [method can_write]. The boot path calls [method load_saved] directly,
## and a rejection that did not latch would leave the path looking absent-and-
## writable the moment the file moved.
static func _refuse(path: String, message: String) -> Variant:
	push_error("CharacterStore: " + message)
	_refused[path] = true
	return null


## Whether the recipe at `path` was refused this session.
##
## This is what tells a refusal apart from a first run: [method load_from]
## returns null for both, and treating them the same opens the writable creator
## over an existing character.
static func is_refused(path: String) -> bool:
	return _refused.has(path)


## Whether it is safe to write a recipe to `path`. False when the path was
## refused this session, or when a file is present that this build cannot accept
## — a character from a NEWER build, or a corrupt one. Writing then would replace
## player state this build cannot even read. Absent AND never-refused is
## writable: that is a first run, not a loss.
static func can_write(path: String) -> bool:
	if _refused.has(path):
		return false
	if not FileAccess.file_exists(path):
		return true
	# load_from() latches any rejection of an existing file (see _refuse), so a
	# failure here has already marked the path.
	return load_from(path) != null


## Forget every latched refusal. FOR TESTS ONLY — a test exercises several recipe
## states through one throwaway path in a single process, and a latch that
## outlived the case would make every later case read as refused. Production never
## calls this: the latch is meant to outlive everything but a restart.
static func clear_refusals_for_test() -> void:
	_refused.clear()


## The staging window in seconds: the WRITE_TMP_MIN_AGE_ENV override when it is a
## non-negative integer, else the shipped default. Unset, empty, non-integer and
## negative values all fall through to the default, so the window can never be
## shortened by a malformed value.
static func write_tmp_min_age_seconds() -> int:
	var raw := OS.get_environment(WRITE_TMP_MIN_AGE_ENV)
	if raw.is_valid_int():
		var seconds := int(raw)
		if seconds >= 0:
			return seconds
	return WRITE_TMP_MIN_AGE_SECONDS


## The staging file this attempt commits from — PRIVATE to one write.
##
## The shared `character.json.tmp` this replaced is a name any other process can
## derive. A second client — the player running a second install, a rollback
## build the updater deliberately keeps runnable, a sync agent — opens that same
## deterministic path and truncates our staged recipe after we serialised it and
## before the rename. `path` itself is untouched, so [method can_write] and the
## pre-rename re-check both pass, and the rename then commits THEIR partial bytes
## over the character while reporting success. `CharacterFactory` refuses the
## result on the next boot, and there is no wipe to recover with.
##
## A per-attempt name removes the sharing instead of trying to detect it: a
## writer that never cooperated cannot name the file we are committing from. The
## process id makes a cross-process collision impossible and the microsecond
## stamp separates two attempts inside one process, matching
## [method SaveVault._free_quarantine_path].
static func _write_tmp_path(path: String) -> String:
	return "%s%s%d-%d" % [path, WRITE_TMP_SUFFIX, OS.get_process_id(), Time.get_ticks_usec()]


## Remove staging files abandoned by a crashed writer.
##
## A per-attempt name cannot be reclaimed by simply being overwritten the way one
## fixed `character.json.tmp` was, so without this a hard crash mid-write would
## leak a file into user:// on every occurrence.
##
## Age-gated rather than lock-gated, which is the one place this deliberately
## departs from the vault's sweep. The vault runs its sweep under the
## cross-process write lock, so everything carrying the prefix is provably
## finished or dead; the character store has no lock yet (#423), so a young
## staging file may belong to a live write by a second client and deleting it
## would cause the corruption this change exists to prevent. Only files that have
## sat unchanged past [method write_tmp_min_age_seconds] are reclaimed.
##
## Scoped to WRITE_TMP_SUFFIX deliberately. A foreign writer's plain
## `character.json.tmp` carries no per-attempt stamp and is none of our business
## — deleting a file another client is mid-write on is the kind of cross-writer
## damage this whole area exists to avoid.
static func _sweep_abandoned_writes(path: String) -> void:
	var parent := path.get_base_dir()
	var prefix := path.get_file() + WRITE_TMP_SUFFIX
	var min_age := write_tmp_min_age_seconds()
	var now := int(Time.get_unix_time_from_system())
	for entry: String in DirAccess.get_files_at(parent):
		if not entry.begins_with(prefix):
			continue
		var candidate := parent.path_join(entry)
		var modified := int(FileAccess.get_modified_time(candidate))
		# get_modified_time() answers 0 when it cannot stat the file, and 0 is
		# also an epoch timestamp — so an age computed from it reads as ancient
		# and would sweep a file whose age we in fact do not know. Unknown age
		# keeps the file: leaking one stale stage costs a launch, deleting a live
		# one costs the character.
		if modified <= 0:
			continue
		if now - modified < min_age:
			continue
		DirAccess.remove_absolute(ProjectSettings.globalize_path(candidate))


## Atomic: write a PRIVATE sibling staging file, then rename over the target. A
## crash mid-write must never corrupt the only copy of a character (no-resets law
## — there is no wipe to recover WITH).
##
## The staging name is per-attempt rather than a derivable `character.json.tmp`,
## so a writer that never cooperated cannot truncate the document being committed
## from (see [method _write_tmp_path]). That is a hole neither [method can_write]
## nor the pre-rename re-check can see, because both read the TARGET and the
## target is untouched until the rename.
##
## Refuses outright when the target holds a recipe this build cannot accept. This
## is the load-bearing half of the refusal: the creator is also locked shut while
## a refusal stands, but that is a UI guard on one entry point, and every writer
## reaching the file goes through here.
static func save_to(path: String, recipe: Dictionary) -> bool:
	if not can_write(path):
		push_error("CharacterStore: refusing to write %s — the recipe there is not this build's to replace" % path)
		return false
	_sweep_abandoned_writes(path)
	var tmp_path := _write_tmp_path(path)
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		push_error("CharacterStore: cannot write %s" % tmp_path)
		return false
	file.store_string(JSON.stringify(recipe, "  "))
	file.close()
	# Re-check immediately before the replacement. The check above is a
	# point-in-time reading, and the actors this store is written against — cloud
	# sync, a second client — can install a recipe this build cannot accept while
	# the temp file is being written. Without this the write would replace a
	# newly-arrived character having never refused or latched it, which is the
	# exact loss the latch exists to prevent. The residual window is the rename
	# itself; the vault narrows the same window the same way.
	if not can_write(path):
		push_error("CharacterStore: refusing to replace %s — its recipe changed to one this build cannot accept" % path)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_path))
		return false
	var err := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(tmp_path), ProjectSettings.globalize_path(path))
	if err != OK:
		push_error("CharacterStore: atomic replace failed (%d)" % err)
		return false
	return true


## The recipe stored at path, or null when none exists, it cannot be parsed, or
## this build cannot accept it.
##
## Null is TWO different answers and the caller must not conflate them. An absent
## file is a first run: nothing was refused and the path stays writable. A file
## that IS there and was rejected latches a refusal (see [method _refuse]) and
## never becomes writable again this session. Ask [method is_refused] or
## [method can_write] to tell them apart — reading the null alone as "no character
## yet" opens the writable creator over a character that is still there.
static func load_from(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var parsed = CharacterFactory.load_recipe(path)
	if parsed is not Dictionary:
		return _refuse(path, "%s is not a readable recipe" % path)
	# Validation, not just parsing: a recipe from a NEWER build parses perfectly
	# and is still not ours to replace.
	var reason := CharacterFactory.refusal_reason(parsed)
	if reason != "":
		return _refuse(path, "refusing %s — %s" % [path, reason])
	return parsed


static func save_recipe(recipe: Dictionary) -> bool:
	return save_to(save_path(), recipe)


static func load_saved() -> Variant:
	return load_from(save_path())


## Delete the active save. Refuses a path whose recipe was refused this session:
## deleting is the most destructive write of all, and the state being protected
## is precisely a character this build could not read well enough to judge.
## Nothing in the shipped game calls this — the guard is here so that nothing
## ever can without meeting the same condition as every other writer.
static func clear() -> void:
	var path := save_path()
	if _refused.has(path):
		push_error("CharacterStore: refusing to delete %s — the recipe there is not this build's to discard" % path)
		return
	if exists():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## Move a character stranded at `backup` back to `target`, but ONLY when
## `target` is absent — never clobber a live save (no-resets law). Returns true
## when a recovery happened. Pure in its paths so it is testable against
## throwaway files without touching the player's real save.
static func recover_backup_into(target: String, backup: String) -> bool:
	if FileAccess.file_exists(target) or not FileAccess.file_exists(backup):
		return false
	return DirAccess.rename_absolute(
		ProjectSettings.globalize_path(backup),
		ProjectSettings.globalize_path(target)) == OK


## Production one-time migration: restore a character an OLDER client's boot
## test stranded at LEGACY_TEST_BACKUP. Runs only when no override is active — a
## redirected test must never touch the real default — and never overwrites an
## existing save. Idempotent (the backup is consumed) and inert on a normal
## install where neither file exists. Call at boot before load_saved().
##
## Returns TRUE when it is safe to proceed with a normal boot (nothing stranded,
## a live save already exists, an override is active, or the backup was
## recovered). Returns FALSE only when a character IS stranded and could not be
## moved back (e.g. a transient file lock): the caller MUST NOT then open the
## writable first-run creator, or a new character would overwrite the default
## and orphan the stranded one forever (no-resets law) — retry on next boot.
static func recover_legacy_backup() -> bool:
	if save_path() != DEFAULT_PATH:
		return true
	if FileAccess.file_exists(DEFAULT_PATH) or not FileAccess.file_exists(LEGACY_TEST_BACKUP):
		return true
	return recover_backup_into(DEFAULT_PATH, LEGACY_TEST_BACKUP)
