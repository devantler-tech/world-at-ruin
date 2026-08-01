extends Node
## Regression test for CharacterFactory recipe TYPE guards (issue #47).
##
## The no-resets product law requires a present-but-malformed character save to
## refuse LOUDLY (push_error + a null build), never crash the boot's load path
## and never half-apply. A recipe whose field is the wrong TYPE — a non-
## Dictionary `shapes`/`bone_girth`/`bone_scale`/`joint_push` — must therefore
## be rejected cleanly, exactly as CreatureFactory already does. Without the
## guards an int/float value aborts validate()'s iteration (a runtime crash on
## the load path that runs at boot), and a String/Array value yields a
## misleading error or a mis-indexed access.
##
## character_factory_test covers the VALUE-level rejections (unknown shape/
## bone/version, unguarded bone, v1-carrying-equipment); this pins the
## TYPE-level ones, plus finite reader scalars and bounded writer scalars. The
## split preserves legacy recipes while preventing new malformed persistence.
##
## Run: godot --headless --path client res://tests/recipe_type_guard_test.tscn

func _ready() -> void:
	# A well-formed v1 recipe with Dictionary-typed (here empty) fields still
	# builds — the guards must reject only the wrong TYPE, never a valid recipe.
	var ok := CharacterFactory.build({
		"version": 1,
		"shapes": {},
		"bone_girth": {},
		"bone_scale": {},
		"joint_push": {},
	})
	if ok == null:
		_fail("a valid v1 recipe with empty Dictionary fields must build")
		return
	ok.free()

	# Each malformed recipe carries one field of the WRONG type. All must be
	# refused cleanly (build() -> null), never accepted and never a crash.
	for bad: Dictionary in [
		{ "version": 1, "shapes": 5 },
		{ "version": 1, "shapes": "big" },
		{ "version": 1, "shapes": ["headbig"] },
		{ "version": 1, "bone_girth": 5 },
		{ "version": 1, "bone_girth": "thin" },
		{ "version": 1, "bone_scale": 2.0 },
		{ "version": 1, "bone_scale": true },
		{ "version": 1, "joint_push": 1 },
		{ "version": 1, "joint_push": [] },
		{ "version": 1, "shapes": { "torso_vshape": "heavy" } },
		{ "version": 1, "shapes": { "torso_vshape": NAN } },
		{ "version": 1, "bone_girth": { "upperarm": "wide" } },
		{ "version": 1, "bone_girth": { "upperarm": INF } },
		{ "version": 1, "shapes": { 1: 0.5 } },
		{ "version": 1, "bone_girth": { 1: 1.0 } },
		{ "version": 1, "bone_scale": { 1: 1.0 } },
		{ "version": 1, "joint_push": { 1: 1.0 } },
	]:
		var built := CharacterFactory.build(bad)
		if built != null:
			built.free()
			_fail("malformed recipe was accepted (must refuse loudly): %s" % JSON.stringify(bad))
			return

	# v1..v4 accepted every finite numeric deformation. The reader must retain
	# that meaning even though new writes are now kept inside authored bounds.
	for legacy: Dictionary in [
		{ "version": 1, "shapes": { "torso_vshape": CharacterFactory.SHAPE_WEIGHT_MAX + 0.01 } },
		{ "version": 1, "bone_girth": { "upperarm": CharacterFactory.BONE_FACTOR_MIN - 0.01 } },
	]:
		var built := CharacterFactory.build(legacy)
		if built == null:
			_fail("a previously accepted finite deformation was stranded: %s" % JSON.stringify(legacy))
			return
		built.free()

	# The stricter range is a WRITE contract. Cover each persisted deformation
	# field independently so a future writer cannot emit a recipe it cannot read
	# back safely on the next launch.
	for unwritable: Dictionary in [
		{ "version": 1, "shapes": { "torso_vshape": CharacterFactory.SHAPE_WEIGHT_MAX + 0.01 } },
		{ "version": 1, "bone_girth": { "upperarm": 0.0 } },
		{ "version": 1, "bone_scale": { "hand": CharacterFactory.BONE_FACTOR_MAX + 0.01 } },
		{ "version": 1, "joint_push": { "upperarm": CharacterFactory.BONE_FACTOR_MIN - 0.01 } },
	]:
		if CharacterFactory.write_refusal_reason(unwritable) == "":
			_fail("an out-of-range deformation remained writable: %s" % JSON.stringify(unwritable))
			return

	print("TEST PASS — malformed character recipes refuse loudly (schema and scalar guards hold)")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
