extends Node
## Boot test for the failed-apply body revert (issue #423): when the character
## creator's apply does not reach disk, the player must be left looking at the
## character that IS on disk — not the edit that was never recorded.
##
## This is the end-to-end half `character_lock_test` cannot reach. That test
## proves the STORE refuses a contended write and leaves the recipe byte-intact,
## but it would still pass if `main.gd` never put the body back: the store would
## be perfect, and the creator — which previews every slider on the live player
## as it moves, and tears itself down whether or not the apply callback returned
## early — would leave a character on screen that the next launch will not show.
## That is exactly the "told they were saved when they were not" harm the notice
## beside it exists to prevent, and only driving the real scene's apply callback
## can see it.
##
## Three arms on ONE boot. A and B differ ONLY by whether the write lock is held;
## C holds the lock like B and differs only in having no recipe on disk:
##  A. CONTROL — lock FREE. Applying the edit must SUCCEED and the body on screen
##     must show the EDITED weight. Without this, arm B's "shows the on-disk
##     weight" would pass just as well on a main.gd whose apply never reached the
##     player at all, and on a fixture whose two weights are indistinguishable.
##  B. POSITIVE — lock HELD by a competing writer. The apply must fail, the body
##     must be back to the ON-DISK weight, the recipe bytes must be untouched,
##     the creator must NOT latch shut (contention is momentary, not a refusal),
##     and the player must be told without being blamed for a second copy of the
##     game that may not be running.
##  C. NO DISK RECIPE — the same contended apply with nothing on disk (a first
##     run, or a save deleted while the creator was open). There is no recorded
##     character to go back to, so the body must return to what the creator
##     OPENED with — the preset — and not stay on the edit. This is the one case
##     the player cannot check for themselves, since there is no saved character
##     to compare against, and it is the path `load_saved()` cannot answer for.
##
## The competing writer is simulated by creating the lock directory directly.
## That is not an approximation: the lock IS a directory, so one created here is
## indistinguishable from one another process took (same device as
## `character_lock_test`).
##
## The apply is driven by emitting the creator's own `applied` signal rather than
## moving sliders. That signal IS the boundary under test — everything below it
## is main.gd's callback, which is the code this test exists for.
##
## The two weights are deliberately far apart (0.9 vs 0.1). A pair close together
## would let a body that was never reverted still land within tolerance of the
## on-disk value, and the test would pass while the bug shipped.
##
## Runs behind SaveIsolation, so the player's own character, vault and recovery
## ledger are never read or written (no-resets law).
##
## Run: godot --headless --path client res://tests/character_revert_boot_test.tscn

const PROBE_PATH := "user://character_revert_boot_probe.json"
const MAIN_SCENE_PATH := "res://scenes/main.tscn"
## The blend shape both arms read. Present on the base body, and driven straight
## from `recipe["shapes"]` with no remapping, so the recipe weight and the mesh
## weight are the same number.
const SIGNAL_SHAPE := "torso_vshape"
## Far apart on purpose — see the fixture note above.
const ON_DISK_WEIGHT := 0.9
const EDITED_WEIGHT := 0.1
## The shipped preset the creator falls back to when nothing is on disk, read at
## run time rather than copied here as a number: the value lives in that file,
## and a hard-coded duplicate would fail this arm for the wrong reason the day
## the preset is retuned. Arm C guards that it is distinct from
## [constant EDITED_WEIGHT] before relying on it.
const PRESET_PATH := "res://recipes/wanderer.json"
## Deferred boot wiring needs idle frames; give it many.
const BOOT_TICK := 30

var _ticks := 0
var _main: Node
var _save: SaveIsolation
## Which arm runs next: 0 = control, 1 = revert-to-disk, 2 = revert-with-no-disk.
var _arm := 0
## The on-disk recipe's bytes, to prove the refused apply left them alone.
var _seeded_sha := ""


func _ready() -> void:
	_save = SaveIsolation.new(PROBE_PATH)
	if not _save.begin():
		_fail("save isolation did not take — refusing to boot into the real save")
		return
	CharacterStore.clear_refusals_for_test()
	if not _seed_on_disk():
		return
	_main = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	add_child(_main)


## Write the recipe the player "already has", through the store's own writer, so
## the fixture is a recipe this build genuinely accepts.
func _seed_on_disk() -> bool:
	var recipe := _recipe(ON_DISK_WEIGHT)
	if not CharacterStore.save_recipe(recipe):
		_fail("could not seed the on-disk recipe — every later assertion would be about nothing")
		return false
	_seeded_sha = FileAccess.get_sha256(CharacterStore.save_path())
	if _seeded_sha.is_empty():
		_fail("the seeded recipe could not be read back")
		return false
	return true


