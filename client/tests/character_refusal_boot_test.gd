extends Node
## Boot test for character-recipe refusal (issue #333, parent #3): a character
## this build cannot accept survives the boot untouched.
##
## This is the end-to-end half `character_refusal_test` cannot reach. That test
## proves the store latches a refusal and refuses the write, but it would still
## pass if `main.gd` never asked: the store would be perfect and the game would
## open its writable first-run creator over the file anyway. Only booting the real
## scene against a pre-seeded, unacceptable recipe shows the wiring is live.
##
## Two boots, because the positive case is worthless alone:
##  A. CONTROL — boot with NO recipe on disk and require the first-run creator to
##     OPEN. Without this, "the creator did not open" in B could equally mean the
##     creator never opens on any boot, and a main.gd that had lost the first-run
##     path entirely would pass.
##  B. POSITIVE — boot with a recipe from a NEWER build seeded on disk and require
##     that the creator did NOT open, that the boot said so, and that the seeded
##     bytes are byte-identical afterwards. That last assertion is the promise the
##     no-resets law actually makes: the rollback case is a real character written
##     by a build the player will go back to.
##
## Both boots run behind SaveIsolation — driven directly rather than through
## IsolatedBoot, because the recipe fixture has to be seeded BETWEEN the redirect
## and the boot — so the player's own character, vault and recovery ledger are
## never read or written (no-resets law).
##
## Run: godot --headless --path client res://tests/character_refusal_boot_test.tscn

const PROBE_PATH := "user://character_refusal_boot_probe.json"
const MAIN_SCENE_PATH := "res://scenes/main.tscn"
## Deferred first-run creator entry needs an idle frame; give it many.
const ASSERT_TICK := 30

var _ticks := 0
var _main: Node
var _save: SaveIsolation
## false = the control boot, true = the seeded-refusal boot.
var _seeded := false
## The seeded recipe's bytes, to prove the boot left them alone.
var _seeded_sha := ""


func _ready() -> void:
	_begin_boot(false)


## Redirect the save seams, optionally seed a recipe this build must refuse,
## then boot the real production scene.
func _begin_boot(seeded: bool) -> void:
	_seeded = seeded
	_ticks = 0
	if _main != null:
		_main.queue_free()
		_main = null
	_save = SaveIsolation.new(PROBE_PATH)
	if not _save.begin():
		_fail("save isolation did not take — refusing to boot into the real save")
		return
	# The latch is process-long by design, so the control boot's reads must not
	# leak into the seeded boot (and vice versa).
	CharacterStore.clear_refusals_for_test()
	if seeded:
		var recipe = CharacterFactory.load_recipe("res://recipes/wanderer.json")
		if recipe is not Dictionary:
			_fail("wanderer preset unreadable")
			return
		var future: Dictionary = (recipe as Dictionary).duplicate(true)
		future.erase("comment")
		future["version"] = CharacterFactory.RECIPE_VERSION + 1
		# Written raw: the store's own writer correctly refuses this file, and
		# the fixture has to exist before the game reads it.
		var file := FileAccess.open(CharacterStore.save_path(), FileAccess.WRITE)
		if file == null:
			_fail("could not seed the refused-recipe probe")
			return
		file.store_string(JSON.stringify(future, "  "))
		file.close()
		_seeded_sha = FileAccess.get_sha256(CharacterStore.save_path())
		if _seeded_sha.is_empty():
			_fail("the seeded probe could not be read back")
			return
	_main = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	add_child(_main)


func _physics_process(_delta: float) -> void:
	if _main == null:
		return
	_ticks += 1
	if _ticks < ASSERT_TICK:
		return
	if not _seeded:
		_assert_control()
	else:
		_assert_refusal()


