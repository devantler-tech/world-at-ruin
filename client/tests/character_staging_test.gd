extends Node
## Regression test for #429: a character write must not stage through a name
## another process can derive.
##
## `CharacterStore.save_to()` used to commit from `<path>.tmp`. That name is
## derivable, so a second client — a rollback build the updater keeps runnable, a
## sync agent, a second install — opens the same path and can truncate our staged
## recipe after we serialised it and before the rename. The TARGET is untouched
## until that rename, so `can_write()` and the pre-rename re-check both pass and
## the rename commits the other writer's partial bytes over the character. There
## is no wipe to recover with (no-resets law), so this is unrecoverable loss.
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
##  4. An abandoned stage past the age window is reclaimed.
##  5. An abandoned stage INSIDE the age window is kept. This is the safety half
##     of the sweep and the one place this deliberately departs from the vault:
##     the vault sweeps under its write lock and so may delete anything it finds,
##     while the character store has no lock yet (#423), so a young staging file
##     may be a live write by a second client. Deleting it would cause exactly
##     the corruption this change removes.
##
## The probe is namespaced by process id: git worktrees do not isolate Godot's
## project-wide user:// directory, so two local test processes sharing a fixed
## probe name would remove and replace one another's evidence.
##
## Run: godot --headless --path client res://tests/character_staging_test.tscn

var _probe: String
var _failures: Array[String] = []


func _ready() -> void:
	_probe = "user://character_staging_probe.process-%d.json" % OS.get_process_id()
	_cleanup()

	var recipe = CharacterFactory.load_recipe("res://recipes/wanderer.json")
	if recipe is not Dictionary:
		_fail("wanderer preset unreadable — cannot exercise a save")
		return

	_check_name_is_private()
	_check_foreign_stage_survives(recipe)
	_check_no_stage_left_behind(recipe)
	_check_abandoned_stage_reclaimed(recipe)
	_check_live_stage_kept(recipe)

	_cleanup()
	if _failures.is_empty():
		print("TEST PASS — character staging is private (5 checks)")
		get_tree().quit(0)
		return
	print("TEST FAIL — %s" % "; ".join(_failures))
	get_tree().quit(1)


## 1. The staging name is private to one attempt.
func _check_name_is_private() -> void:
	var first := CharacterStore._write_tmp_path(_probe)
	var second := CharacterStore._write_tmp_path(_probe)
	if first == _probe + ".tmp":
		_fail("staging name is the derivable <path>.tmp")
	if first == second:
		_fail("two staging attempts share one name (%s)" % first)
	if not first.begins_with(_probe + CharacterStore.WRITE_TMP_SUFFIX):
		_fail("staging name does not carry the sweepable prefix (%s)" % first)
	if not first.contains(str(OS.get_process_id())):
		_fail("staging name does not carry this process id (%s)" % first)


## 2. A foreign writer's derivable stage survives a save untouched.
##
## This is the behavioural proof, and the one that goes RED on the old code:
## there, save_to() opened this exact path with FileAccess.WRITE (truncating the
## planted bytes) and then renamed it onto the target, so the file was consumed.
func _check_foreign_stage_survives(recipe: Dictionary) -> void:
	var foreign := _probe + ".tmp"
	var foreign_bytes := "a second client's half-written recipe"
	_write_text(foreign, foreign_bytes)

	if not CharacterStore.save_to(_probe, recipe):
		_fail("save failed while a foreign stage was present")
		_remove(foreign)
		return
	if not FileAccess.file_exists(foreign):
		_fail("the save consumed a foreign writer's %s" % foreign)
	elif _read_text(foreign) != foreign_bytes:
		_fail("the save overwrote a foreign writer's staged bytes")
	if CharacterStore.load_from(_probe) == null:
		_fail("the character did not land while a foreign stage was present")

	_remove(foreign)
	_remove(_probe)


## 3. A completed save leaves no staging file — matched BY PREFIX, never by the
## fixed name (the vacuity trap #424 measured).
func _check_no_stage_left_behind(recipe: Dictionary) -> void:
	if not CharacterStore.save_to(_probe, recipe):
		_fail("save failed on a clean path")
		return
	var leftovers := _stages()
	if not leftovers.is_empty():
		_fail("save left staging files behind: %s" % ", ".join(leftovers))
	_remove(_probe)


## 4. A stage older than the window is reclaimed.
func _check_abandoned_stage_reclaimed(recipe: Dictionary) -> void:
	var abandoned := CharacterStore._write_tmp_path(_probe)
	_write_text(abandoned, "bytes a crashed writer left behind")
	# A just-written file cannot be aged from GDScript, so the window is moved to
	# it: 0 makes every stage immediately eligible.
	OS.set_environment(CharacterStore.WRITE_TMP_MIN_AGE_ENV, "0")
	if CharacterStore.write_tmp_min_age_seconds() != 0:
		_fail("the staging window override did not take")
	if not CharacterStore.save_to(_probe, recipe):
		_fail("save failed with an abandoned stage present")
	if FileAccess.file_exists(abandoned):
		_fail("an abandoned stage past the window was not reclaimed")
	OS.set_environment(CharacterStore.WRITE_TMP_MIN_AGE_ENV, "")
	_remove(abandoned)
	_remove(_probe)


## 5. A stage inside the window is KEPT — it may be a second client's live write.
##
## Runs with the shipped window (the override is cleared above), so the planted
## file is seconds old and must survive. Deleting it is the failure this age
## floor exists to prevent, and the vault's lock-gated sweep would do exactly
## that if copied here unchanged.
func _check_live_stage_kept(recipe: Dictionary) -> void:
	if CharacterStore.write_tmp_min_age_seconds() != CharacterStore.WRITE_TMP_MIN_AGE_SECONDS:
		_fail("the shipped staging window did not restore after the override")
	var live := CharacterStore._write_tmp_path(_probe)
	_write_text(live, "a second client is mid-write here")
	if not CharacterStore.save_to(_probe, recipe):
		_fail("save failed with a live stage present")
	if not FileAccess.file_exists(live):
		_fail("the sweep destroyed a second client's live staging file")
	_remove(live)
	_remove(_probe)


## Every staging file for the probe, matched by prefix.
func _stages() -> Array[String]:
	var found: Array[String] = []
	var parent := _probe.get_base_dir()
	var prefix := _probe.get_file() + CharacterStore.WRITE_TMP_SUFFIX
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
	push_error("character_staging_test: " + message)
	_failures.append(message)


func _cleanup() -> void:
	OS.set_environment(CharacterStore.WRITE_TMP_MIN_AGE_ENV, "")
	_remove(_probe)
	_remove(_probe + ".tmp")
	var parent := _probe.get_base_dir()
	for entry: String in _stages():
		_remove(parent.path_join(entry))


func _exit_tree() -> void:
	_cleanup()
