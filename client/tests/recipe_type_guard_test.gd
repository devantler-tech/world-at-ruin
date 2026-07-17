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
## TYPE-level ones so the two factories stay at parity.
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
	]:
		var built := CharacterFactory.build(bad)
		if built != null:
			built.free()
			_fail("malformed recipe was accepted (must refuse loudly): %s" % JSON.stringify(bad))
			return

	print("TEST PASS — malformed character recipes refuse loudly (type guards hold)")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
