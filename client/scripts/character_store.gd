class_name CharacterStore
## Saves and loads the player's character recipe (user://character.json).
##
## The recipe on disk is player state, so the no-resets law applies in full:
## it is versioned, name-keyed, and forward-only — every client that ever
## shipped must keep reading every recipe it ever wrote. Reading is delegated
## to CharacterFactory's validation (a newer-versioned recipe is refused
## loudly, never half-applied).
##
## MAINTENANCE PROTOCOL (crash-safe): a save-path maintenance operation (the
## regression tests) calls begin_maintenance(), which parks the live save at
## BACKUP (byte-verified) and holds MARKER while it owns PATH, and
## end_maintenance(), which puts the save back and releases both. If the
## owning process dies mid-operation, every public entry point recovers the
## parked file FIRST — so a normal game launch can never load maintenance
## detritus, and an interrupted test can never strand a character. A stale
## backup found WITHOUT the marker beside a live file with different bytes
## could be NEWER player state written after a kill: it is never overwritten;
## maintenance refuses to start instead.

const PATH := "user://character.json"
const BACKUP := PATH + ".test-backup"
const MARKER := PATH + ".test-active"

## True while THIS process legitimately owns PATH (between begin_ and
## end_maintenance) — recovery must not fire on the owner's own reads.
static var _maintenance_active := false


static func exists() -> bool:
	recover_interrupted()
	return FileAccess.file_exists(PATH)


## Atomic: write a sibling temp file, then rename over the save. A crash
## mid-write must never corrupt the only copy of a character (no-resets law
## — there is no wipe to recover WITH).
static func save_recipe(recipe: Dictionary) -> bool:
	# Never write over interrupted-maintenance state: a later recovery would
	# rename the old parked file over this fresh save.
	if not recover_interrupted():
		return false
	var tmp_path := PATH + ".tmp"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		push_error("CharacterStore: cannot write %s" % tmp_path)
		return false
	file.store_string(JSON.stringify(recipe, "  "))
	file.close()
	var err := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(tmp_path), ProjectSettings.globalize_path(PATH))
	if err != OK:
		push_error("CharacterStore: atomic replace failed (%d)" % err)
		return false
	return true


## The saved recipe, or null when none exists or it cannot be parsed.
static func load_saved() -> Variant:
	if not exists():
		return null
	return CharacterFactory.load_recipe(PATH)


static func clear() -> void:
	# exists() recovers interrupted state first, so clearing acts on the
	# player's real file, never on maintenance detritus hiding it.
	if exists():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))


## Puts a parked live save back and releases the marker after an
## INTERRUPTED maintenance run (marker present, no live owner). True when no
## interrupted state remains; false when the parked file could not be
## restored (the marker is kept so the next call retries).
static func recover_interrupted() -> bool:
	if _maintenance_active or not FileAccess.file_exists(MARKER):
		return true
	return _force_restore()


## Takes ownership of PATH for a maintenance run: recovers or refuses stale
## state, parks any live save at BACKUP (byte-verified), and holds MARKER.
## False = ownership NOT taken and the live save untouched; never proceed.
static func begin_maintenance() -> bool:
	if FileAccess.file_exists(MARKER):
		# A previous owner died mid-run: the live file is its detritus.
		if not _force_restore():
			return false
	elif FileAccess.file_exists(BACKUP):
		if not FileAccess.file_exists(PATH) or _same_bytes(BACKUP, PATH):
			# Live file never diverged (or is gone): the stale backup is
			# redundant; restoring it loses nothing.
			if not _force_restore():
				return false
		else:
			push_error("CharacterStore: stale backup beside a CHANGED live save and no ownership marker — it may be newer player state; refusing maintenance (recover %s by hand)" % BACKUP)
			return false
	if FileAccess.file_exists(PATH):
		var err := DirAccess.copy_absolute(
			ProjectSettings.globalize_path(PATH),
			ProjectSettings.globalize_path(BACKUP))
		# Byte-verify the copy: a partial backup left on disk would let a
		# later recovery clobber the live save with a truncated file.
		if err != OK or not _same_bytes(BACKUP, PATH):
			if FileAccess.file_exists(BACKUP):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(BACKUP))
			return false
	var marker := FileAccess.open(MARKER, FileAccess.WRITE)
	if marker == null:
		return false
	marker.store_string("maintenance owns user://character.json while this file exists")
	marker.close()
	_maintenance_active = true
	return true


## Releases ownership: puts the live save back and clears the marker. Safe
## to call unconditionally (including last-ditch teardown) — without an
## owned or interrupted state it does nothing. A false return means the
## player's save still sits at BACKUP — the caller must FAIL loudly, never
## report success.
static func end_maintenance() -> bool:
	if not _maintenance_active and not FileAccess.file_exists(MARKER):
		return true
	return _force_restore()


static func _force_restore() -> bool:
	if FileAccess.file_exists(BACKUP):
		if DirAccess.rename_absolute(
			ProjectSettings.globalize_path(BACKUP),
			ProjectSettings.globalize_path(PATH)) != OK:
			push_error("CharacterStore: could not restore the live save — it remains at %s" % BACKUP)
			return false
	if FileAccess.file_exists(MARKER):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(MARKER))
	_maintenance_active = false
	return true


static func _same_bytes(a: String, b: String) -> bool:
	return FileAccess.get_file_as_bytes(a) == FileAccess.get_file_as_bytes(b)
