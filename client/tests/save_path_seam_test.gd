extends Node
## Regression test for the save-path seam (#41): CharacterStore.save_path()
## resolves the WAR_SAVE_PATH override, so a boot test can redirect the whole
## game's save to a throwaway file and never strand the player's real character
## (no-resets law). This pins the contract the boot tests depend on.
##  1. Inert by default: with no override, save_path() is the shipped default.
##  2. Active override: with WAR_SAVE_PATH set, save_path() is that path.
##  3. Routing: the whole-game save/load path (save_recipe/load_saved/exists/
##     clear) goes to the override, and the shipped default file is never
##     created or changed by it.
##  4. Legacy-backup recovery restores a save an older client's boot test could
##     have stranded, never clobbers a live save, and the production wrapper is
##     inert while an override is active.
##  5. Cleared override goes inert again.
##
## FAIL-CLOSED: every write is gated on save_path() already equalling the probe,
## and the default file's bytes are snapshotted read-only and asserted unchanged.
## So even a regressed seam makes this test FAIL without ever writing the
## player's real save — the test can prove the seam without risking it.
##
## Run: godot --headless --path client res://tests/save_path_seam_test.tscn

const PROBE := "user://save_path_seam_probe.json"
const RTARGET := "user://recover_target_probe.json"
const RBACKUP := "user://recover_backup_probe.json"
const ENV := CharacterStore.SAVE_PATH_ENV

var _default_before_exists: bool
var _default_before_sha: String


func _ready() -> void:
	# Snapshot the shipped default read-only so we can prove nothing here touched
	# it. On a dev machine this is the player's real save; we never write it.
	_default_before_exists = FileAccess.file_exists(CharacterStore.DEFAULT_PATH)
	_default_before_sha = _sha(CharacterStore.DEFAULT_PATH)

	# 1. Inert by default.
	OS.set_environment(ENV, "")
	if CharacterStore.save_path() != CharacterStore.DEFAULT_PATH:
		_fail("unset override should resolve to the shipped default, got %s"
			% CharacterStore.save_path())
		return

	# 2. Active override.
	_cleanup_probe()
	OS.set_environment(ENV, PROBE)
	if CharacterStore.save_path() != PROBE:
		_fail("WAR_SAVE_PATH override did not take — save_path() is %s"
			% CharacterStore.save_path())
		return

	# 3. Routing — GATED on the override being active, so a regressed seam fails
	#    here and no write ever lands on the default (the real save).
	if CharacterStore.exists():
		_fail("a fresh probe should not exist yet")
		return
	var recipe = CharacterFactory.load_recipe("res://recipes/wanderer.json")
	if recipe is not Dictionary:
		_fail("wanderer preset unreadable")
		return
	if CharacterStore.save_path() != PROBE:
		_fail("refusing to save — override not active (would hit the real save)")
		return
	if not CharacterStore.save_recipe(recipe):
		_fail("save_recipe failed under the override")
		return
	if not FileAccess.file_exists(PROBE):
		_fail("save_recipe did not write to the override path")
		return
	if not CharacterStore.exists():
		_fail("exists() does not see the override save")
		return
	var loaded = CharacterStore.load_saved()
	if loaded is not Dictionary:
		_fail("load_saved did not read the override save back")
		return
	var a := CharacterFactory.build(recipe)
	var b := CharacterFactory.build(loaded)
	var same := a != null and b != null \
		and CharacterFactory.fingerprint(a) == CharacterFactory.fingerprint(b)
	if a != null:
		a.free()
	if b != null:
		b.free()
	if not same:
		_fail("round-trip through the override changed the character")
		return

	# clear() also honours the override.
	CharacterStore.clear()
	if CharacterStore.exists() or FileAccess.file_exists(PROBE):
		_fail("clear() did not remove the override save")
		return

	# 4. Legacy-backup recovery: an older client's boot test could strand the
	#    real save at a .test-backup and die before restoring it. The migration
	#    must put it back, but only when no live save exists (never clobber).
	#    Exercised on throwaway probes so the player's real save is never touched.
	_cleanup_probe()
	var stranded = CharacterFactory.load_recipe("res://recipes/wanderer.json")
	if not CharacterStore.save_to(RBACKUP, stranded):
		_fail("could not stage a stranded backup probe")
		return
	var backup_sha := FileAccess.get_sha256(RBACKUP)
	# (a) target absent + backup present -> recovered, backup consumed.
	if not CharacterStore.recover_backup_into(RTARGET, RBACKUP):
		_fail("recover_backup_into did not recover a stranded save")
		return
	if not FileAccess.file_exists(RTARGET) or FileAccess.file_exists(RBACKUP):
		_fail("recovery should MOVE the backup onto the target")
		return
	if FileAccess.get_sha256(RTARGET) != backup_sha:
		_fail("recovered save is not byte-identical to the stranded backup")
		return
	# (b) target present -> no clobber (no-resets law: never overwrite a save).
	if not CharacterStore.save_to(RBACKUP, stranded):
		_fail("could not stage a second stranded backup probe")
		return
	var target_sha := FileAccess.get_sha256(RTARGET)
	if CharacterStore.recover_backup_into(RTARGET, RBACKUP):
		_fail("recovery clobbered an existing save")
		return
	if FileAccess.get_sha256(RTARGET) != target_sha or not FileAccess.file_exists(RBACKUP):
		_fail("no-clobber recovery must leave both files untouched")
		return
	# (c) no backup -> no-op.
	_cleanup_probe()
	if CharacterStore.recover_backup_into(RTARGET, RBACKUP):
		_fail("recovery reported success with no backup present")
		return
	# (d) the production wrapper reports "safe to proceed" and is inert while an
	#     override is active — a redirected test must never let it touch the real
	#     default, nor tell the caller to refuse the creator.
	OS.set_environment(ENV, PROBE)
	var d_exists := FileAccess.file_exists(CharacterStore.DEFAULT_PATH)
	var d_sha := _sha(CharacterStore.DEFAULT_PATH)
	if not CharacterStore.recover_legacy_backup():
		_fail("recover_legacy_backup falsely reported failure under an active override")
		return
	if FileAccess.file_exists(CharacterStore.DEFAULT_PATH) != d_exists \
			or _sha(CharacterStore.DEFAULT_PATH) != d_sha:
		_fail("recover_legacy_backup touched the real default under an active override")
		return

	# 5. Cleared override goes inert again.
	OS.set_environment(ENV, "")
	if CharacterStore.save_path() != CharacterStore.DEFAULT_PATH:
		_fail("clearing the override did not restore the default")
		return

	# The whole test never touched the shipped default file.
	if FileAccess.file_exists(CharacterStore.DEFAULT_PATH) != _default_before_exists \
			or _sha(CharacterStore.DEFAULT_PATH) != _default_before_sha:
		_fail("the seam test changed the shipped default save")
		return

	_cleanup_probe()
	print("TEST PASS — save-path seam resolves, routes, and stays inert by default")
	get_tree().quit(0)


func _fail(message: String) -> void:
	OS.set_environment(ENV, "")
	_cleanup_probe()
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _exit_tree() -> void:
	OS.set_environment(ENV, "")
	_cleanup_probe()


func _cleanup_probe() -> void:
	for p in [PROBE, RTARGET, RBACKUP]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _sha(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_sha256(path)
