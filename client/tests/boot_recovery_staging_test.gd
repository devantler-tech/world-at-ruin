extends Node
## Regression test for #442: a boot-recovery write must not stage through a name
## another process can derive.
##
## `BootRecovery.save_state()` used to commit from `<path>.tmp`. That name is
## derivable, so a writer that never took the lock — a retained or rollback build
## from before [FileLock] existed, a sync agent, a second install — opens the same
## path and can truncate our staged document. The TARGET is untouched until the
## rename, so `can_write()`, the `only_if_missing` re-check and the ownership
## proof all pass, and the rename commits the other writer's partial bytes over
## the quarantine ledger. What that loses is the evidence deciding whether a
## client rolls back, lost at the least recoverable moment there is.
##
## The read-back compare that was already there narrows this and does not close
## it: it catches a truncation landing BEFORE the compare, never one landing
## between the compare and the rename.
##
## What is pinned here:
##  1. The staging name is private — not the derivable `<path>.tmp`, distinct per
##     attempt, and carrying this process's id.
##  2. A foreign writer's `<path>.tmp` is neither staged through nor deleted: it
##     survives a save byte-for-byte. THIS is the case that fails on the old
##     code, where the save consumed that exact file.
##  3. A save leaves no staging file behind — asserted BY PREFIX. #424 measured
##     the trap: an assertion probing the fixed `<path>.tmp` passes vacuously the
##     moment staging becomes per-attempt, so it must never be written that way.
##  4. An abandoned stage is reclaimed by the next write.
##  5. The sweep NEVER runs unlocked. This is the safety half, and it is what
##     recovery has instead of the character store's age floor (#429/#434): the
##     sweep may delete anything carrying the prefix only because it runs while
##     holding the cross-process write lock, which proves no other lock-aware
##     writer is inside its staging window. A save that cannot take the lock must
##     therefore sweep nothing — otherwise the sweep would delete a live stage
##     belonging to the very writer that holds the lock.
##
## The probe is namespaced by process id: git worktrees do not isolate Godot's
## project-wide user:// directory, so two local test processes sharing a fixed
## probe name would remove and replace one another's evidence.
##
## Run: godot --headless --path client res://tests/boot_recovery_staging_test.tscn

var _probe: String
var _failures: Array[String] = []


func _ready() -> void:
	_probe = "user://boot_recovery_staging_probe.process-%d.json" % OS.get_process_id()
	_cleanup()

	_check_name_is_private()
	_check_foreign_stage_survives()
	_check_no_stage_left_behind()
	_check_abandoned_stage_reclaimed()
	_check_sweep_never_runs_unlocked()

	_cleanup()
	if _failures.is_empty():
		print("TEST PASS — boot-recovery staging is private (5 checks)")
		get_tree().quit(0)
		return
	print("TEST FAIL — %s" % "; ".join(_failures))
	get_tree().quit(1)


## 1. The staging name is private to one attempt.
func _check_name_is_private() -> void:
	var first := BootRecovery._write_tmp_path(_probe)
	var second := BootRecovery._write_tmp_path(_probe)
	if first == _probe + ".tmp":
		_fail("staging name is the derivable <path>.tmp")
	if first == second:
		_fail("two staging attempts share one name (%s)" % first)
	if not first.begins_with(_probe + BootRecovery.WRITE_TMP_SUFFIX):
		_fail("staging name does not carry the sweepable prefix (%s)" % first)
	if not first.contains(str(OS.get_process_id())):
		_fail("staging name does not carry this process id (%s)" % first)


## 2. A foreign writer's derivable stage survives a save untouched.
##
## This is the behavioural proof, and the one that goes RED on the old code:
## there, save_state() opened this exact path with FileAccess.WRITE (truncating
## the planted bytes) and then renamed it onto the target, so the file was
## consumed.
func _check_foreign_stage_survives() -> void:
	var foreign := _probe + ".tmp"
	var foreign_bytes := "a second client's half-written recovery document"
	_write_text(foreign, foreign_bytes)

	var saved := BootRecovery.save_state(_probe, _state())
	if not (saved["ok"] as bool):
		_fail("save failed while a foreign stage was present: %s" % str(saved["reason"]))
		_remove(foreign)
		return
	if not FileAccess.file_exists(foreign):
		_fail("the save consumed a foreign writer's %s" % foreign)
	elif _read_text(foreign) != foreign_bytes:
		_fail("the save overwrote a foreign writer's staged bytes")
	if not (BootRecovery.load_state(_probe)["ok"] as bool):
		_fail("the recovery state did not land while a foreign stage was present")

	_remove(foreign)
	_remove(_probe)


