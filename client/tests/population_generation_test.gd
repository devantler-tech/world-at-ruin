extends Node
## Compare shipped order and forced collisions to independently captured base
## records. Positions/yaw use tolerances; recipe hashes bind draw schedules.
var _boot: IsolatedBoot
var _main: Node
var _failed := false

func _ready() -> void:
	_boot = IsolatedBoot.new("user://population_generation_probe.json")
	_main = _boot.boot()
	if _main == null:
		_fail("isolation did not take")
		return
	add_child(_main)
	var world := _main.get_node("World")
	var actual := {"npcs": _records(_main.get_node("Npcs"), false),
		"creatures": _records(_main.get_node("Creatures"), true)}
	# Seed every initial name plus its first suffix, forcing repeated collisions.
	# The literal records were captured from unchanged public spawners.
	var npc := NpcSpawner.new()
	npc.npc_names = (_main.get_node("Npcs") as NpcSpawner).npc_names.duplicate()
	npc.npc_names.append("Marinma")
	_main.add_child(npc)
	npc.populate(world)
	actual["npc_collisions"] = _records(npc, false)
	var creature := CreatureSpawner.new()
	creature.creature_names = (_main.get_node("Creatures") as CreatureSpawner).creature_names.duplicate()
	_main.add_child(creature)
	creature.populate(world)
	actual["creature_collisions"] = _records(creature, true)
	var expected = JSON.parse_string(FileAccess.get_file_as_string("res://tests/data/population_generation.json"))
	_check(expected is Dictionary, "baseline records missing")
	if expected is Dictionary:
		for family: String in ["npcs", "creatures", "npc_collisions", "creature_collisions"]:
			var rows: Array = actual[family]
			var golden: Array = expected[family]
			_check(rows.size() == golden.size(), family + " census changed")
			for i in mini(rows.size(), golden.size()):
				_check(rows[i]["name"] == golden[i]["name"] and rows[i]["recipe"] == golden[i]["recipe"],
					family + " name/recipe draw schedule changed at " + str(i))
				var pos: Array = golden[i]["position"]
				var observed: Array = rows[i]["position"]
				_check(Vector3(observed[0], observed[1], observed[2]).distance_to(Vector3(pos[0], pos[1], pos[2])) < 0.001,
					family + " placement changed")
				_check(absf(rows[i]["yaw"] - golden[i]["yaw"]) < 0.0001, family + " yaw changed")
	if not _boot.real_save_untouched():
		_fail("population contract touched player state")
		return
	if not _failed:
		print("TEST PASS — ordered names, recipes, positions and rotations retain baseline and collision draws")
		get_tree().quit(0)

func _records(spawner: Node, creature: bool) -> Array:
	var rows: Array = []
	for root: Node3D in spawner.get_children():
		var name_key := String(root.name).trim_prefix("Hound_" if creature else "Npc_")
		var archetype := NpcGen.ARCHETYPE_VILLAGER if rows.size() < NpcSpawner.SETTLEMENT_COUNT else NpcGen.ARCHETYPE_DRIFTER
		var recipe := CreatureGen.recipe_for(name_key) if creature else NpcGen.recipe_for(name_key, archetype)
		rows.append({"name": name_key, "recipe": JSON.stringify(recipe).sha256_text(),
			"position": [root.position.x, root.position.y, root.position.z], "yaw": root.rotation.y})
	return rows

func _check(ok: bool, message: String) -> void:
	if not ok:
		_fail(message)

func _fail(message: String) -> void:
	_failed = true
	if _boot != null and not _boot.real_save_untouched():
		message += " — population failure also breached player-state isolation"
	push_error("TEST FAIL — " + message)
	get_tree().quit(1)

func _exit_tree() -> void:
	if _boot != null:
		_boot.end()
