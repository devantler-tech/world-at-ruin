extends Node
## Regression test for the skin layer (character system stage 5, #24).
##  1. FORWARD-ONLY SKINS (no-resets law): every skin that ever shipped
##     (tests/data/shipped_skins.txt) is still in the baked registry, its
##     texture loads, and it builds on a v3 recipe.
##  2. A skinned build wears the texture: the body's surface override
##     material carries the right albedo texture; equipment keeps its own
##     materials; two builds with the same skin share ONE material.
##  3. Fingerprints: same recipe twice ⇒ identical; same body in two skins ⇒
##     different (the skin is part of the character's identity).
##  4. Validation refuses loudly: skin on a v2 recipe, unknown skin name.
## The v3 golden's build/zero-loss/determinism law lives in
## save_fixture_guard_test (#36).
##
## Run: godot --headless --path client res://tests/skin_layer_test.tscn

const SHIPPED := "res://tests/data/shipped_skins.txt"


func _ready() -> void:
	var registry := CharacterFactory.skins_registry()
	if (registry["skins"] as Dictionary).is_empty():
		_fail("skins registry is empty or unreadable")
		return

	# 1. Forward-only: every shipped skin still exists, loads, builds.
	for skin_name in _shipped_skins():
		if skin_name not in (registry["skins"] as Dictionary):
			_fail("SHIPPED SKIN '%s' VANISHED from the registry (no-resets law)" % skin_name)
			return
		var texture = load(CharacterFactory.SKINS_DIR + String(registry["skins"][skin_name]["texture"]))
		if texture is not Texture2D:
			_fail("skin '%s' texture failed to load" % skin_name)
			return
		var built := CharacterFactory.build({ "version": 3, "skin": skin_name })
		if built == null:
			_fail("shipped skin '%s' no longer builds" % skin_name)
			return
		built.free()

	# 2. The texture is actually worn, equipment keeps its own materials,
	#    and materials are shared across instances.
	var recipe := { "version": 3, "skin": "skin_male_light",
		"equipment": { "torso": "shirt_ragged" } }
	var a := CharacterFactory.build(recipe)
	var b := CharacterFactory.build(recipe)
	if a == null or b == null:
		_fail("skinned+dressed recipe failed to build")
		return
	var body_a := CharacterFactory.find_skinned_mesh(CharacterFactory.find_skeleton(a))
	var body_b := CharacterFactory.find_skinned_mesh(CharacterFactory.find_skeleton(b))
	var mat_a := body_a.get_surface_override_material(0) as StandardMaterial3D
	var mat_b := body_b.get_surface_override_material(0) as StandardMaterial3D
	if mat_a == null or mat_a.albedo_texture == null:
		_fail("skinned body has no texture material")
		return
	if not String(mat_a.albedo_texture.resource_path).ends_with("skin_male_light.png"):
		_fail("body wears the wrong texture: %s" % mat_a.albedo_texture.resource_path)
		return
	if mat_a != mat_b:
		_fail("two builds with the same skin did not share one material")
		return
	var shirt := CharacterFactory.find_skeleton(a).get_node_or_null(
		NodePath(CharacterFactory.EQUIP_PREFIX + "shirt_ragged")) as MeshInstance3D
	if shirt == null or shirt.get_surface_override_material(0) != null:
		_fail("equipment lost its own baked material")
		return

	# 3. Fingerprints: deterministic per recipe, distinct per skin.
	var fp_a := CharacterFactory.fingerprint(a)
	if fp_a != CharacterFactory.fingerprint(b):
		_fail("same skinned recipe produced different fingerprints")
		return
	var other := CharacterFactory.build({ "version": 3, "skin": "skin_female_mid",
		"equipment": { "torso": "shirt_ragged" } })
	if fp_a == CharacterFactory.fingerprint(other):
		_fail("different skins share a fingerprint — the skin is part of identity")
		return
	a.free()
	b.free()
	other.free()

	# 4. Validation refuses loudly.
	for bad: Dictionary in [
		{ "version": 2, "skin": "skin_male_light" },
		{ "version": 3, "skin": "no_such_skin" },
	]:
		var built := CharacterFactory.build(bad)
		if built != null:
			built.free()
			_fail("invalid recipe was accepted: %s" % JSON.stringify(bad))
			return

	print("TEST PASS — %d shipped skins hold, %s" % [_shipped_skins().size(), fp_a])
	get_tree().quit(0)


func _shipped_skins() -> PackedStringArray:
	var out := PackedStringArray()
	var f := FileAccess.open(SHIPPED, FileAccess.READ)
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
