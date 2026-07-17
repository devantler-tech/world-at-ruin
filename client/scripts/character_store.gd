class_name CharacterStore
## Saves and loads the player's character recipe (user://character.json).
##
## The recipe on disk is player state, so the no-resets law applies in full:
## it is versioned, name-keyed, and forward-only — every client that ever
## shipped must keep reading every recipe it ever wrote. Reading is delegated
## to CharacterFactory's validation (a newer-versioned recipe is refused
## loudly, never half-applied).
##
## Two seams keep tests off the player's real save (the no-resets law forbids a
## test stranding a character):
##  - save_to/load_from take an explicit path, so a test can exercise the exact
##    save/load logic against a throwaway file (character_persistence_test).
##  - save_path() resolves the location the whole-game path (save_recipe /
##    load_saved / exists / clear) reads, so a BOOT test that must go through
##    the game's own first-run path can point the game at a throwaway file by
##    setting WAR_SAVE_PATH before the scene loads. Shipped, the override is
##    unset and the path is the default below — the seam is inert in production.

const DEFAULT_PATH := "user://character.json"

## Environment override for the active save path. Empty/unset means "use the
## shipped default" — production never sets it; boot tests and a developer
## running the suite on a machine with a played save point it at a temp file.
const SAVE_PATH_ENV := "WAR_SAVE_PATH"


## The active save path: the WAR_SAVE_PATH override when set, else the shipped
## default. Resolved fresh each call so a test can redirect the game before it
## boots; inert (returns DEFAULT_PATH) whenever the override is empty.
static func save_path() -> String:
	var override := OS.get_environment(SAVE_PATH_ENV)
	return override if not override.is_empty() else DEFAULT_PATH


static func exists() -> bool:
	return FileAccess.file_exists(save_path())


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
	return save_to(save_path(), recipe)


static func load_saved() -> Variant:
	return load_from(save_path())


static func clear() -> void:
	if exists():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path()))
