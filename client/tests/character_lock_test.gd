extends Node
## Contention test for the character store's cross-process write lock (issue #423).
##
## character_persistence_test pins the store's single-writer behaviour and
## character_staging_test pins its private staging; this pins what happens when
## there is MORE than one writer. The race it closes is check-then-act across a
## read-modify-write: two clients sharing one user:// directory — the player
## running a second install, a rollback build the updater keeps runnable, a sync
## agent restoring a file — each read the same recipe, each judge it writable,
## and the slower rename silently discards the faster writer's character. Under
## the no-resets law that loss is permanent, and the recipe is the more valuable
## of the two saved documents.
##
## The character store deliberately takes the SAME lock as SaveVault rather than
## a second bespoke mechanism, so the two stores fail the same way for the same
## reason. FileLock's own internals — reclaim-never-acquires, the ownership
## stamp's shape, the timeout seam's fallbacks — are pinned once in
## vault_lock_test and are not restated here. What this file pins is that the
## CHARACTER write is actually under that lock, and what a refused character
## write leaves behind.
##
## A competing process is simulated by creating the lock directory directly.
## That is not an approximation: the lock IS a directory, so one created by
## anything is byte-for-byte what a real competing client leaves behind, and the
## code under test cannot tell the difference.
##
## What is pinned:
##  1. The lock sits beside the recipe, and a successful write leaves none behind.
##  2. A held lock REFUSES the write — recipe byte-intact and, because the lock is
##     taken before the read, nothing staged either. This is the case that goes
##     RED on the pre-lock code, where the write ignored the lock entirely.
##  3. Contention degrades to a refused write, never a blocked boot: the recipe
##     still READS while another writer holds the lock.
##  4. Writes resume once the competing writer releases — without this, case 2
##     could pass on any unrelated failure.
##  5. A REFUSED write releases the lock. A leak would wedge saving for the whole
##     stale timeout.
##  6. An abandoned lock is reclaimed, so a killed process cannot make the
##     character unsaveable for the life of the install.
##  7. The refusal latch is independent of the lock: a refused path stays
##     unwritable with the lock free, and takes no lock on its way out.
##  8. A write that LOST its lock refuses rather than replacing the recipe behind
##     the back of whoever holds it now.
##  9. Contention does NOT latch a refusal, while a genuine refusal does. The two
##     answer false alike, and `main.gd` latches the creator shut on the second
##     only — so a momentary collision must not lock a player out of their own
##     character for the session.
##
## The probe is namespaced by process id: git worktrees do not isolate Godot's
## project-wide user:// directory, so two local test processes sharing a fixed
## probe name would remove and replace one another's evidence.
##
## Run: godot --headless --path client res://tests/character_lock_test.tscn

var _probe: String
var _failures: Array[String] = []


func _ready() -> void:
	_probe = "user://character_lock_probe.process-%d.json" % OS.get_process_id()
	_cleanup()

	var recipe = CharacterFactory.load_recipe("res://recipes/wanderer.json")
	if recipe is not Dictionary:
		_fail("wanderer preset unreadable — cannot exercise a save")
		_finish()
		return

	_check_lock_sits_beside_and_does_not_leak(recipe)
	_check_held_lock_refuses_write(recipe)
	_check_read_survives_contention(recipe)
	_check_write_resumes_after_release(recipe)
	_check_refused_write_releases_lock(recipe)
	_check_abandoned_lock_reclaimed(recipe)
	_check_refusal_latch_independent_of_lock(recipe)
	_check_lost_lock_refuses_write(recipe)
	_check_contention_does_not_latch_a_refusal(recipe)

	_finish()


func _finish() -> void:
	_cleanup()
	if _failures.is_empty():
		print("TEST PASS — the character write takes the cross-process lock, refuses under contention without staging, releases on every path, recovers from an abandoned lock, and never latches a refusal on contention (9 checks)")
		get_tree().quit(0)
		return
	print("TEST FAIL — %s" % "; ".join(_failures))
	get_tree().quit(1)


## 1. The lock is a directory beside the recipe — the same shape and the same
## class of lock the vault takes — and a completed write does not leave it.
func _check_lock_sits_beside_and_does_not_leak(recipe: Dictionary) -> void:
	var lock := FileLock.path_for(_probe)
	if lock != _probe + FileLock.SUFFIX:
		_fail("the character lock does not sit beside the recipe: %s" % lock)
		return
	if not CharacterStore.save_to(_probe, recipe):
		_fail("the first save did not persist")
		return
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("the lock survived a successful write — it would wedge saving")
	_remove(_probe)


