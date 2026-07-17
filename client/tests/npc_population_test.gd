extends Node
## Regression test for the seeded NPC population (character system stage 6,
## #24): the Reach is inhabited, deterministically, by people standing on
## the ground and out of the way.
##  1. The main scene builds an "Npcs" node with the expected census.
##  2. Placement law per NPC: outside the shrine clear radius, outside cave
##     footprints, off the cave->shrine walk-out line, on real ground
##     (position matches surface_height_at), inside the grid.
##  3. Determinism: node positions equal a fresh recompute of the layout
##     from the same seeds (scatter_spots is a pure function of the world).
##  4. Every NPC actually built (has a skeleton) and carries a nameplate.
##
## Run: godot --headless --path client res://tests/npc_population_test.tscn

const ASSERT_TICK := 30

var _ticks := 0
var _main: Node


func _ready() -> void:
	if not _backup_live_save():
		_fail("could not back up the live character save — refusing to touch it")
		return
	CharacterStore.clear()
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(_main)


func _physics_process(_delta: float) -> void:
	_ticks += 1
	var world := _main.get_node_or_null("World") as WorldGen
	var npcs := _main.get_node_or_null("Npcs") as NpcSpawner
	if world == null or npcs == null:
		if _ticks > 10:
			_fail("main scene did not build World and Npcs")
		return
	if _ticks != ASSERT_TICK:
		return

	var roots: Array[Node] = []
	for child in npcs.get_children():
		if String(child.name).begins_with("Npc_"):
			roots.append(child)
	# The census is EXACT: the rejection sampler silently emits fewer spots
	# when placement degrades, and a recompute-only comparison would shrink
	# with it — pin the promised head count so a shortfall fails loudly.
	var promised := NpcSpawner.SETTLEMENT_COUNT + NpcSpawner.DRIFTER_COUNT
	if roots.size() != promised:
		_fail("census %d != promised %d — the sampler lost people" % [roots.size(), promised])
		return

	var expected: Array[Vector3] = []
	expected.append_array(NpcSpawner.scatter_spots(world, NpcSpawner.SETTLEMENT_COUNT,
		NpcSpawner.RING_INNER, NpcSpawner.RING_OUTER, NpcSpawner.SETTLEMENT_POS_SEED))
	expected.append_array(NpcSpawner.scatter_spots(world, NpcSpawner.DRIFTER_COUNT,
		NpcSpawner.DRIFT_INNER, NpcSpawner.DRIFT_OUTER, NpcSpawner.DRIFTER_POS_SEED))
	if expected.size() != promised:
		_fail("recomputed layout has %d spots, promised %d — sampler headroom collapsed" % [expected.size(), promised])
		return

	for i in roots.size():
		var npc := roots[i] as Node3D
		var pos := npc.position
		if pos.distance_to(expected[i]) > 0.001:
			_fail("%s stands at %s, recomputed layout says %s — placement is not deterministic" % [npc.name, pos, expected[i]])
			return
		if Vector2(pos.x, pos.z).length() < WorldGen.SHRINE_CLEAR_RADIUS:
			_fail("%s stands inside the shrine clearing" % npc.name)
			return
		if world.cave_protects(pos.x, pos.z):
			_fail("%s stands in a cave footprint" % npc.name)
			return
		var walkout := Geometry2D.get_closest_point_to_segment(
			Vector2(pos.x, pos.z), WorldGen.CAVE_SITE, Vector2.ZERO)
		if Vector2(pos.x, pos.z).distance_to(walkout) < NpcSpawner.WALKOUT_CLEARANCE - 0.001:
			_fail("%s blocks the cave walk-out line" % npc.name)
			return
		var ground: float = world.surface_height_at(pos.x, pos.z)
		if absf(pos.y - ground) > 0.001:
			_fail("%s floats: y=%f, ground=%f" % [npc.name, pos.y, ground])
			return
		if CharacterFactory.find_skeleton(npc) == null:
			_fail("%s has no body — build failed" % npc.name)
			return
		var has_nameplate := false
		for child in npc.get_children():
			if child is Label3D:
				has_nameplate = true
		if not has_nameplate:
			_fail("%s has no nameplate" % npc.name)
			return

	_restore_live_save()
	print("TEST PASS — %d NPCs placed lawfully and deterministically" % roots.size())
	get_tree().quit(0)


func _fail(message: String) -> void:
	_restore_live_save()
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


## Booting main.tscn with no save exercises the first-run creator — but a
## LIVE character save is player state (no-resets law): back it up first and
## put it back whatever happens. CRASH-SAFE: a stale backup from a killed
## run is restored (never clobbered) before a new backup is taken, the copy
## is verified before anything destructive runs, and tree teardown restores
## too — the live save's only copy is never hostage to a clean exit.
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
