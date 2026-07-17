extends Node
## Regression test for CreatureFactory (creature system pilot, issue #24).
##  1. THE GOLDEN RECIPE BUILDS (the no-resets guard): tests/data/
##     golden_creature_recipe_v1.json uses every kit shape, every guarded
##     bone_scale key and a tint that has ever shipped — if it fails to build,
##     a shipped creature recipe has been broken. It may only ever gain
##     entries.
##  2. Forward-only tints: every tint in tests/data/shipped_creature_tints.txt
##     is still in the baked registry and builds.
##  3. Determinism: same recipe twice ⇒ identical fingerprint; two tints on
##     the same body ⇒ distinct; the shared-material rule holds.
##  4. TRS law: after a root bone_scale, global pose == global rest at the head
##     bone (shear in a rest decomposes lossily and the skin silently lies).
##  5. Validation fails loudly: future version, missing version, unknown field,
##     unknown shape, unguarded bone, unknown tint.
##
## Run: godot --headless --path client res://tests/creature_factory_test.tscn

const GOLDEN := "res://tests/data/golden_creature_recipe_v1.json"
const SHIPPED_TINTS := "res://tests/data/shipped_creature_tints.txt"


func _ready() -> void:
	var registry := CreatureFactory.tints_registry()
	if (registry["tints"] as Dictionary).is_empty():
		_fail("tints registry is empty or unreadable")
		return

	# 1. The golden recipe builds and is deterministic.
	var golden = CreatureFactory.load_recipe(GOLDEN)
	if golden == null:
		_fail("golden recipe unreadable")
		return
	var golden_a := CreatureFactory.build(golden)
	var golden_b := CreatureFactory.build(golden)
	if golden_a == null or golden_b == null:
		_fail("THE GOLDEN RECIPE NO LONGER BUILDS — a shipped shape, bone or tint was removed (no-resets law)")
		return
	var fp_golden := CreatureFactory.fingerprint(golden_a)
	if fp_golden != CreatureFactory.fingerprint(golden_b):
		_fail("same recipe produced different creatures")
		return

	# 2. Forward-only: every shipped tint still exists and builds.
	for tint_name in _shipped_tints():
		if tint_name not in (registry["tints"] as Dictionary):
			_fail("SHIPPED TINT '%s' VANISHED from the registry (no-resets law)" % tint_name)
			return
		var built := CreatureFactory.build({ "version": 1, "tint": tint_name })
		if built == null:
			_fail("shipped tint '%s' no longer builds" % tint_name)
			return
		built.free()

	# 3. Shared material per tint; distinct fingerprint per tint.
	var a := CreatureFactory.build({ "version": 1, "tint": "ash" })
	var b := CreatureFactory.build({ "version": 1, "tint": "ash" })
	var mat_a := CreatureFactory.find_skinned_mesh(CreatureFactory.find_skeleton(a)).get_surface_override_material(0)
	var mat_b := CreatureFactory.find_skinned_mesh(CreatureFactory.find_skeleton(b)).get_surface_override_material(0)
	if mat_a == null:
		_fail("tinted hide has no override material")
		return
	if mat_a != mat_b:
		_fail("two builds with the same tint did not share one material")
		return
	var other := CreatureFactory.build({ "version": 1, "tint": "char" })
	if CreatureFactory.fingerprint(a) == CreatureFactory.fingerprint(other):
		_fail("different tints share a fingerprint — the tint is part of identity")
		return
	a.free()
	b.free()
	other.free()

	# 4. TRS law on the heaviest bone-op recipe (the golden one, which scales
	#    root, head and tail_01).
	var skeleton := CreatureFactory.find_skeleton(golden_a)
	skeleton.force_update_all_bone_transforms()
	var head := skeleton.find_bone("head")
	var rest_origin := skeleton.get_bone_global_rest(head).origin
	var pose_origin := skeleton.get_bone_global_pose(head).origin
	if rest_origin.distance_to(pose_origin) > 0.001:
		_fail("head pose diverged from rest (non-TRS rest?): pose=%s rest=%s" % [pose_origin, rest_origin])
		return

	# 5. Validation must fail loudly, not half-apply.
	var kit_probe := CreatureFactory.build({ "version": 1 })
	if kit_probe == null:
		_fail("empty v1 recipe should build")
		return
	kit_probe.free()
	for bad: Dictionary in [
		{ "version": CreatureFactory.RECIPE_VERSION + 1 },
		{},
		{ "version": 1, "no_such_field": 1 },
		{ "version": 1, "shapes": { "no_such_shape": 1.0 } },
		{ "version": 1, "bone_scale": { "no_such_bone": 1.1 } },
		# A real bone OUTSIDE the guarded set — accepting it would dodge the
		# golden recipe's forward-compat guarantee.
		{ "version": 1, "bone_scale": { "spine": 1.1 } },
		{ "version": 1, "tint": "no_such_tint" },
	]:
		var built := CreatureFactory.build(bad)
		if built != null:
			built.free()
			_fail("invalid recipe was accepted: %s" % JSON.stringify(bad))
			return

	golden_a.free()
	golden_b.free()
	print("TEST PASS — golden holds, %d shipped tints, %s" % [_shipped_tints().size(), fp_golden])
	get_tree().quit(0)


func _shipped_tints() -> PackedStringArray:
	var out := PackedStringArray()
	var f := FileAccess.open(SHIPPED_TINTS, FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line != "" and not line.begins_with("#"):
			out.append(line)
	return out


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