## 3. A completed save leaves no staging file — matched BY PREFIX, never by the
## fixed name (the vacuity trap #424 measured).
func _check_no_stage_left_behind() -> void:
	var saved := BootRecovery.save_state(_probe, _state())
	if not (saved["ok"] as bool):
		_fail("save failed on a clean path: %s" % str(saved["reason"]))
		return
	var leftovers := _stages()
	if not leftovers.is_empty():
		_fail("save left staging files behind: %s" % ", ".join(leftovers))
	_remove(_probe)


## 4. A stage abandoned by a crashed writer is reclaimed by the next write.
func _check_abandoned_stage_reclaimed() -> void:
	var abandoned := BootRecovery._write_tmp_path(_probe)
	_write_text(abandoned, "bytes a crashed writer left behind")
	var saved := BootRecovery.save_state(_probe, _state())
	if not (saved["ok"] as bool):
		_fail("save failed with an abandoned stage present: %s" % str(saved["reason"]))
	if FileAccess.file_exists(abandoned):
		_fail("an abandoned stage was not reclaimed")
	_remove(abandoned)
	_remove(_probe)


## 5. The sweep never runs while the lock is held by someone else.
##
## The sweep deletes anything carrying the prefix, with no age check. That is
## sound ONLY under the lock: holding it proves no other lock-aware writer is
## mid-write, and every file the sweep can match was written by a build that
## takes the lock. Move the sweep outside the lock and this check goes red — the
## refused save would reclaim a stage belonging to the writer that actually holds
## it. This is the recovery equivalent of the character store's live-stage check,
## and it fails in the same direction: destroying another writer's in-flight
## document.
func _check_sweep_never_runs_unlocked() -> void:
	var lock := FileLock.path_for(_probe)
	if DirAccess.make_dir_absolute(ProjectSettings.globalize_path(lock)) != OK:
		_fail("could not plant a foreign lock at %s" % lock)
		return
	var stamp := FileAccess.open(FileLock.owner_path(lock), FileAccess.WRITE)
	if stamp == null:
		_fail("could not stamp the foreign lock")
		FileLock.remove_dir(lock)
		return
	stamp.store_string("another-client")
	stamp.close()
	# The stamp above was written by THIS process, so drop the local bookkeeping:
	# without it FileLock.owns() would answer for a lock we do not hold.
	FileLock.clear_for_test()

	var live := BootRecovery._write_tmp_path(_probe)
	_write_text(live, "the lock holder is mid-write here")
	var refused := BootRecovery.save_state(_probe, _state())
	if refused["ok"] as bool:
		_fail("save succeeded while another writer held the lock")
	if not FileAccess.file_exists(live):
		_fail("an unlocked sweep destroyed the lock holder's live staging file")

	_remove(live)
	FileLock.remove_dir(lock)
	FileLock.clear_for_test()
	_remove(_probe)


## A minimal state every write-side predicate accepts.
func _state() -> Dictionary:
	var state := BootRecovery.fresh_state()
	state["last_good"] = "0.1.15"
	return state


## Every staging file for the probe, matched by prefix.
func _stages() -> Array[String]:
	var found: Array[String] = []
	var parent := _probe.get_base_dir()
	var prefix := _probe.get_file() + BootRecovery.WRITE_TMP_SUFFIX
	for entry: String in DirAccess.get_files_at(parent):
		if entry.begins_with(prefix):
			found.append(entry)
	return found


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("could not seed %s" % path)
		return
	file.store_string(text)
	file.close()


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text


func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _fail(message: String) -> void:
	push_error("boot_recovery_staging_test: " + message)
	_failures.append(message)


func _cleanup() -> void:
	BootRecovery.clear_refusals_for_test()
	FileLock.remove_dir(FileLock.path_for(_probe))
	FileLock.clear_for_test()
	_remove(_probe)
	_remove(_probe + ".tmp")
	var parent := _probe.get_base_dir()
	for entry: String in _stages():
		_remove(parent.path_join(entry))


func _exit_tree() -> void:
	_cleanup()
