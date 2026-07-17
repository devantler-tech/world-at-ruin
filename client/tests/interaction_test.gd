extends Node
## Regression test for the interaction system (#39): the world answers.
##  1. Interactable.choose is a PURE selector — nearest in-range AND faced
##     wins, out-of-range and turned-away candidates are excluded, ties are
##     deterministic.
##  2. NpcGen.bark_for is deterministic per name and drawn from the archetype's
##     pool (determinism law — a person says the same thing every boot).
##  3. Integration (booted main scene): the shrine and every NPC register an
##     interactable; standing at the shrine and interacting makes it the
##     respawn point (a later respawn wakes there); standing at a person and
##     interacting speaks their seeded line. This drives the real controller
##     end to end — proximity -> prompt target -> interact -> effect.
##
## Run: godot --headless --path client res://tests/interaction_test.tscn

const ASSERT_TICK := 30
const EPS := 0.001

var _ticks := 0
var _main: Node
var _save: SaveIsolation


func _ready() -> void:
	# Pure tests need no scene and never touch player state — run them first,
	# so a logic regression fails fast without booting the world.
	if not _test_choose():
		return
	if not _test_bark_determinism():
		return

	# The integration boot exercises the first-run creator — point the game at a
	# throwaway probe so it never touches the player's real character (no-resets
	# law). Fail closed if the redirect does not take hold.
	_save = SaveIsolation.new("user://interaction_boot_probe.json")
	if not _save.begin():
		_fail("save isolation did not take — refusing to boot into the real save")
		return
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(_main)


# --- 1. pure selector -------------------------------------------------------

func _test_choose() -> bool:
	# Looking +Z: the near candidate in range wins over the far one out of range.
	var pos := PackedVector3Array([Vector3(0, 0, 2), Vector3(0, 0, 5)])
	var rng := PackedFloat32Array([3.0, 3.0])
	var face := PackedFloat32Array([-1.0, -1.0])
	if Interactable.choose(Vector3.ZERO, Vector3(0, 0, 1), pos, rng, face) != 0:
		return _fail("choose: near-in-range candidate should win")

	# Nothing in range -> -1.
	if Interactable.choose(Vector3.ZERO, Vector3(0, 0, 1),
			PackedVector3Array([Vector3(0, 0, 10)]),
			PackedFloat32Array([3.0]), PackedFloat32Array([-1.0])) != -1:
		return _fail("choose: out-of-range candidate must not be selected")

	# A candidate behind you, with a facing gate, is excluded.
	if Interactable.choose(Vector3.ZERO, Vector3(0, 0, 1),
			PackedVector3Array([Vector3(0, 0, -2)]),
			PackedFloat32Array([3.0]), PackedFloat32Array([0.35])) != -1:
		return _fail("choose: turned-away candidate must be excluded by facing gate")

	# Same candidate, but lenient facing (-1) accepts any direction.
	if Interactable.choose(Vector3.ZERO, Vector3(0, 0, 1),
			PackedVector3Array([Vector3(0, 0, -2)]),
			PackedFloat32Array([3.0]), PackedFloat32Array([-1.0])) != 0:
		return _fail("choose: lenient facing should accept a candidate behind you")

	# Two faced, in range: the NEARER wins.
	if Interactable.choose(Vector3.ZERO, Vector3(0, 0, 1),
			PackedVector3Array([Vector3(0, 0, 2.5), Vector3(0, 0, 1.5)]),
			PackedFloat32Array([3.0, 3.0]), PackedFloat32Array([-1.0, -1.0])) != 1:
		return _fail("choose: the nearer of two faced candidates should win")

	return true


# --- 2. seeded barks --------------------------------------------------------

func _test_bark_determinism() -> bool:
	for npc_name in ["Maren", "Torvald", "Ashwyn", "Vela", "Brenok"]:
		for archetype in [NpcGen.ARCHETYPE_VILLAGER, NpcGen.ARCHETYPE_DRIFTER]:
			var a := NpcGen.bark_for(npc_name, archetype)
			var b := NpcGen.bark_for(npc_name, archetype)
			if a != b:
				return _fail("bark_for('%s', %s) is not deterministic" % [npc_name, archetype])
			if a.is_empty():
				return _fail("bark_for('%s', %s) returned an empty line" % [npc_name, archetype])
			var pool: Array = NpcGen.VILLAGER_BARKS if archetype == NpcGen.ARCHETYPE_VILLAGER \
				else NpcGen.DRIFTER_BARKS
			if not pool.has(a):
				return _fail("bark_for('%s', %s) returned a line outside its pool" % [npc_name, archetype])
	return true


# --- 3. integration: the built world answers --------------------------------

