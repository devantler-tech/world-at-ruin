class_name TestSaveBackup
## Crash-safe backup/restore of the LIVE character save, for tests that
## exercise the save path. The live save is player state (no-resets law):
## back it up before touching it and put it back whatever happens. A stale
## backup from a killed run is restored (never clobbered) before a new
## backup is taken, and the copy is verified before anything destructive
## runs.

const BACKUP := "user://character.json.test-backup"


static func backup() -> bool:
	if FileAccess.file_exists(BACKUP):
		# A previous run died before restoring: put the original back first.
		restore()
	if not FileAccess.file_exists(CharacterStore.PATH):
		return true
	var err := DirAccess.copy_absolute(
		ProjectSettings.globalize_path(CharacterStore.PATH),
		ProjectSettings.globalize_path(BACKUP))
	# Byte-verify the copy: a partial backup left on disk would let a later
	# restore() clobber the live save with a truncated file.
	var ok := err == OK and FileAccess.get_file_as_bytes(BACKUP) == \
		FileAccess.get_file_as_bytes(CharacterStore.PATH)
	if not ok and FileAccess.file_exists(BACKUP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(BACKUP))
	return ok


static func restore() -> void:
	if FileAccess.file_exists(BACKUP):
		DirAccess.rename_absolute(
			ProjectSettings.globalize_path(BACKUP),
			ProjectSettings.globalize_path(CharacterStore.PATH))
