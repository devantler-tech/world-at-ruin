extends DelayedBootScenario
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



func _ready() -> void:
	_boot("user://npc_population_boot_probe.json")


func _physics_process(_delta: float) -> void:
	if not _advance():
		return
	var world := _main.get_node_or_null("World") as WorldGen
	var npcs := _main.get_node_or_null("Npcs") as NpcSpawner
	if not _nodes_ready(world != null and npcs != null, "main scene did not build World and Npcs"):
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
		var problem := PopulationTestSupport.placement_problem(npc, expected[i], world)
		if not problem.is_empty():
			_fail(problem)
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

	_finish("%d NPCs placed lawfully and deterministically" % roots.size())
