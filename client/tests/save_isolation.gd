class_name SaveIsolation
extends RefCounted
## Points the game's save, its progression vault AND its boot-recovery ledger at
## throwaway files for a boot test, so exercising the first-run character
## creator — or anything that writes progression, such as attuning the shrine —
## can NEVER touch the player's real character, progress or recovery history
## (no-resets law: a test must never be able to strand a save).
##
## All three seams are redirected together on purpose. They are separate files
## (SaveVault, #249; BootRecovery, #301) but one test action can write all of
## them: booting main.tscn persists an attunement when the shrine is used, and
## since #301 EVERY boot writes a boot-attempt record. Isolating only the
## character save would leave the real user://vault.json being written by every
## boot test — which is exactly what happened when the vault first landed, and
## the recovery ledger is the same trap one file later: a boot test that marked
## and quarantined the player's REAL installed build would be worse still,
## because quarantine is forward-only and could never be undone.
##
## This replaces the old back-up-and-restore dance. That dance cleared the real
## user://character.json, booted, and put it back on exit — but a test killed
## mid-run left the only copy parked at a `.test-backup` the game never restores.
## Here the game is REDIRECTED (CharacterStore.save_path() reads WAR_SAVE_PATH)
## before the scene loads, so the real save is never cleared, moved, or written:
## a killed run leaves it exactly where it was.
##
## The caller's name is namespaced by the current process ID. Git worktrees do
## not isolate Godot's project-wide `user://` directory, so two local test
## processes using the same fixed probe name would otherwise remove, seed and
## replace one another's evidence. The namespace is chosen once here: every
## synthetic boot phase inside one process still shares the same probe.
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
var _recovery_probe: String
var _default_before_exists: bool
var _default_before_sha: String
var _vault_before_exists: bool
var _vault_before_sha: String
var _recovery_before_exists: bool
var _recovery_before_sha: String


func _init(probe_path: String) -> void:
	var stem := probe_path.trim_suffix(".json")
	_probe = "%s.process-%d.json" % [stem, OS.get_process_id()]
	# Sibling probes, derived so a caller cannot forget to pass one and
	# silently fall back to the player's real vault or recovery ledger.
	_vault_probe = _probe.trim_suffix(".json") + "_vault.json"
	_recovery_probe = _probe.trim_suffix(".json") + "_recovery.json"


## The redirected recovery-ledger path, so a test can seed a prior launch's
## state into it or read back what the boot recorded.
func recovery_probe() -> String:
	return _recovery_probe


## Redirect the game's save to the throwaway probe and record the real save's
## state so the test can prove it stayed byte-identical. Starts from a clean
## probe so the boot exercises the first-run creator. Returns false (fail
## closed) if the redirect did not take — the caller must not boot then.
func begin() -> bool:
	for path in [_probe, _vault_probe, _recovery_probe]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_clear_locks()
	_default_before_exists = FileAccess.file_exists(CharacterStore.DEFAULT_PATH)
	_default_before_sha = _sha(CharacterStore.DEFAULT_PATH)
	_vault_before_exists = FileAccess.file_exists(SaveVault.DEFAULT_PATH)
	_vault_before_sha = _sha(SaveVault.DEFAULT_PATH)
	_recovery_before_exists = FileAccess.file_exists(BootRecovery.DEFAULT_PATH)
	_recovery_before_sha = _sha(BootRecovery.DEFAULT_PATH)
	OS.set_environment(CharacterStore.SAVE_PATH_ENV, _probe)
	OS.set_environment(SaveVault.VAULT_PATH_ENV, _vault_probe)
	OS.set_environment(BootRecovery.RECOVERY_PATH_ENV, _recovery_probe)
	# Fail closed on ALL THREE seams: a redirect that partly took would leave
	# the unredirected part pointing at the real file.
	return (CharacterStore.save_path() == _probe
		and SaveVault.vault_path() == _vault_probe
		and BootRecovery.recovery_path() == _recovery_probe)


## True when the real save, the real vault AND the real recovery ledger are
## exactly as they were before the test (existence AND bytes) — the isolation
## guarantee. Clears every seam and removes every probe whatever the answer, so
## nothing leaks into the next test.
func real_save_untouched() -> bool:
	var still_exists := FileAccess.file_exists(CharacterStore.DEFAULT_PATH)
	var still_sha := _sha(CharacterStore.DEFAULT_PATH)
	var vault_exists := FileAccess.file_exists(SaveVault.DEFAULT_PATH)
	var vault_sha := _sha(SaveVault.DEFAULT_PATH)
	var recovery_exists := FileAccess.file_exists(BootRecovery.DEFAULT_PATH)
	var recovery_sha := _sha(BootRecovery.DEFAULT_PATH)
	end()
	return (still_exists == _default_before_exists and still_sha == _default_before_sha
		and vault_exists == _vault_before_exists and vault_sha == _vault_before_sha
		and recovery_exists == _recovery_before_exists and recovery_sha == _recovery_before_sha)


## Remove the throwaway probes and clear the seams (idempotent, safe to call
## more than once — e.g. from both a fail path and tree teardown).
func end() -> void:
	OS.set_environment(CharacterStore.SAVE_PATH_ENV, "")
	OS.set_environment(SaveVault.VAULT_PATH_ENV, "")
	OS.set_environment(BootRecovery.RECOVERY_PATH_ENV, "")
	for path in [_probe, _vault_probe, _recovery_probe]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_clear_locks()


## Drop every write lock as well as the probe files.
##
## A lock is a DIRECTORY, so the file sweep above cannot see it, and a lock left
## behind by a boot that was killed mid-write would otherwise outlive its test:
## the next test redirecting to the same probe path would find a lock that is not
## yet stale, refuse every write to that file, and fail as though persistence
## were simply not being applied. Clearing the in-process bookkeeping first, then
## the directories, covers both a lock this process still holds and one inherited
## from an earlier run.
##
## BOTH locked probes are swept. Probe paths carry the process id, so an
## inherited lock needs the OS to have reused that pid — which is precisely the
## case [method FileLock._reclaim_if_abandoned] is built around, so it is a real
## possibility here rather than a theoretical one. Sweeping only the vault's
## would leave the recovery ledger's behind, and a stuck recovery lock is the
## worse of the two: it refuses the quarantine write that decides a rollback.
func _clear_locks() -> void:
	FileLock.clear_for_test()
	for locked: String in [_vault_probe, _recovery_probe]:
		FileLock.remove_dir(FileLock.path_for(locked))


func _sha(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_sha256(path)
