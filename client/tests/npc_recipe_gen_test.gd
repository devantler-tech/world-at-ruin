extends Node
## Regression test for the seeded NPC recipe generator (character system
## stage 6, #24).
##  1. Determinism: the same name yields deep-equal recipes; two names yield
##     different ones; the name forge is deterministic per seed.
##  2. VALIDITY LAW: every generated recipe passes CharacterFactory
##     validation for many names in both archetypes — the generator can
##     never emit a person the factory refuses.
##  3. Range law: weights inside the creator's proven ranges, bone ops
##     inside the guarded-safe table, quantized to 0.01.
##  4. Variety: across many villagers, both genders, several skins and both
##     feet pieces actually occur.
##
## Run: godot --headless --path client res://tests/npc_recipe_gen_test.tscn

const SAMPLE := 60


func _ready() -> void:
	var again_a := NpcGen.recipe_for("Maren", NpcGen.ARCHETYPE_VILLAGER)
	var again_b := NpcGen.recipe_for("Maren", NpcGen.ARCHETYPE_VILLAGER)
	if JSON.stringify(again_a) != JSON.stringify(again_b):
		_fail("same name produced different recipes")
		return
	if JSON.stringify(again_a) == JSON.stringify(NpcGen.recipe_for("Toreth", NpcGen.ARCHETYPE_VILLAGER)):
		_fail("different names produced identical recipes")
		return

	var forge_a := RandomNumberGenerator.new()
	forge_a.seed = 7
	var forge_b := RandomNumberGenerator.new()
	forge_b.seed = 7
	if NpcGen.forge_name(forge_a) != NpcGen.forge_name(forge_b):
		_fail("name forge is not deterministic per seed")
		return

	var kit := CharacterFactory.build({ "version": 1 })
	if kit == null:
		_fail("kit probe failed to build")
		return
	var skeleton := CharacterFactory.find_skeleton(kit)
	var mesh := CharacterFactory.find_skinned_mesh(skeleton)

	var name_rng := RandomNumberGenerator.new()
	name_rng.seed = 20260717
	var genders := {}
	var skins := {}
	var feet := {}
	for i in SAMPLE:
		var npc_name := NpcGen.forge_name(name_rng) + str(i)
		var archetype := NpcGen.ARCHETYPE_VILLAGER if i % 2 == 0 else NpcGen.ARCHETYPE_DRIFTER
		var recipe := NpcGen.recipe_for(npc_name, archetype)
		var problem := CharacterFactory.validate(recipe, skeleton, mesh)
		if problem != "":
			_fail("generated recipe for '%s' is invalid: %s" % [npc_name, problem])
			return
		for shape_name: String in recipe.get("shapes", {}):
			var w: float = recipe["shapes"][shape_name]
			if w < -0.5 or w > 1.2:
				_fail("'%s' weight %f outside creator range" % [shape_name, w])
				return
			if absf(w - snappedf(w, 0.01)) > 0.0001:
				_fail("'%s' weight %f is not quantized" % [shape_name, w])
				return
		for field in ["bone_scale", "bone_girth"]:
			for key: String in recipe.get(field, {}):
				var v: float = recipe[field][key]
				if v < 0.9 or v > 1.35:
					_fail("%s.%s value %f outside guarded-safe range" % [field, key, v])
					return
		genders["f" if recipe["shapes"].has("body_female") else "m"] = true
		skins[recipe["skin"]] = true
		if (recipe["equipment"] as Dictionary).has("feet"):
			feet[recipe["equipment"]["feet"]] = true

	if genders.size() < 2:
		_fail("no gender variety across %d NPCs" % SAMPLE)
		return
	if skins.size() < 4:
		_fail("only %d skins across %d NPCs — variety collapsed" % [skins.size(), SAMPLE])
		return
	if feet.size() < 2:
		_fail("no footwear variety across %d NPCs" % SAMPLE)
		return

	kit.free()
	print("TEST PASS — %d recipes valid, %d skins, both genders" % [SAMPLE, skins.size()])
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
