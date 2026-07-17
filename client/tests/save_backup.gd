class_name TestSaveBackup
## Crash-safe backup/restore of the LIVE character save, for tests that
## exercise the save path. The live save is player state (no-resets law):
## back it up before touching it and put it back whatever happens — and when
## that cannot be guaranteed, REFUSE to run rather than risk the file.
##
## Ownership protocol: a MARKER file exists exactly while a test owns the
## save path (created only after the backup is byte-verified, removed only
## after a successful restore). A stale backup found WITH the marker means
## the live file is test detritus — restore over it. A stale backup WITHOUT
## the marker beside a live file with different bytes could be NEWER player
## state written after a killed run — never overwrite it; refuse and leave
## both files for a human.

const BACKUP := "user://character.json.test-backup"
const MARKER := "user://character.json.test-active"


static func backup() -> bool:
	if FileAccess.file_exists(BACKUP):
		if FileAccess.file_exists(MARKER):
			# The killed run owned the path: the live file is test detritus.
			if not _force_restore():
				return false
		elif not FileAccess.file_exists(CharacterStore.PATH) \
			or _same_bytes(BACKUP, CharacterStore.PATH):
			# Live file never diverged (or is gone): the stale backup is
			# redundant; restoring it loses nothing.
			if not _force_restore():
				return false
		else:
			push_error("stale test backup beside a CHANGED live save and no ownership marker — it may be newer player state; refusing to touch it (recover %s by hand)" % BACKUP)
			return false
	if not FileAccess.file_exists(CharacterStore.PATH):
		return _mark_owned()
	var err := DirAccess.copy_absolute(
		ProjectSettings.globalize_path(CharacterStore.PATH),
		ProjectSettings.globalize_path(BACKUP))
	# Byte-verify the copy: a partial backup left on disk would let a later
	# restore() clobber the live save with a truncated file.
	if err != OK or not _same_bytes(BACKUP, CharacterStore.PATH):
		if FileAccess.file_exists(BACKUP):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(BACKUP))
		return false
	return _mark_owned()


## Releases ownership: puts the live save back and clears the marker. ONLY
## acts while this run's ownership marker exists — an unowned save path is
## never touched, so callers (including last-ditch teardown) can call this
## unconditionally without risk of clobbering newer player state. A false
## return means the player's save still sits at BACKUP — the caller must
## FAIL loudly, never PASS.
static func restore() -> bool:
	if not FileAccess.file_exists(MARKER):
		return true
	return _force_restore()


static func _force_restore() -> bool:
	if FileAccess.file_exists(BACKUP):
		if DirAccess.rename_absolute(
			ProjectSettings.globalize_path(BACKUP),
			ProjectSettings.globalize_path(CharacterStore.PATH)) != OK:
			push_error("could not restore the live save — it remains at %s" % BACKUP)
			return false
	if FileAccess.file_exists(MARKER):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(MARKER))
	return true


static func _mark_owned() -> bool:
	var f := FileAccess.open(MARKER, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string("test owns user://character.json while this file exists")
	f.close()
	return true


static func _same_bytes(a: String, b: String) -> bool:
	return FileAccess.get_file_as_bytes(a) == FileAccess.get_file_as_bytes(b)
