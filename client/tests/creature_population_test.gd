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
##  6. Determinism-law sweep: across 128 forged names every recipe builds and
##     honours the generator's invariants (opposing morphs never co-occur,
##     every value quantized) — the drift three hand-picked names miss.
##  7. Every hound's node name is unique — the name-keyed recipe stays 1:1.
##
## Run: godot --headless --path client res://tests/creature_population_test.tscn

const ASSERT_TICK := 30

var _ticks := 0
var _main: Node
var _save: SaveIsolation


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

	# 6. Determinism-law sweep. The forge can emit any HEAD+TAIL name; a name
	#    that yields an unbuildable recipe is a hound that would silently vanish
	#    on some machine's seed, and a recipe carrying opposing morphs
	#    (body_heavy AND body_gaunt) or an unquantized value drifts under float
	#    printing. Three hand-picked names above cannot catch either — sweep the
	#    forge from a fixed seed so the sweep itself is deterministic.
	var forge := RandomNumberGenerator.new()
	forge.seed = 0xC0FFEE
	for _i in 128:
		var forged := CreatureGen.forge_name(forge)
		var recipe := CreatureGen.recipe_for(forged)
		var shapes: Dictionary = recipe.get("shapes", {})
		if shapes.has("body_heavy") and shapes.has("body_gaunt"):
			_fail("'%s' carries both body_heavy and body_gaunt — opposing morphs" % forged)
			return
		for key in shapes:
			var value: float = shapes[key]
			if value != snappedf(value, 0.01):
				_fail("'%s' shape %s=%f is not quantized to 0.01" % [forged, key, value])
				return
		for key in (recipe.get("bone_scale", {}) as Dictionary):
			var scale: float = recipe["bone_scale"][key]
			if scale != snappedf(scale, 0.01):
				_fail("'%s' bone_scale %s=%f is not quantized to 0.01" % [forged, key, scale])
				return
		var built := CreatureFactory.build(recipe)
		if built == null:
			_fail("forged name '%s' produced an unbuildable recipe: %s" % [forged, JSON.stringify(recipe)])
			return
		built.free()

	# Booting main.tscn with no save exercises the first-run creator — point the
	# game at a throwaway probe so it never touches the player's real character
	# (no-resets law). Fail closed if the redirect does not take hold.
	_save = SaveIsolation.new("user://creature_population_boot_probe.json")
	if not _save.begin():
		_fail("save isolation did not take — refusing to boot into the real save")
		return
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

	# 7. Forged names can collide; the spawner suffixes until unique so the
	#    name-keyed recipe stays 1:1 with the hound standing there. Two hounds
	#    sharing a node name would mean two identical recipes — assert unique.
	var seen_names := {}
	for hound_node in roots:
		var node_name := String(hound_node.name)
		if seen_names.has(node_name):
			_fail("two hounds share the name %s — collision suffixing failed" % node_name)
			return
		seen_names[node_name] = true

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

	if not _save.real_save_untouched():
		_fail("the boot test touched the player's real save")
		return
	print("TEST PASS — %d hounds placed lawfully and deterministically" % roots.size())
	get_tree().quit(0)


func _fail(message: String) -> void:
	if _save != null:
		_save.end()
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


## Clearing the seam on teardown covers the process being killed after the scene
## loaded but before an exit path ran — the redirect never outlives the test.
## Idempotent with the end() the exit paths already call.
func _exit_tree() -> void:
	if _save != null:
		_save.end()