func _physics_process(_delta: float) -> void:
	_ticks += 1
	var world := _main.get_node_or_null("World") as WorldGen
	var player := _main.get_node_or_null("Wanderer") as Player
	var controller := _main.get_node_or_null("Interaction") as InteractionController
	var npcs := _main.get_node_or_null("Npcs") as NpcSpawner
	if world == null or player == null or controller == null or npcs == null:
		if _ticks > 10:
			_fail("main scene did not build World, Wanderer, Interaction and Npcs")
		return
	if _ticks != ASSERT_TICK:
		return

	# The first-run creator suppresses control; the interaction verb is what we
	# are testing, so take control for the drive.
	player.control_enabled = true

	# The shrine registered an interactable, and it is the attune prompt.
	var shrine_it := world.shrine_interactable()
	if shrine_it == null or not shrine_it.is_in_group(Interactable.GROUP):
		_fail("the shrine registered no interactable")
		return
	if not shrine_it.prompt.contains("Attune"):
		_fail("shrine prompt is '%s', expected an attune prompt" % shrine_it.prompt)
		return

	# Stand at the shrine's foot, facing the flame: the controller should offer
	# the shrine and nothing else (the people are far outside its reach).
	player.global_position = Vector3(0, world.height_at(0, 4.0) + 0.1, 4.0)
	player.face_toward(Vector3.ZERO)
	if controller.scan() != shrine_it:
		_fail("standing at the shrine, the controller did not target it")
		return

	# The visible payoff: one controller frame at the shrine's foot puts the
	# attune prompt on the HUD (this is what the player actually sees).
	var hud := _main.get_node_or_null("Hud") as Hud
	controller._process(0.0)
	if hud == null or not hud.prompt_shown() or not hud.prompt_text().contains("Attune"):
		_fail("standing at the shrine, no attune prompt appeared (HUD showed '%s')"
			% ("<no hud>" if hud == null else hud.prompt_text()))
		return

	# Walk far away and the prompt clears.
	player.global_position = Vector3(500, 0, 500)
	controller._process(0.0)
	if hud.prompt_shown():
		_fail("the prompt did not clear when nothing was in reach")
		return
	# Back to the shrine for the attune drive.
	player.global_position = Vector3(0, world.height_at(0, 4.0) + 0.1, 4.0)
	player.face_toward(Vector3.ZERO)

	# Attuning makes the shrine the respawn point; a later respawn wakes there.
	var before := player.spawn_point
	shrine_it.trigger(player)
	var attuned := world.shrine_respawn_point()
	if player.spawn_point.distance_to(attuned) > EPS:
		_fail("attuning the shrine did not move the respawn point")
		return
	if before.distance_to(attuned) <= EPS:
		_fail("respawn point did not actually change (cave spawn == shrine spawn?)")
		return
	player.respawn()
	if player.global_position.distance_to(attuned) > EPS:
		_fail("after attuning, respawn did not wake the wanderer at the shrine")
		return

	# The people answer: stand at the first (settlement) NPC, face them, speak.
	var npc_root: Node3D = null
	for child in npcs.get_children():
		if String(child.name).begins_with("Npc_"):
			npc_root = child as Node3D
			break
	if npc_root == null:
		_fail("no NPCs in the world to speak to")
		return
	var talk := npc_root.get_node_or_null("Talk") as Interactable
	if talk == null:
		_fail("%s has no Talk interactable" % npc_root.name)
		return
	var heard := { "name": "", "line": "" }
	npcs.npc_spoke.connect(func(n: String, line: String) -> void:
		heard["name"] = n
		heard["line"] = line)
	var npos := npc_root.global_position
	player.global_position = npos + Vector3(0.5, 0, 0)
	player.face_toward(npos)
	if controller.scan() != talk:
		_fail("standing at %s, the controller did not target them" % npc_root.name)
		return
	talk.trigger(player)
	var nm := String(npc_root.name).substr(4)  # strip "Npc_"
	# Settlement NPCs are added first, so the first Npc_ child is a villager.
	var expected := NpcGen.bark_for(nm, NpcGen.ARCHETYPE_VILLAGER)
	if heard["name"] != nm or heard["line"] != expected:
		_fail("speaking to %s gave ('%s','%s'), expected ('%s','%s')"
			% [nm, heard["name"], heard["line"], nm, expected])
		return

	# Recovery-failure lockout (#41, codex P0): while a stranded save is
	# unrecovered, NO character-creator entry may open — applying one would write
	# the default and orphan the stranded backup. Assert _open_creator is a no-op
	# in that state (the creator reference does not change), covering the manual
	# editor-key door as well as the auto first-run one.
	var creator_before = _main.get("_creator")
	_main.set("_save_blocked", true)
	_main.call("_open_creator", false)
	if _main.get("_creator") != creator_before:
		_fail("the creator opened while the save was blocked — it could overwrite a stranded character")
		return
	_main.set("_save_blocked", false)

	if not _save.real_save_untouched():
		_fail("the boot test touched the player's real save")
		return
	print("TEST PASS — interaction verb drives shrine attunement and NPC speech")
	get_tree().quit(0)


func _fail(message: String) -> bool:
	if _save != null:
		_save.end()
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
	return false


## Clearing the seam on teardown covers the process being killed after the scene
## loaded but before an exit path ran — the redirect never outlives the test.
## Idempotent with the end() the exit paths already call.
func _exit_tree() -> void:
	if _save != null:
		_save.end()
