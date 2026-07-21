extends Node
## Regression contract for the unremovable ragged base layer (#323).
##
## A recipe describes what the player puts ON. The kit supplies what remains
## when every recipe-addressable piece comes OFF, so `equipment: {}` must
## never resolve to a bare body. The base garment is therefore kit data,
## rendered before clothing and armour, and deliberately unavailable to the
## persisted recipe vocabulary.
##
## Run: godot --headless --path client res://tests/base_layer_test.tscn

const BASE_PIECE := "loincloth_ragged"


func _ready() -> void:
	var registry := CharacterFactory.equipment_registry()
	var pieces: Dictionary = registry.get("pieces", {})
	if pieces.is_empty():
		_fail("equipment registry is empty or unreadable")
		return

	# The floor is explicit kit data and the first render layer. This is the
	# RED seam on pre-#323 main: the kit only declares clothing and armour.
	if Array(registry.get("layers", [])) != ["base", "clothing", "armor"]:
		_fail("equipment layers do not start with the unremovable base: %s" % str(registry.get("layers", [])))
		return
	if Array(registry.get("base_pieces", [])) != [BASE_PIECE]:
		_fail("the kit does not declare exactly one base garment: %s" % str(registry.get("base_pieces", [])))
		return
	if not CharacterCreator._pieces_in_slot(registry, "pelvis").is_empty():
		_fail("the creator exposes the kit-owned base garment as recipe equipment")
		return
	if BASE_PIECE not in pieces:
		_fail("the declared base garment '%s' is missing from the baked registry" % BASE_PIECE)
		return
	var base: Dictionary = pieces[BASE_PIECE]
	if String(base.get("layer", "")) != "base" or String(base.get("slot", "")) != "pelvis":
		_fail("the base garment is not the base-layer pelvis piece: %s" % str(base))
		return

	# Empty equipment still wears the floor, and ordinary equipment is layered
	# after it in kit order. A recipe can neither omit nor reorder the base.
	if Array(CharacterFactory.pieces_to_wear({})) != [BASE_PIECE]:
		_fail("an empty equipment recipe does not wear the ragged base")
		return
	var layered := CharacterFactory.pieces_to_wear({
		"legs": "pants_wool", "feet": ["shoes_cloth", "boots_worn"] })
	if Array(layered) != [BASE_PIECE, "pants_wool", "boots_worn"]:
		_fail("base/clothing/armour render order drifted: %s" % str(layered))
		return

	# The real build, not only the resolver, carries the garment and its body
	# tuck even for a version-1 recipe that has no equipment field at all.
	var built := CharacterFactory.build({ "version": 1 })
	if built == null:
		_fail("a version-1 recipe stopped building")
		return
	add_child(built)
	var skeleton := CharacterFactory.find_skeleton(built)
	var garment := skeleton.get_node_or_null(
		NodePath(CharacterFactory.EQUIP_PREFIX + BASE_PIECE)) as MeshInstance3D
	if garment == null:
		_fail("the ragged base was not composed onto an otherwise-unequipped character")
		return
	var material := garment.get_active_material(0) as StandardMaterial3D
	if material == null or material.albedo_texture == null \
			or material.roughness_texture == null or material.normal_texture == null:
		_fail("the base garment has no woven albedo/roughness/normal material — a flat tint is placeholder art")
		return

	# "Under clothing" is geometric, not merely registry ordering. At the
	# waistband the base must sit inside the ordinary trousers with a small
	# clearance, otherwise the supposedly hidden belt peeks out at either hip.
	var dressed := CharacterFactory.build({
		"version": 2,
		"equipment": { "legs": "pants_wool" },
	})
	if dressed == null:
		_fail("a dressed character stopped building")
		return
	add_child(dressed)
	var dressed_skeleton := CharacterFactory.find_skeleton(dressed)
	var dressed_base := dressed_skeleton.get_node_or_null(
		NodePath(CharacterFactory.EQUIP_PREFIX + BASE_PIECE)) as MeshInstance3D
	var trousers := dressed_skeleton.get_node_or_null(
		NodePath(CharacterFactory.EQUIP_PREFIX + "pants_wool")) as MeshInstance3D
	var base_width := _waist_half_width(dressed_base)
	var trouser_width := _waist_half_width(trousers)
	if base_width <= 0.0 or trouser_width <= 0.0 or base_width + 0.005 > trouser_width:
		_fail("base belt is not tucked inside trousers at the waist (%.3f vs %.3f; AABBs %s vs %s)" \
			% [base_width, trouser_width, dressed_base.mesh.get_aabb(), trousers.mesh.get_aabb()])
		return
	dressed.free()

	var body := CharacterFactory.find_skinned_mesh(skeleton)
	var hide_name := String(base.get("hide_shape", ""))
	var hide_idx := body.find_blend_shape_by_name(hide_name)
	if hide_name == "" or hide_idx < 0 or not is_equal_approx(body.get_blend_shape_value(hide_idx), 1.0):
		_fail("the base garment does not tuck the covered body through '%s'" % hide_name)
		return

	# Negative control: the known piece is refused specifically because base is
	# kit-owned. Unknown-piece rejection cannot satisfy this assertion.
	var illegal := CharacterFactory._resolve_equipment({ "pelvis": BASE_PIECE }, 2)
	if String(illegal.get("problem", "")) != ("piece '%s' is on the base layer, which the kit composes; "
		+ "recipes cannot remove or override it") % BASE_PIECE:
		_fail("a recipe-addressed base piece was not refused for the base-layer law: %s" % illegal.get("problem", ""))
		return

	built.free()
	print("TEST PASS — empty and dressed recipes keep the unremovable ragged base beneath clothing and armour")
	get_tree().quit(0)


func _waist_half_width(piece: MeshInstance3D) -> float:
	if piece == null or piece.mesh == null:
		return 0.0
	var half_width := 0.0
	for surface_idx in piece.mesh.get_surface_count():
		var arrays := piece.mesh.surface_get_arrays(surface_idx)
		var vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		for vertex in vertices:
			# Blender's Z-up garment coordinates import into Godot's Y-up mesh.
			if vertex.y >= 0.885 and vertex.y <= 0.94:
				half_width = maxf(half_width, absf(vertex.x))
	return half_width


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
