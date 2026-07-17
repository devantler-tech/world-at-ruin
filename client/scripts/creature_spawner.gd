class_name CreatureSpawner
extends Node3D
## Scatters seeded ash hounds across the wild edges of the Reach (creature
## system pilot, issue #24): the first non-humanoid life in the world. Like the
## NPCs, every hound is derived from WORLD_SEED — the same pack stands in the
## same places every boot (determinism law).
##
## Hounds are scenery-grade for now: no physics bodies, no AI, one pose. The
## cost of N hounds is N skinned meshes standing still — cheap. Movement,
## hostility and combat arrive with the combat phase; today they haunt the
## treeline and watch.

const PACK_COUNT := 8
## Seed offsets carve independent RNG streams off WORLD_SEED. Offsets 0-7 are
## terrain/ruins/shrine/cave (world_gen); 101-104 are the NPC settlement and
## drifters (npc_spawner); creatures claim 110+.
const PACK_POS_SEED := 110
const PACK_NAME_SEED := 111
const PACK_YAW_SEED := 112

## Hounds keep to the wild, well outside the settlement ring but inside the
## playable field — they share the NPC scatter's keep-outs (shrine, cave
## footprints, the cave-mouth walk-out line, off-grid, mutual spacing).
const WILD_INNER := 46.0
const WILD_OUTER := 104.0

var creature_names: PackedStringArray = []


## Builds and places the pack. `world` is the live WorldGen node.
func populate(world: Node) -> void:
	var spots := NpcSpawner.scatter_spots(world, PACK_COUNT, WILD_INNER, WILD_OUTER, PACK_POS_SEED)
	var name_rng := RandomNumberGenerator.new()
	name_rng.seed = WorldGen.WORLD_SEED + PACK_NAME_SEED
	var yaw_rng := RandomNumberGenerator.new()
	yaw_rng.seed = WorldGen.WORLD_SEED + PACK_YAW_SEED
	for spot in spots:
		var creature_name := CreatureGen.forge_name(name_rng)
		# Forged names can collide; suffix until unique so the name-keyed
		# recipe stays 1:1 with the hound standing there.
		while creature_name in creature_names:
			creature_name += CreatureGen.NAME_TAILS[name_rng.randi_range(0, CreatureGen.NAME_TAILS.size() - 1)]
		creature_names.append(creature_name)
		var body := CreatureFactory.build(CreatureGen.recipe_for(creature_name))
		if body == null:
			push_error("CreatureSpawner: '%s' failed to build" % creature_name)
			continue
		var root := Node3D.new()
		root.name = "Hound_" + creature_name
		add_child(root)
		root.position = spot
		# Hounds face any which way — they are watching the land, not us.
		root.rotation.y = yaw_rng.randf_range(-PI, PI)
		root.add_child(body)
