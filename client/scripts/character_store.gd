class_name CharacterStore
## Saves and loads the player's character recipe (user://character.json).
##
## The recipe on disk is player state, so the no-resets law applies in full:
## it is versioned, name-keyed, and forward-only — every client that ever
## shipped must keep reading every recipe it ever wrote. Reading is delegated
## to CharacterFactory's validation (a newer-versioned recipe is refused
## loudly, never half-applied).
##
## The public methods act on the player's real save (PATH); the path-taking
## variants (save_to/load_from) exist so tests can exercise the exact save
## and load logic against a throwaway file WITHOUT ever touching the
## player's character — the no-resets law forbids a test stranding a save.

const PATH := "user://character.json"


static func exists() -> bool:
	return FileAccess.file_exists(PATH)


## Atomic: write a sibling temp file, then rename over the target. A crash
## mid-write must never corrupt the only copy of a character (no-resets law
## — there is no wipe to recover WITH).
static func save_to(path: String, recipe: Dictionary) -> bool:
	var tmp_path := path + ".tmp"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		push_error("CharacterStore: cannot write %s" % tmp_path)
		return false
	file.store_string(JSON.stringify(recipe, "  "))
	file.close()
	var err := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(tmp_path), ProjectSettings.globalize_path(path))
	if err != OK:
		push_error("CharacterStore: atomic replace failed (%d)" % err)
		return false
	return true


## The recipe stored at path, or null when none exists or it cannot be parsed.
static func load_from(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return CharacterFactory.load_recipe(path)


static func save_recipe(recipe: Dictionary) -> bool:
	return save_to(PATH, recipe)


static func load_saved() -> Variant:
	return load_from(PATH)


static func clear() -> void:
	if exists():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
