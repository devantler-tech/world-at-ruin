extends Node
## Regression test for CharacterFactory (character system stage 2, issue #24).
##  1. Distinctness: the res://recipes/ presets are pairwise distinct.
##  2. TRS law: after bone ops, global pose == global rest on both hands
##     (shear in a rest decomposes lossily and the skin silently lies).
##  3. Validation fails loudly: future version, missing version, unknown
##     shape, unknown bone.
## The golden-fixture build/zero-loss/determinism law lives in
## save_fixture_guard_test (#36); the v1 golden is used here only as the
## heaviest bone-op input for the TRS check.
##
## Run: godot --headless --path client res://tests/character_factory_test.tscn

const GOLDEN := "res://tests/data/golden_recipe_v1.json"
const PRESETS := ["res://recipes/wanderer.json", "res://recipes/villager.json", "res://recipes/elder.json", "res://recipes/brute.json"]


func _ready() -> void:
	var golden = CharacterFactory.load_recipe(GOLDEN)
	if golden == null:
		_fail("golden recipe unreadable")
		return
	var golden_a := CharacterFactory.build(golden)
	if golden_a == null:
		_fail("golden recipe failed to build (the build law itself is save_fixture_guard_test's)")
		return

	var preset_fingerprints := {}
	for path in PRESETS:
		var recipe = CharacterFactory.load_recipe(path)
		if recipe == null:
			_fail("preset unreadable: %s" % path)
			return
		var built := CharacterFactory.build(recipe)
		if built == null:
			_fail("preset failed to build: %s" % path)
			return
		var fp := CharacterFactory.fingerprint(built)
		if preset_fingerprints.has(fp):
			_fail("presets %s and %s are identical" % [preset_fingerprints[fp], path])
			return
		preset_fingerprints[fp] = path
		built.free()

	# TRS law on the heaviest bone-op recipe (the golden one).
	var skeleton := CharacterFactory.find_skeleton(golden_a)
	skeleton.force_update_all_bone_transforms()
	for hand_name in ["hand_l", "hand_r"]:
		var hand := skeleton.find_bone(hand_name)
		var rest_origin := skeleton.get_bone_global_rest(hand).origin
		var pose_origin := skeleton.get_bone_global_pose(hand).origin
		if rest_origin.distance_to(pose_origin) > 0.001:
			_fail("%s pose diverged from rest (non-TRS rest?): pose=%s rest=%s" % [hand_name, pose_origin, rest_origin])
			return

	# Validation must fail loudly, not half-apply.
	var kit_probe := CharacterFactory.build({ "version": 1 })
	if kit_probe == null:
		_fail("empty v1 recipe should build")
		return
	kit_probe.free()
	for bad: Dictionary in [
		{ "version": CharacterFactory.RECIPE_VERSION + 1 },
		{},
		{ "version": 1, "shapes": { "no_such_shape": 1.0 } },
		{ "version": 1, "bone_girth": { "no_such_bone": 1.1 } },
		# A real bone OUTSIDE the guarded set — accepting it would dodge the
		# golden recipe's forward-compat guarantee.
		{ "version": 1, "bone_girth": { "index_01_l": 1.1 } },
		# equipment entered the format at v2; a v1 recipe carrying it was
		# always invalid and must stay invalid forever (a client that cannot
		# render everything a recipe says refuses, never a half-truth).
		{ "version": 1, "equipment": { "head": "hood" } },
	]:
		var built := CharacterFactory.build(bad)
		if built != null:
			built.free()
			_fail("invalid recipe was accepted: %s" % JSON.stringify(bad))
			return

	golden_a.free()
	print("TEST PASS — %d presets distinct, TRS law holds, validation refuses" % PRESETS.size())
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
