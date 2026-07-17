class_name SaveIsolation
extends RefCounted
## Points the game's save at a throwaway file for a boot test, so exercising
## the first-run character creator can NEVER touch the player's real character
## (no-resets law: a test must never be able to strand a save).
##
## This replaces the old back-up-and-restore dance. That dance cleared the real
## user://character.json, booted, and put it back on exit — but a test killed
## mid-run left the only copy parked at a `.test-backup` the game never restores.
## Here the game is REDIRECTED (CharacterStore.save_path() reads WAR_SAVE_PATH)
## before the scene loads, so the real save is never cleared, moved, or written:
## a killed run leaves it exactly where it was.
##
## Usage — in a boot test's _ready(), before instantiating main.tscn:
##     _save := SaveIsolation.new("user://<name>_boot_probe.json")
##     if not _save.begin():
##         _fail("save isolation did not take — refusing to boot into the real save")
##     ...
## and on every exit path assert the guarantee:
##     if not _save.real_save_untouched():
##         _fail("the boot test touched the player's real save")

var _probe: String
var _default_before_exists: bool
var _default_before_sha: String


func _init(probe_path: String) -> void:
	_probe = probe_path


## Redirect the game's save to the throwaway probe and record the real save's
## state so the test can prove it stayed byte-identical. Starts from a clean
## probe so the boot exercises the first-run creator. Returns false (fail
## closed) if the redirect did not take — the caller must not boot then.
func begin() -> bool:
	if FileAccess.file_exists(_probe):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_probe))
	_default_before_exists = FileAccess.file_exists(CharacterStore.DEFAULT_PATH)
	_default_before_sha = _sha(CharacterStore.DEFAULT_PATH)
	OS.set_environment(CharacterStore.SAVE_PATH_ENV, _probe)
	return CharacterStore.save_path() == _probe


## True when the real save is exactly as it was before the test (existence AND
## bytes) — the isolation guarantee. Clears the seam and removes the probe
## whatever the answer, so nothing leaks into the next test.
func real_save_untouched() -> bool:
	var still_exists := FileAccess.file_exists(CharacterStore.DEFAULT_PATH)
	var still_sha := _sha(CharacterStore.DEFAULT_PATH)
	end()
	return still_exists == _default_before_exists and still_sha == _default_before_sha


## Remove the throwaway probe and clear the seam (idempotent, safe to call more
## than once — e.g. from both a fail path and tree teardown).
func end() -> void:
	OS.set_environment(CharacterStore.SAVE_PATH_ENV, "")
	if FileAccess.file_exists(_probe):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_probe))


func _sha(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_sha256(path)
