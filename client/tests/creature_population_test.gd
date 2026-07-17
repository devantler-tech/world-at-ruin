extends Node
## Regression test for the seeded creature pack (creature system pilot, #24):
## the first non-humanoid life stands in the wild, deterministically, on real
## ground and out of the way.
##  1. The main scene builds a "Creatures" node with the expected census.
##  2. Placement law per hound: outside the shrine clear radius, outside cave
##     footprints, off the cave->shrine walk-out line, on real ground
##     (position matches surface_height_at), inside the grid.
##  3. Determinism: node positions equal a fresh recompute of the layout from
##     the same seeds (scatter_spots is a pure function of the world).
##  4. Every hound actually built (has a skeleton).
##  5. Generated recipes are deterministic and valid per the name.
##
## Run: godot --headless --path client res://tests/creature_population_test.tscn

const ASSERT_TICK := 30

var _ticks := 0
var _main: Node


func _ready() -> void:
	# 5. Recipe generation is deterministic and valid (pure — no scene needed).
	var names := ["Ashfang", "Grimmaw", "Vorclaw", "Ashfang"]
	var fingerprints := {}
	for creature_name in names:
		var r1 := CreatureGen.recipe_for(creature_name)
		var r2 := CreatureGen.recipe_for(creature_name)
		if JSON.stringify(r1) != JSON.stringify(r2):
			_fail("recipe for '%s' is not deterministic" % creature_name)
			return
		var built := CreatureFactory.build(r1)
		if built == null:
			_fail("generated recipe for '%s' failed to validate/build: %s" % [creature_name, JSON.stringify(r1)])
			return
		fingerprints[creature_name] = CreatureFactory.fingerprint(built)
		built.free()
	# The same name is the same hound; two different names differ.
	if fingerprints["Ashfang"] == fingerprints["Grimmaw"]:
		_fail("distinct names produced identical hounds — the seed is not name-keyed")
		return

	if not _backup_live_save():
		_fail("could not back up the live character save — refusing to touch it")
		return
	CharacterStore.clear()
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(_main)


func _physics_process(_delta: float) -> void:
	if _main == null:
		return
	_ticks += 1
	var world := _main.get_node_or_null("World") as WorldGen
	var creatures := _main.get_node_or_null("Creatures") as CreatureSpawner
	if world == null or creatures == null:
		if _ticks > 10:
			_fail("main scene did not build World and Creatures")
		return
	if _ticks != ASSERT_TICK:
		return

	var roots: Array[Node] = []
	for child in creatures.get_children():
		if String(child.name).begins_with("Hound_"):
			roots.append(child)
	# The census is EXACT: the rejection sampler silently emits fewer spots
	# when placement degrades — pin the promised head count so a shortfall
	# fails loudly.
	if roots.size() != CreatureSpawner.PACK_COUNT:
		_fail("census %d != promised %d — the sampler lost hounds" % [roots.size(), CreatureSpawner.PACK_COUNT])
		return

	var expected := NpcSpawner.scatter_spots(world, CreatureSpawner.PACK_COUNT,
		CreatureSpawner.WILD_INNER, CreatureSpawner.WILD_OUTER, CreatureSpawner.PACK_POS_SEED)
	if expected.size() != CreatureSpawner.PACK_COUNT:
		_fail("recomputed layout has %d spots, promised %d — sampler headroom collapsed" % [expected.size(), CreatureSpawner.PACK_COUNT])
		return

	for i in roots.size():
		var hound := roots[i] as Node3D
		var pos := hound.position
		if pos.distance_to(expected[i]) > 0.001:
			_fail("%s stands at %s, recomputed layout says %s — placement is not deterministic" % [hound.name, pos, expected[i]])
			return
		if Vector2(pos.x, pos.z).length() < WorldGen.SHRINE_CLEAR_RADIUS:
			_fail("%s stands inside the shrine clearing" % hound.name)
			return
		if world.cave_protects(pos.x, pos.z):
			_fail("%s stands in a cave footprint" % hound.name)
			return
		var walkout := Geometry2D.get_closest_point_to_segment(
			Vector2(pos.x, pos.z), WorldGen.CAVE_SITE, Vector2.ZERO)
		if Vector2(pos.x, pos.z).distance_to(walkout) < NpcSpawner.WALKOUT_CLEARANCE - 0.001:
			_fail("%s blocks the cave walk-out line" % hound.name)
			return
		var ground: float = world.surface_height_at(pos.x, pos.z)
		if absf(pos.y - ground) > 0.001:
			_fail("%s floats: y=%f, ground=%f" % [hound.name, pos.y, ground])
			return
		if CreatureFactory.find_skeleton(hound) == null:
			_fail("%s has no body — build failed" % hound.name)
			return

	_restore_live_save()
	print("TEST PASS — %d hounds placed lawfully and deterministically" % roots.size())
	get_tree().quit(0)


func _fail(message: String) -> void:
	_restore_live_save()
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


## Booting main.tscn with no save exercises the first-run creator — but a LIVE
## character save is player state (no-resets law): back it up first and put it
## back whatever happens. CRASH-SAFE, mirrors npc_population_test.
const BACKUP := "user://character.json.test-backup"


func _exit_tree() -> void:
	_restore_live_save()


func _backup_live_save() -> bool:
	if FileAccess.file_exists(BACKUP):
		# A previous run died before restoring: put the original back first.
		_restore_live_save()
	if not FileAccess.file_exists(CharacterStore.PATH):
		return true
	return DirAccess.copy_absolute(
		ProjectSettings.globalize_path(CharacterStore.PATH),
		ProjectSettings.globalize_path(BACKUP)) == OK


func _restore_live_save() -> void:
	if FileAccess.file_exists(BACKUP):
		DirAccess.rename_absolute(
			ProjectSettings.globalize_path(BACKUP),
			ProjectSettings.globalize_path(CharacterStore.PATH))
