extends Node
## Regression test for independently editable outfit layers in the creator
## (#253, under wardrobe epic #222).
##
## A layered recipe can wear clothing and armour in the same body region. The
## creator used to collapse both into one disabled region picker: it displayed
## only the outer piece and gave the player no way to see or edit the clothing
## underneath. This test drives the real creator controls and pins both halves
## of the contract:
##
##  1. The clothing and armour pieces are simultaneously visible in separate,
##     enabled pickers.
##  2. Editing either layer preserves the other layer byte-for-byte.
##
## Run: godot --headless --path client res://tests/creator_outfit_layers_test.tscn


func _ready() -> void:
	var player := Player.new()
	add_child(player)
	var creator := CharacterCreator.new()
	add_child(creator)
	creator.open(player, {
		"version": CharacterFactory.LAYERED_EQUIPMENT_VERSION,
		"equipment": {
			"torso": "shirt_ragged",
			"legs": "pants_wool",
			"feet": ["shoes_cloth", "boots_worn"],
		},
	}, false)

	var clothing: OptionButton = null
	var armour: OptionButton = null
	for node: Node in creator.find_children("*", "OptionButton", true, false):
		var picker := node as OptionButton
		var names := _item_names(picker)
		if "shoes_cloth" in names:
			if clothing != null:
				_fail("the creator exposes shoes_cloth in more than one picker")
				return
			clothing = picker
		if "boots_worn" in names:
			if armour != null:
				_fail("the creator exposes boots_worn in more than one picker")
				return
			armour = picker

	if clothing == null or armour == null:
		_fail("the feet region does not expose both clothing and armour controls")
		return
	if clothing == armour:
		_fail("clothing and armour are flattened into one feet picker")
		return
	if clothing.disabled or armour.disabled:
		_fail("a layered feet recipe is visible but still read-only")
		return
	if clothing.get_item_text(clothing.selected) != "shoes_cloth":
		_fail("the clothing picker does not show the worn shoes")
		return
	if armour.get_item_text(armour.selected) != "boots_worn":
		_fail("the armour picker does not show the worn boots")
		return

	# Remove only the armour. The clothing must survive in the compact
	# single-name form, rather than being silently removed or rewritten as a
	# one-element list.
	armour.select(0)
	armour.item_selected.emit(0)
	var equipment: Dictionary = creator._recipe.get("equipment", {})
	if equipment.get("feet", null) != "shoes_cloth":
		_fail("removing feet armour changed the clothing layer: %s" % str(equipment.get("feet", null)))
		return

	# Put the armour back, then remove only the clothing. The armour must remain
	# under its original name. This is the opposite mutation, so a setter that
	# always preserves the inner layer cannot pass both controls accidentally.
	var boots_index := _item_index(armour, "boots_worn")
	if boots_index < 0:
		_fail("the armour picker lost boots_worn after editing")
		return
	armour.select(boots_index)
	armour.item_selected.emit(boots_index)
	clothing.select(0)
	clothing.item_selected.emit(0)
	equipment = creator._recipe.get("equipment", {})
	if equipment.get("feet", null) != "boots_worn":
		_fail("removing feet clothing changed the armour layer: %s" % str(equipment.get("feet", null)))
		return

	print("TEST PASS — creator shows and edits clothing/armour independently without flattening the outfit")
	get_tree().quit(0)


func _item_names(picker: OptionButton) -> Array[String]:
	var out: Array[String] = []
	for i in picker.item_count:
		out.append(picker.get_item_text(i))
	return out


func _item_index(picker: OptionButton, text: String) -> int:
	for i in picker.item_count:
		if picker.get_item_text(i) == text:
			return i
	return -1


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
