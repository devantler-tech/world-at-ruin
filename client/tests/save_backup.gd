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
	return DirAccess.copy_absolute(
		ProjectSettings.globalize_path(CharacterStore.PATH),
		ProjectSettings.globalize_path(BACKUP)) == OK


static func restore() -> void:
	if FileAccess.file_exists(BACKUP):
		DirAccess.rename_absolute(
			ProjectSettings.globalize_path(BACKUP),
			ProjectSettings.globalize_path(CharacterStore.PATH))
