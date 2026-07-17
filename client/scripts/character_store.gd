class_name CharacterStore
## Saves and loads the player's character recipe (user://character.json).
##
## The recipe on disk is player state, so the no-resets law applies in full:
## it is versioned, name-keyed, and forward-only — every client that ever
## shipped must keep reading every recipe it ever wrote. Reading is delegated
## to CharacterFactory's validation (a newer-versioned recipe is refused
## loudly, never half-applied).

const PATH := "user://character.json"


static func exists() -> bool:
	return FileAccess.file_exists(PATH)


## Atomic: write a sibling temp file, then rename over the save. A crash
## mid-write must never corrupt the only copy of a character (no-resets law
## — there is no wipe to recover WITH).
static func save_recipe(recipe: Dictionary) -> bool:
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
	if exists():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