## 2. A competing writer holds the lock: the write must refuse rather than
## interleave, leave the recipe byte-intact, and stage NOTHING.
##
## The staging assertion is what proves the lock spans the whole read-modify-write
## rather than only the rename. A lock taken late would let this call read, judge
## and serialise a recipe before discovering the contention, leaving a staging
## file behind as the evidence.
func _check_held_lock_refuses_write(recipe: Dictionary) -> void:
	if not CharacterStore.save_to(_probe, recipe):
		_fail("could not seed a recipe for the contention case")
		return
	var baseline := _read_text(_probe)
	if baseline.is_empty():
		_fail("the seeded recipe is empty")
		return

	var lock := FileLock.path_for(_probe)
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not simulate a competing writer by taking the lock")
		return
	if CharacterStore.save_to(_probe, recipe):
		_fail("a save SUCCEEDED while another writer held the lock — the race is open")
	if _read_text(_probe) != baseline:
		_fail("a refused save still modified the recipe — it must be byte-intact")
	var staged := _stages()
	if not staged.is_empty():
		_fail("a refused save staged bytes before taking the lock: %s" % ", ".join(staged))
		_remove_stages()
	DirAccess.remove_absolute(_abs(lock))


## 3. Contention refuses a WRITE; it must never make the character unreadable.
## A locked recipe that stopped loading would block a boot.
func _check_read_survives_contention(_recipe: Dictionary) -> void:
	var lock := FileLock.path_for(_probe)
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not take the lock for the readability case")
		return
	if CharacterStore.load_from(_probe) == null:
		_fail("the recipe became unreadable while another writer held the lock — that blocks a boot")
	DirAccess.remove_absolute(_abs(lock))


## 4. Once the competing writer releases, writes resume. Without this, case 2
## would pass on any unrelated failure that refused a write anyway.
func _check_write_resumes_after_release(recipe: Dictionary) -> void:
	var baseline := _read_text(_probe)
	var changed := recipe.duplicate(true)
	changed["name"] = "lock-probe-resumed"
	if not CharacterStore.save_to(_probe, changed):
		_fail("the save did not resume once the competing writer released the lock")
		return
	if _read_text(_probe) == baseline:
		_fail("the resumed save did not actually change the recipe")
	if DirAccess.dir_exists_absolute(_abs(FileLock.path_for(_probe))):
		_fail("the resumed save leaked the lock")


## 5. A refused write must release the lock too. The refusal here comes from the
## pre-rename guard deep inside the locked section, which is exactly the kind of
## early return that leaks a lock when release is not on a single path.
func _check_refused_write_releases_lock(recipe: Dictionary) -> void:
	_remove(_probe)
	CharacterStore.clear_refusals_for_test()
	# A recipe this build cannot accept makes can_write() refuse INSIDE the lock.
	_write_text(_probe, "{ not a readable recipe")
	if CharacterStore.save_to(_probe, recipe):
		_fail("a save replaced a recipe this build cannot read")
	if DirAccess.dir_exists_absolute(_abs(FileLock.path_for(_probe))):
		_fail("the lock LEAKED after a refused write — saving would wedge until the timeout")
	CharacterStore.clear_refusals_for_test()
	_remove(_probe)


## 6. Stale recovery: a killed process leaves a lock nobody will ever release.
## With the timeout seamed to 0 the next attempt frees the slot, so a crash
## cannot make the character permanently unsaveable.
func _check_abandoned_lock_reclaimed(recipe: Dictionary) -> void:
	var lock := FileLock.path_for(_probe)
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not simulate a crashed process's abandoned lock")
		return
	OS.set_environment(FileLock.STALE_ENV, "0")
	# The reclaiming pass frees the slot and still refuses; the NEXT attempt
	# acquires it. Recovery is one deferred write, not a permanently locked save.
	if CharacterStore.save_to(_probe, recipe):
		_fail("the reclaiming attempt WROTE — reclaim and acquire must not share a pass")
	if DirAccess.dir_exists_absolute(_abs(lock)):
		_fail("the abandoned lock was not reclaimed — a crash would wedge saving permanently")
	OS.set_environment(FileLock.STALE_ENV, "")
	if not CharacterStore.save_to(_probe, recipe):
		_fail("the save did not resume after the abandoned lock was reclaimed")
	_remove(_probe)


## 7. The refusal latch outranks the lock and does not depend on it. A refused
## path stays unwritable with the lock free, and leaves no lock behind.
func _check_refusal_latch_independent_of_lock(recipe: Dictionary) -> void:
	_write_text(_probe, "{ not a readable recipe")
	# Latch the refusal by reading it, then remove the file entirely: the latch,
	# not the file's current state, is what must keep the path unwritable.
	CharacterStore.load_from(_probe)
	if not CharacterStore.is_refused(_probe):
		_fail("reading an unacceptable recipe did not latch a refusal")
	_remove(_probe)
	if CharacterStore.save_to(_probe, recipe):
		_fail("a refused path became writable once the file was gone")
	if DirAccess.dir_exists_absolute(_abs(FileLock.path_for(_probe))):
		_fail("a refused save left a lock behind")
	CharacterStore.clear_refusals_for_test()
	_remove(_probe)