## The wanderer preset with the signal shape pinned to `weight`. Built from the
## shipped preset rather than hand-rolled so the body actually composes.
func _recipe(weight: float) -> Dictionary:
	var loaded = CharacterFactory.load_recipe(PRESET_PATH)
	if loaded is not Dictionary:
		return {}
	var recipe: Dictionary = (loaded as Dictionary).duplicate(true)
	recipe.erase("comment")
	var shapes: Dictionary = recipe.get("shapes", {})
	shapes[SIGNAL_SHAPE] = weight
	recipe["shapes"] = shapes
	return recipe


func _physics_process(_delta: float) -> void:
	if _main == null:
		return
	_ticks += 1
	if _ticks < BOOT_TICK:
		return
	match _arm:
		0: _assert_control()
		1: _assert_revert()
		_: _assert_revert_without_disk()


## CONTROL: with the lock free, an apply reaches BOTH disk and the body. Without
## this arm, the positive arm proves only that the body never changed — which a
## main.gd that had lost the apply path entirely would also satisfy.
func _assert_control() -> void:
	var creator = _open_creator()
	if creator == null:
		return
	creator.applied.emit(_recipe(EDITED_WEIGHT))
	if bool(_main.get("_save_blocked")):
		_fail("an uncontended apply latched the creator shut")
		return
	var shown := _shown_weight()
	if not is_equal_approx(shown, EDITED_WEIGHT):
		_fail(("an uncontended apply did not reach the body on screen (shape %s reads %f, want %f) — "
			+ "the revert arm would then pass without proving anything")
			% [SIGNAL_SHAPE, shown, EDITED_WEIGHT])
		return
	var persisted = CharacterStore.load_saved()
	if persisted is not Dictionary:
		_fail("an uncontended apply left no readable recipe on disk")
		return
	if not is_equal_approx(float((persisted as Dictionary)["shapes"][SIGNAL_SHAPE]), EDITED_WEIGHT):
		_fail("an uncontended apply did not reach disk — the contention arm would prove nothing")
		return
	# Put the fixture back so the positive arm starts from the on-disk weight
	# again, and re-anchor the byte baseline to what is actually there now.
	_close_creator(creator)
	if not _seed_on_disk():
		return
	_arm = 1
	_ticks = 0


## POSITIVE: a competing writer holds the lock, so the apply cannot be recorded.
## The body must go back to what disk holds, and nothing may latch.
func _assert_revert() -> void:
	var creator = _open_creator()
	if creator == null:
		return
	# The creator previews as it goes: put the EDITED body on screen first, so a
	# main.gd that simply never touched the player would fail this arm. Without
	# it the body would still be showing the on-disk weight for the trivial
	# reason that nothing ever moved it.
	_main.get("_player").set_character(_recipe(EDITED_WEIGHT))
	if not is_equal_approx(_shown_weight(), EDITED_WEIGHT):
		_fail("the pre-apply preview did not take, so a revert cannot be observed")
		return

	var lock := FileLock.path_for(CharacterStore.save_path())
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not simulate a competing writer by taking the lock")
		return
	creator.applied.emit(_recipe(EDITED_WEIGHT))
	DirAccess.remove_absolute(_abs(lock))

	var shown := _shown_weight()
	if not is_equal_approx(shown, ON_DISK_WEIGHT):
		_fail(("a contended apply left the body on the edit that was never recorded "
			+ "(shape %s reads %f, want the on-disk %f) — the player is looking at a "
			+ "character the next launch will not show")
			% [SIGNAL_SHAPE, shown, ON_DISK_WEIGHT])
		return
	if FileAccess.get_sha256(CharacterStore.save_path()) != _seeded_sha:
		_fail("a contended apply modified the recipe it failed to replace")
		return
	# Contention is momentary. Latching here would lock the player out of their
	# own character for the rest of the session over a collision the next
	# attempt resolves.
	if bool(_main.get("_save_blocked")):
		_fail("a contended apply latched the creator shut — that is the refusal path, not contention")
		return
	if CharacterStore.is_refused(CharacterStore.save_path()):
		_fail("a contended apply latched a refusal on a recipe this build can read")
		return
	# The player has to be told, and told something true: this branch cannot know
	# whether a second copy of the game was running, so it must not say one was.
	var toast := _toast_text()
	if toast != String(_main.get("UNSAVED_NOTICE")):
		_fail("a contended apply did not tell the player their character was not saved (toast read %s)"
			% [toast])
		return
	if toast == String(_main.get("REFUSED_SAVE_NOTICE")):
		_fail("a contended apply told the player their save had been permanently refused")
		return
	_close_creator(creator)
	_arm = 2
	_ticks = 0