## CONTROL: no character on disk is a first run — the creator must open.
func _assert_control() -> void:
	var creator = _main.get("_creator")
	if creator == null:
		_fail("the first-run creator did not open on a boot with no character — "
			+ "the refusal assertions would then prove nothing")
		return
	if bool(_main.get("_save_blocked")):
		_fail("a boot with no character blocked the creator — that is the first-run path")
		return
	# CONTROL for the notice: a first run must not accuse the game of refusing
	# anything, or the positive assertion would pass on a boot that always says it.
	if _toast_text() == _main.get("REFUSED_SAVE_NOTICE"):
		_fail("a boot with no character told the player their save had been refused")
		return
	if not _check_refusal_discovered_after_boot():
		return
	if not _save.real_save_untouched():
		_fail("the control boot touched the player's real save or vault")
		return
	_begin_boot(true)


## POSITIVE: a recipe from a newer build is existing player state. No writable
## path may open, the player must be told, and the bytes must be exactly as
## they were.
func _assert_refusal() -> void:
	var creator = _main.get("_creator")
	if creator != null:
		_fail("the writable character creator opened over a refused recipe")
		return
	if not bool(_main.get("_save_blocked")):
		_fail("the boot did not lock character writing after refusing the saved recipe")
		return
	# The player has to be TOLD. Refusing silently leaves someone staring at a
	# body that is not theirs with nothing to explain it, which is its own harm.
	if _toast_text() != _main.get("REFUSED_SAVE_NOTICE"):
		_fail("the boot did not tell the player their character was left alone (toast read %s)"
			% [_toast_text()])
		return
	if not CharacterStore.is_refused(CharacterStore.save_path()):
		_fail("the boot did not latch the refusal, so a later write could still replace the recipe")
		return
	var after := FileAccess.get_sha256(CharacterStore.save_path())
	if after != _seeded_sha:
		_fail("the boot modified a recipe it had refused (%s -> %s)" % [_seeded_sha, after])
		return
	# The store must still refuse a direct write, not merely the creator door.
	if CharacterStore.save_recipe({ "version": 1 }):
		_fail("a write was accepted over a refused recipe after boot")
		return
	if FileAccess.get_sha256(CharacterStore.save_path()) != _seeded_sha:
		_fail("a refused recipe was overwritten by a write that should have been refused")
		return
	if not _save.real_save_untouched():
		_fail("the boot test touched the player's real save or vault")
		return
	_main.queue_free()
	_main = null
	print("TEST PASS — a refused character survives the boot untouched and no writer can replace it")
	get_tree().quit(0)


## A refusal can be discovered AFTER boot: the save is fine at startup and then
## a newer build's client or a bad write replaces it mid-session. Opening the
## editor then must lock, not fall back to the first-run preset — otherwise the
## body on screen changes while the store refuses to persist it, and the player
## is told they were saved when the next launch will show them someone else.
##
## Runs on the control boot, which started with no character, so nothing was
## latched at startup and the refusal here can only come from the new file.
## Returns false when it failed (the caller stops).
func _check_refusal_discovered_after_boot() -> bool:
	var path := CharacterStore.save_path()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("could not seed the post-boot corrupt recipe")
		return false
	file.store_string("{ truncated mid-write")
	file.close()
	var before := FileAccess.get_sha256(path)
	_main.call("_open_creator", false)
	if not bool(_main.get("_save_blocked")):
		_fail("a refusal discovered after boot did not lock the creator")
		return false
	if _toast_text() != _main.get("REFUSED_SAVE_NOTICE"):
		_fail("a refusal discovered after boot did not tell the player")
		return false
	if FileAccess.get_sha256(path) != before:
		_fail("a refusal discovered after boot modified the file")
		return false
	# Leave the probe as the control boot found it, so the isolation assertion
	# and the seeded boot both start clean.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return true


## What the HUD is currently saying to the player, or "" when it has no HUD or
## nothing to say. Read off the live label rather than the notice list, so this
## asserts what a player would actually read.
func _toast_text() -> String:
	var hud = _main.get("_hud")
	if hud == null:
		return ""
	var toast = hud.get("_toast")
	if toast == null:
		return ""
	return String(toast.text)


func _fail(message: String) -> void:
	if _save != null:
		_save.end()
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