## 8. A write that lost its lock refuses rather than replacing the recipe.
##
## A reclaimer that misjudged this live lock as abandoned moves it away, and
## another writer may then hold it legitimately. Driven at _save_to_locked()
## because that interleaving needs two real processes to arise otherwise.
func _check_lost_lock_refuses_write(recipe: Dictionary) -> void:
	if not CharacterStore.save_to(_probe, recipe):
		_fail("could not seed a recipe for the lost-lock case")
		return
	var before := _read_text(_probe)
	if not FileLock.acquire(_probe):
		_fail("could not acquire the lock for the lost-lock case")
		return
	var stamp := FileAccess.open(FileLock.owner_path(FileLock.path_for(_probe)), FileAccess.WRITE)
	if stamp == null:
		_fail("could not overwrite the ownership stamp")
		FileLock.release(_probe)
		return
	stamp.store_string("999999-1")
	stamp.close()
	if FileLock.owns(_probe):
		_fail("a REPLACED ownership stamp still read as ours")
	var changed := recipe.duplicate(true)
	changed["name"] = "lock-probe-hijacked"
	if CharacterStore._save_to_locked(_probe, changed):
		_fail("a write proceeded while the lock was no longer ours")
	if _read_text(_probe) != before:
		_fail("a write that lost the lock still modified the recipe")
	if not _stages().is_empty():
		_fail("a write that lost the lock left its staging file behind")
		_remove_stages()
	FileLock.release(_probe)
	# That lock is owned by the hijacked stamp now, so release left it in place.
	FileLock.remove_dir(FileLock.path_for(_probe))
	_remove(_probe)


## 9. Contention must NOT latch a refusal — a refused write and a contended one
## both answer false, and the caller has to tell them apart.
##
## `main.gd` locks the character creator shut for the whole session when a save
## comes back false AND the path reads as refused. Were contention to latch,
## one momentary collision — or the reclaiming pass, which deliberately refuses
## once while freeing an abandoned lock — would lock the player out of their own
## character until they restarted. Both directions are asserted, because a latch
## that never fires would satisfy the first half alone.
func _check_contention_does_not_latch_a_refusal(recipe: Dictionary) -> void:
	CharacterStore.clear_refusals_for_test()
	if not CharacterStore.save_to(_probe, recipe):
		_fail("could not seed a recipe for the latch case")
		return
	var lock := FileLock.path_for(_probe)
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not take the lock for the latch case")
		return
	if CharacterStore.save_to(_probe, recipe):
		_fail("a save succeeded while another writer held the lock")
	if CharacterStore.is_refused(_probe):
		_fail("CONTENTION latched a refusal — one collision would lock the creator for the session")
	DirAccess.remove_absolute(_abs(lock))

	# The other direction: a genuine refusal DOES latch, so the caller still has a
	# signal to latch the creator on.
	_remove(_probe)
	_write_text(_probe, "{ not a readable recipe")
	if CharacterStore.save_to(_probe, recipe):
		_fail("a save replaced a recipe this build cannot read")
	if not CharacterStore.is_refused(_probe):
		_fail("a genuine refusal did NOT latch — the creator would never lock shut")
	CharacterStore.clear_refusals_for_test()
	_remove(_probe)


## Every staging file for the probe, matched by prefix — never by a fixed name
## (the vacuity trap #424 measured, since staging is per-attempt).
func _stages() -> Array[String]:
	var found: Array[String] = []
	var parent := _probe.get_base_dir()
	var prefix := _probe.get_file() + CharacterStore.WRITE_TMP_SUFFIX
	for entry: String in DirAccess.get_files_at(parent):
		if entry.begins_with(prefix):
			found.append(entry)
	return found


func _remove_stages() -> void:
	var parent := _probe.get_base_dir()
	for entry: String in _stages():
		_remove(parent.path_join(entry))


func _abs(path: String) -> String:
	return ProjectSettings.globalize_path(path)


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("could not seed %s" % path)
		return
	file.store_string(text)
	file.close()


func _read_text(path: String) -> String:
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


func _fail(message: String) -> void:
	push_error("character_lock_test: " + message)
	_failures.append(message)


func _cleanup() -> void:
	OS.set_environment(FileLock.STALE_ENV, "")
	CharacterStore.clear_refusals_for_test()
	FileLock.clear_for_test()
	var lock := FileLock.path_for(_probe)
	FileLock.remove_dir(lock)
	# Reclaim copies carry a per-ATTEMPT suffix, so they cannot be reconstructed
	# by name — scan the directory for the prefix instead.
	var parent := lock.get_base_dir()
	var reclaim_prefix := lock.get_file() + FileLock.RECLAIM_SUFFIX
	for entry: String in DirAccess.get_directories_at(parent):
		if entry.begins_with(reclaim_prefix):
			FileLock.remove_dir(parent.path_join(entry))
	_remove_stages()
	_remove(_probe)


func _exit_tree() -> void:
	_cleanup()
