class_name NpcSpawner
extends Node3D
## Populates the Reach with seeded people (character system stage 6, #24):
## a small settlement ringing the shrine and lone drifters scattered across
## the open land. Everything is derived from WORLD_SEED — the same people
## stand in the same places every boot (determinism law).
##
## NPCs are scenery-grade for now: no physics bodies, no AI, one pose. The
## cost of N people is N skinned meshes standing still — cheap. Movement,
## dialogue and hostility arrive with later phases (combat, meta tier).

const SETTLEMENT_COUNT := 14
const DRIFTER_COUNT := 10
## Seed offsets carve independent RNG streams off WORLD_SEED (offsets 0-7
## are taken by terrain/ruins/shrine/cave — see world_gen.gd).
const SETTLEMENT_POS_SEED := 101
const SETTLEMENT_NAME_SEED := 102
const DRIFTER_POS_SEED := 103
const DRIFTER_NAME_SEED := 104

## The settlement rings the shrine just outside its clear radius.
const RING_INNER := 16.0
const RING_OUTER := 26.0
## Drifters roam the wider Reach.
const DRIFT_INNER := 32.0
const DRIFT_OUTER := 100.0
## Keep-outs: the walk-out line from the cave mouth to the shrine stays
## clear (the player's first traversal), and people never stand inside cave
## footprints, off the grid, or in each other.
const WALKOUT_CLEARANCE := 6.0
const EDGE_MARGIN := 12.0
const SPACING := 1.6
const PLACEMENT_ATTEMPTS := 40

var npc_names: PackedStringArray = []

## A person spoke: their name and the seeded line they gave. main.gd surfaces it
## as a toast. (A first bark only — real dialogue and quests come with #13.)
signal npc_spoke(npc_name: String, line: String)


## Builds and places everyone. `world` is the live WorldGen node.
func populate(world: Node) -> void:
	_scatter(world, SETTLEMENT_COUNT, RING_INNER, RING_OUTER,
		SETTLEMENT_POS_SEED, SETTLEMENT_NAME_SEED, NpcGen.ARCHETYPE_VILLAGER)
	_scatter(world, DRIFTER_COUNT, DRIFT_INNER, DRIFT_OUTER,
		DRIFTER_POS_SEED, DRIFTER_NAME_SEED, NpcGen.ARCHETYPE_DRIFTER)


func _scatter(world: Node, count: int, inner: float, outer: float,
		pos_seed: int, name_seed: int, archetype: String) -> void:
	var spots := scatter_spots(world, count, inner, outer, pos_seed)
	var name_rng := RandomNumberGenerator.new()
	name_rng.seed = WorldGen.WORLD_SEED + name_seed
	var yaw_rng := RandomNumberGenerator.new()
	yaw_rng.seed = WorldGen.WORLD_SEED + pos_seed + 1000
	for spot in spots:
		var npc_name := NpcGen.forge_name(name_rng)
		# Forged names can collide; suffix until unique so the name-keyed
		# recipe stays 1:1 with the person standing there.
		while npc_name in npc_names:
			npc_name += NpcGen.NAME_TAILS[name_rng.randi_range(0, NpcGen.NAME_TAILS.size() - 1)]
		npc_names.append(npc_name)
		var body := CharacterFactory.build(NpcGen.recipe_for(npc_name, archetype))
		if body == null:
			push_error("NpcSpawner: '%s' failed to build" % npc_name)
			continue
		var root := Node3D.new()
		root.name = "Npc_" + npc_name
		add_child(root)
		root.position = spot
		# Villagers loosely face the shrine at world origin; drifters face
		# wherever their road was taking them.
		if archetype == NpcGen.ARCHETYPE_VILLAGER:
			root.rotation.y = atan2(spot.x, spot.z) + yaw_rng.randf_range(-0.6, 0.6)
		else:
			root.rotation.y = yaw_rng.randf_range(-PI, PI)
		root.add_child(body)
		root.add_child(_nameplate(npc_name))
		# The people can finally answer: walk up and face someone and "Speak"
		# offers their one seeded line. Chest-height handle, small reach, must
		# be faced — so you address the person you look at, not the crowd.
		var talk := Interactable.new()
		talk.name = "Talk"
		talk.prompt = "Speak"
		talk.interact_range = 3.0
		talk.facing_min = 0.35
		talk.position = Vector3(0, 1.4, 0)
		root.add_child(talk)
		talk.interacted.connect(_on_npc_talk.bind(npc_name, archetype))


func _on_npc_talk(_by: Node, npc_name: String, archetype: String) -> void:
	npc_spoke.emit(npc_name, NpcGen.bark_for(npc_name, archetype))


## Deterministic ground spots: rejection-sampled ring positions honouring
## every keep-out. Static and side-effect-free so tests can recompute the
## expected layout without instancing a spawner.
static func scatter_spots(world: Node, count: int, inner: float, outer: float,
		pos_seed: int) -> Array[Vector3]:
	var rng := RandomNumberGenerator.new()
	rng.seed = WorldGen.WORLD_SEED + pos_seed
	var spots: Array[Vector3] = []
	for _i in count:
		for _attempt in PLACEMENT_ATTEMPTS:
			var angle := rng.randf_range(-PI, PI)
			var radius := rng.randf_range(inner, outer)
			var x := cos(angle) * radius
			var z := sin(angle) * radius
			if not _spot_ok(world, x, z, spots):
				continue
			spots.append(Vector3(x, world.surface_height_at(x, z), z))
			break
	return spots


static func _spot_ok(world: Node, x: float, z: float, taken: Array[Vector3]) -> bool:
	var flat := Vector2(x, z)
	if flat.length() < WorldGen.SHRINE_CLEAR_RADIUS:
		return false
	if absf(x) > 110.0 - EDGE_MARGIN or absf(z) > 110.0 - EDGE_MARGIN:
		return false
	if world.cave_protects(x, z):
		return false
	var walkout := Geometry2D.get_closest_point_to_segment(flat, WorldGen.CAVE_SITE, Vector2.ZERO)
	if flat.distance_to(walkout) < WALKOUT_CLEARANCE:
		return false
	var ground: float = world.surface_height_at(x, z)
	if ground <= WorldGen.NO_GROUND + 1.0:
		return false
	for spot in taken:
		if flat.distance_to(Vector2(spot.x, spot.z)) < SPACING:
			return false
	return true


func _nameplate(npc_name: String) -> Label3D:
	var label := Label3D.new()
	label.text = npc_name
	label.font_size = 36
	label.outline_size = 10
	label.pixel_size = 0.0035
	label.modulate = Color(0.88, 0.84, 0.76, 0.9)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0, 2.05, 0)
	# Names are an up-close courtesy, not skyline clutter — and they FADE at
	# the range edge (the default fade mode is DISABLED, which hard-pops).
	label.visibility_range_end = 22.0
	label.visibility_range_end_margin = 4.0
	label.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	return label
