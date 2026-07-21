extends Node
## Regression test for equipment composition (character system stage 3, #24).
##  1. FORWARD-ONLY EQUIPMENT (no-resets law): every piece that ever shipped
##     (tests/data/shipped_equipment.txt) is still in the baked registry and
##     still builds on a v2 recipe.
##  2. The wanderer preset composes: body + equipped pieces on ONE skeleton;
##     each worn piece's equip_hide_* shape is set on the body.
##  3. Equipment follows the BODY: garments carry the kit shape names and the
##     recipe's weights are applied to them.
##  4. Equipment follows the SKELETON: a bone_girth edit changes the
##     CPU-skinned garment (skin binds resolve through rest surgery).
##  5. Determinism: same v2 recipe twice ⇒ identical fingerprint; dressed vs
##     naked ⇒ different.
##  6. Validation refuses loudly: equipment on a v1 recipe, unknown slot,
##     unknown piece, piece in the wrong slot, plumbing shape in `shapes`.
##  7. Weapon sockets: a stable BoneAttachment3D that follows the hand bone.
##
## Run: godot --headless --path client res://tests/equipment_composition_test.tscn

const SHIPPED := "res://tests/data/shipped_equipment.txt"
const WANDERER := "res://recipes/wanderer.json"


func _ready() -> void:
	var registry := CharacterFactory.equipment_registry()
	if (registry["pieces"] as Dictionary).is_empty():
		_fail("equipment registry is empty or unreadable")
		return

	# 1. Forward-only: every shipped piece still exists and still builds.
	for piece_name in _shipped_pieces():
		if piece_name not in (registry["pieces"] as Dictionary):
			_fail("SHIPPED PIECE '%s' VANISHED from the registry (no-resets law)" % piece_name)
			return
		var slot := String(registry["pieces"][piece_name]["slot"])
		var built := CharacterFactory.build({ "version": 2, "equipment": { slot: piece_name } })
		if built == null:
			_fail("shipped piece '%s' no longer builds" % piece_name)
			return
		built.free()

	# 2. The wanderer preset: dressed body, one skeleton, hide shapes set.
	var wanderer = CharacterFactory.load_recipe(WANDERER)
	if wanderer == null or not (wanderer as Dictionary).has("equipment"):
		_fail("wanderer preset unreadable or lost its equipment")
		return
	var dressed := CharacterFactory.build(wanderer)
	if dressed == null:
		_fail("the dressed wanderer failed to build")
		return
	add_child(dressed)
	var skeleton := CharacterFactory.find_skeleton(dressed)
	var body := CharacterFactory.find_skinned_mesh(skeleton)
	var equipped := {}
	for child in skeleton.get_children():
		if child is MeshInstance3D and String(child.name).begins_with(CharacterFactory.EQUIP_PREFIX):
			equipped[String(child.name).trim_prefix(CharacterFactory.EQUIP_PREFIX)] = child
	var expected_worn := CharacterFactory.pieces_to_wear(wanderer["equipment"])
	if equipped.size() != expected_worn.size():
		_fail("wanderer wears %d pieces, kit composition says %d" % [equipped.size(), expected_worn.size()])
		return
	for slot: String in wanderer["equipment"]:
		var piece_name := String(wanderer["equipment"][slot])
		if piece_name not in equipped:
			_fail("piece '%s' missing from the built wanderer" % piece_name)
			return
		var piece: Dictionary = registry["pieces"][piece_name]
		if piece.has("hide_shape"):
			var hide_idx := body.find_blend_shape_by_name(String(piece["hide_shape"]))
			if hide_idx < 0 or not is_equal_approx(body.get_blend_shape_value(hide_idx), 1.0):
				_fail("hide shape '%s' not set on the body for '%s'" % [piece["hide_shape"], piece_name])
				return

	# 3. Garments follow the body's morphs: the recipe weight is on the shirt.
	var shirt := equipped[String(wanderer["equipment"]["torso"])] as MeshInstance3D
	var shape_idx := shirt.find_blend_shape_by_name("torso_vshape")
	if shape_idx < 0:
		_fail("the shirt carries no torso_vshape blend shape")
		return
	var want: float = wanderer["shapes"]["torso_vshape"]
	if not is_equal_approx(shirt.get_blend_shape_value(shape_idx), want):
		_fail("shirt torso_vshape weight %f != recipe %f" % [shirt.get_blend_shape_value(shape_idx), want])
		return

	# 4. Garments follow the skeleton through rest surgery.
	var plain := CharacterFactory.build({ "version": 2, "equipment": { "legs": "pants_wool" } })
	var girthy := CharacterFactory.build({ "version": 2, "equipment": { "legs": "pants_wool" },
		"bone_girth": { "thigh": 1.18 } })
	var pants_plain := _equipped_mesh(plain, "pants_wool")
	var pants_girthy := _equipped_mesh(girthy, "pants_wool")
	CharacterFactory.find_skeleton(plain).force_update_all_bone_transforms()
	CharacterFactory.find_skeleton(girthy).force_update_all_bone_transforms()
	var skin_plain := CharacterFactory.cpu_skin(CharacterFactory.find_skeleton(plain), pants_plain)
	var skin_girthy := CharacterFactory.cpu_skin(CharacterFactory.find_skeleton(girthy), pants_girthy)
	if skin_plain == skin_girthy:
		_fail("thigh girth did not deform the pants — equipment skin is not following the skeleton")
		return
	plain.free()
	girthy.free()

	# 5. Determinism and distinctness.
	var again := CharacterFactory.build(wanderer)
	var naked: Dictionary = (wanderer as Dictionary).duplicate(true)
	naked.erase("equipment")
	var undressed := CharacterFactory.build(naked)
	var fp_dressed := CharacterFactory.fingerprint(dressed)
	if fp_dressed != CharacterFactory.fingerprint(again):
		_fail("same dressed recipe produced different characters")
		return
	if fp_dressed == CharacterFactory.fingerprint(undressed):
		_fail("dressed and naked builds share a fingerprint")
		return
	again.free()
	undressed.free()

	# 6. Validation refuses loudly, never half-renders.
	for bad: Dictionary in [
		{ "version": 1, "equipment": { "torso": "shirt_ragged" } },
		{ "version": 2, "equipment": { "hat": "shirt_ragged" } },
		{ "version": 2, "equipment": { "torso": "no_such_piece" } },
		{ "version": 2, "equipment": { "feet": "shirt_ragged" } },
		{ "version": 2, "shapes": { "equip_hide_shirt_ragged": 1.0 } },
	]:
		var built := CharacterFactory.build(bad)
		if built != null:
			built.free()
			_fail("invalid recipe was accepted: %s" % JSON.stringify(bad))
			return

	# 7. Weapon sockets: stable, bone-bound, following the hand.
	var socket := CharacterFactory.weapon_socket(dressed, "hand_r")
	if socket == null or socket.bone_name != "hand_r":
		_fail("weapon socket missing or bound to the wrong bone")
		return
	if CharacterFactory.weapon_socket(dressed, "hand_r") != socket:
		_fail("weapon socket is not stable across calls")
		return
	skeleton.force_update_all_bone_transforms()
	var hand_pos: Vector3 = (skeleton.global_transform
		* skeleton.get_bone_global_pose(skeleton.find_bone("hand_r"))).origin
	if socket.global_position.distance_to(hand_pos) > 0.001:
		_fail("weapon socket is not at the hand bone: %s vs %s" % [socket.global_position, hand_pos])
		return
	if CharacterFactory.weapon_socket(dressed, "no_such_bone") != null:
		_fail("a socket appeared on a bone that does not exist")
		return

	print("TEST PASS — %d shipped pieces hold, %s" % [_shipped_pieces().size(), fp_dressed])
	get_tree().quit(0)


func _shipped_pieces() -> PackedStringArray:
	var out := PackedStringArray()
	var f := FileAccess.open(SHIPPED, FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line != "" and not line.begins_with("#"):
			out.append(line)
	return out


func _equipped_mesh(instance: Node3D, piece_name: String) -> MeshInstance3D:
	var skeleton := CharacterFactory.find_skeleton(instance)
	return skeleton.get_node_or_null(NodePath(CharacterFactory.EQUIP_PREFIX + piece_name)) as MeshInstance3D


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
