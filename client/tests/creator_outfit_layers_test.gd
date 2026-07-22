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
##  1. The unfinished layer UI is default-off: without the explicit opt-in, the
##     existing single region picker stays read-only for a layered recipe.
##  2. Opting in makes clothing and armour simultaneously visible in separate,
##     enabled pickers.
##  3. Editing either layer preserves the other layer byte-for-byte.
##  4. A build that can originate the layered value advertises save capability
##     2 for both reads and writes.
##
## Run: godot --headless --path client res://tests/creator_outfit_layers_test.tscn

const LAYERED_OUTFIT_ENV := "WAR_LAYERED_OUTFIT_PICKERS"


var _original_flag := ""


func _ready() -> void:
	_original_flag = OS.get_environment(LAYERED_OUTFIT_ENV)
	# Product law: this text-led preview is not the shipped creator surface yet.
	# A plain boot must keep the previously shipped honest limitation — one
	# disabled region picker for a recipe it cannot fully represent.
	OS.set_environment(LAYERED_OUTFIT_ENV, "")
	var default_player := Player.new()
	add_child(default_player)
	var default_creator := CharacterCreator.new()
	add_child(default_creator)
	default_creator.open(default_player, _layered_recipe(), false)
	var default_pickers := _feet_pickers(default_creator)
	var default_clothing := default_pickers[0] as OptionButton
	var default_armour := default_pickers[1] as OptionButton
	if default_clothing == null or default_armour == null:
		_fail("the default creator no longer surfaces the worn feet region honestly")
		return
	if default_clothing != default_armour or not default_clothing.disabled:
		_fail("the unfinished independent layer controls ship without the explicit opt-in")
		return
	default_creator.free()
	default_player.free()

	# The opt-in state is the feature under test.
	OS.set_environment(LAYERED_OUTFIT_ENV, "1")
	var player := Player.new()
	add_child(player)
	var creator := CharacterCreator.new()
	add_child(creator)
	creator.open(player, _layered_recipe(), false)

	var pickers := _feet_pickers(creator)
	var clothing := pickers[0] as OptionButton
	var armour := pickers[1] as OptionButton

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
	if UpdateManifest.SAVE_CAPABILITY_READS < 2 or UpdateManifest.SAVE_CAPABILITY_WRITES < 2:
		_fail(("the layered writer is live but the manifest still advertises read/write "
			+ "capabilities %d/%d instead of capability 2") % [
			UpdateManifest.SAVE_CAPABILITY_READS,
			UpdateManifest.SAVE_CAPABILITY_WRITES,
		])
		return

	print("TEST PASS — layered outfit controls stay default-off and edit each layer independently when opted in")
	get_tree().quit(0)


func _layered_recipe() -> Dictionary:
	return {
		"version": CharacterFactory.LAYERED_EQUIPMENT_VERSION,
		"equipment": {
			"torso": "shirt_ragged",
			"legs": "pants_wool",
			"feet": ["shoes_cloth", "boots_worn"],
		},
	}


## Returns [clothing picker, armour picker]. With the default single-region UI
## both entries intentionally point at the SAME picker; under the opt-in they
## point at two independent controls.
func _feet_pickers(creator: CharacterCreator) -> Array:
	var clothing: OptionButton = null
	var armour: OptionButton = null
	for node: Node in creator.find_children("*", "OptionButton", true, false):
		var picker := node as OptionButton
		var names := _item_names(picker)
		if "shoes_cloth" in names:
			if clothing != null:
				_fail("the creator exposes shoes_cloth in more than one picker")
				return [null, null]
			clothing = picker
		if "boots_worn" in names:
			if armour != null:
				_fail("the creator exposes boots_worn in more than one picker")
				return [null, null]
			armour = picker
	return [clothing, armour]


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


func _exit_tree() -> void:
	OS.set_environment(LAYERED_OUTFIT_ENV, _original_flag)