## ARM C: the same contended apply with NOTHING on disk. `load_saved()` cannot
## answer here, so the body must fall back to the recipe the creator opened with
## — the preset — rather than keeping an edit that was never recorded.
func _assert_revert_without_disk() -> void:
	# Remove the recipe directly rather than through clear(): clear() takes the
	# same write lock this arm is about to hold, and the arm is about the ABSENCE
	# of a recipe, not about how it came to be absent.
	DirAccess.remove_absolute(_abs(CharacterStore.save_path()))
	if CharacterStore.load_saved() is Dictionary:
		_fail("the recipe survived removal, so this arm would not be testing the no-disk path")
		return

	var preset = CharacterFactory.load_recipe(PRESET_PATH)
	if preset is not Dictionary:
		_fail("the preset is unreadable, so there is no expected fallback to assert against")
		return
	var preset_weight := float((preset as Dictionary)["shapes"][SIGNAL_SHAPE])
	# Without this the arm is vacuous whenever the preset happens to carry the
	# edited weight: "went back to the preset" and "stayed on the edit" would be
	# the same number, and the assertion below would pass on broken code.
	if is_equal_approx(preset_weight, EDITED_WEIGHT):
		_fail(("the preset's %s (%f) equals the edited weight — this arm cannot separate a revert "
			+ "from a body that never moved; pick a different signal shape")
			% [SIGNAL_SHAPE, preset_weight])
		return

	var creator = _open_creator()
	if creator == null:
		return
	# Same preview-first discipline as arm B: move the body OFF the value being
	# asserted, or "shows the preset" would be true for the trivial reason that
	# nothing ever changed it.
	_main.get("_player").set_character(_recipe(EDITED_WEIGHT))
	if not is_equal_approx(_shown_weight(), EDITED_WEIGHT):
		_fail("the pre-apply preview did not take, so a revert cannot be observed")
		return

	var lock := FileLock.path_for(CharacterStore.save_path())
	if DirAccess.make_dir_absolute(_abs(lock)) != OK:
		_fail("could not simulate a competing writer by taking the lock")
		return
	creator.applied.emit(_recipe(EDITED_WEIGHT))
	DirAccess.remove_absolute(_abs(lock))

	var shown := _shown_weight()
	if not is_equal_approx(shown, preset_weight):
		_fail(("a contended apply with no recipe on disk left the body on the edit "
			+ "(shape %s reads %f, want the preset %f) — the notice says nothing changed "
			+ "while the player is looking at something that was never recorded, and with "
			+ "no saved character they cannot discover otherwise")
			% [SIGNAL_SHAPE, shown, preset_weight])
		return
	if CharacterStore.exists():
		_fail("a contended apply created a recipe it had failed to write")
		return
	if bool(_main.get("_save_blocked")):
		_fail("a contended apply with no recipe on disk latched the creator shut")
		return
	if _toast_text() != String(_main.get("UNSAVED_NOTICE")):
		_fail("a contended apply with no recipe on disk did not tell the player (toast read %s)"
			% [_toast_text()])
		return
	if not _save.real_save_untouched():
		_fail("the boot test touched the player's real save, vault or recovery ledger")
		return
	_main.queue_free()
	_main = null
	print("TEST PASS — an apply that never reached disk puts the body back to the recorded "
		+ "character, falls back to the opening recipe when there is none, leaves the recipe "
		+ "byte-intact, and does not latch the creator shut")
	get_tree().quit(0)


## Open the real scene's creator and hand back the node, or fail and return null.
func _open_creator() -> Node:
	_main.call("_open_creator", false)
	var creator = _main.get("_creator")
	if creator == null:
		_fail("the character creator did not open over a recipe this build accepts")
		return null
	return creator


## Let main.gd drop its reference the way a real close does, then free the node.
func _close_creator(creator: Node) -> void:
	creator.closed.emit()
	creator.queue_free()


## The signal shape's weight on the body the player is actually looking at.
## Read off the live mesh rather than any recipe the test holds, so this asserts
## what a player would see. -1.0 when there is no body or no such shape, which no
## arm accepts.
func _shown_weight() -> float:
	var player = _main.get("_player")
	if player == null:
		return -1.0
	var mesh: MeshInstance3D = player.character_mesh()
	if mesh == null:
		return -1.0
	var idx := mesh.find_blend_shape_by_name(SIGNAL_SHAPE)
	if idx < 0:
		return -1.0
	return mesh.get_blend_shape_value(idx)


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


func _abs(path: String) -> String:
	return ProjectSettings.globalize_path(path)


func _fail(message: String) -> void:
	# real_save_untouched() clears the seams itself, so it REPLACES the bare
	# end() rather than adding a second teardown (#326).
	if _save != null and not _save.real_save_untouched():
		message += (" — AND the run touched the player's real save, vault or recovery ledger; "
			+ "the isolation breach outranks the failure above")
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
