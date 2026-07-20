class_name SaveIsolation
extends RefCounted
## Points the game's save AND its progression vault at throwaway files for a
## boot test, so exercising the first-run character creator — or anything that
## writes progression, such as attuning the shrine — can NEVER touch the
## player's real character or progress (no-resets law: a test must never be able
## to strand a save).
##
## Both seams are redirected together on purpose. They are separate files
## (SaveVault, #249) but one test action can write both: booting main.tscn and
## interacting with the shrine persists an attunement. Isolating only the
## character save would leave the real user://vault.json being written by every
## boot test — which is exactly what happened when the vault first landed.
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
##         _fail("the boot test touched the player's real save or vault")

var _probe: String
var _vault_probe: String
var _default_before_exists: bool
var _default_before_sha: String
var _vault_before_exists: bool
var _vault_before_sha: String


func _init(probe_path: String) -> void:
	_probe = probe_path
	# A sibling probe, derived so a caller cannot forget to pass one and
	# silently fall back to the player's real vault.
	_vault_probe = probe_path.trim_suffix(".json") + "_vault.json"


## Redirect the game's save to the throwaway probe and record the real save's
## state so the test can prove it stayed byte-identical. Starts from a clean
## probe so the boot exercises the first-run creator. Returns false (fail
## closed) if the redirect did not take — the caller must not boot then.
func begin() -> bool:
	for path in [_probe, _vault_probe]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_default_before_exists = FileAccess.file_exists(CharacterStore.DEFAULT_PATH)
	_default_before_sha = _sha(CharacterStore.DEFAULT_PATH)
	_vault_before_exists = FileAccess.file_exists(SaveVault.DEFAULT_PATH)
	_vault_before_sha = _sha(SaveVault.DEFAULT_PATH)
	OS.set_environment(CharacterStore.SAVE_PATH_ENV, _probe)
	OS.set_environment(SaveVault.VAULT_PATH_ENV, _vault_probe)
	# Fail closed on BOTH seams: a redirect that half-took would leave the
	# unredirected half pointing at the real file.
	return CharacterStore.save_path() == _probe and SaveVault.vault_path() == _vault_probe


## True when the real save AND the real vault are exactly as they were before
## the test (existence AND bytes) — the isolation guarantee. Clears both seams
## and removes both probes whatever the answer, so nothing leaks into the next
## test.
func real_save_untouched() -> bool:
	var still_exists := FileAccess.file_exists(CharacterStore.DEFAULT_PATH)
	var still_sha := _sha(CharacterStore.DEFAULT_PATH)
	var vault_exists := FileAccess.file_exists(SaveVault.DEFAULT_PATH)
	var vault_sha := _sha(SaveVault.DEFAULT_PATH)
	end()
	return (still_exists == _default_before_exists and still_sha == _default_before_sha
		and vault_exists == _vault_before_exists and vault_sha == _vault_before_sha)


## Remove the throwaway probe and clear the seam (idempotent, safe to call more
## than once — e.g. from both a fail path and tree teardown).
func end() -> void:
	OS.set_environment(CharacterStore.SAVE_PATH_ENV, "")
	OS.set_environment(SaveVault.VAULT_PATH_ENV, "")
	for path in [_probe, _vault_probe]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _sha(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_sha256(path)
