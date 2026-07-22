extends Node
## Contract-stage regression for independently editable outfit layers (#253,
## under wardrobe epic #222).
##
## v0.50.0 baked capability-2 reads without a production writer. This test pins
## the separate writer release that follows it:
##
##  1. The shipped creator keeps its single read-only region control for a
##     layered recipe unless the preview is explicitly enabled.
##  2. The opt-in surface exposes distinct clothing and armour controls.
##  3. Editing either real UI control preserves the untouched layer.
##  4. This contract build advertises read 2 / write 2.
##
## Run: godot --headless --path client res://tests/creator_outfit_layers_test.tscn

const LAYERED_OUTFIT_ENV := "WAR_LAYERED_OUTFIT_PICKERS"


var _original_flag := ""


func _ready() -> void:
	_original_flag = OS.get_environment(LAYERED_OUTFIT_ENV)

	# A plain boot retains the honest safe default: one disabled region picker
	# for a recipe it cannot fully represent. #336 owns retiring this flag after
	# the creator receives an authored wardrobe surface.
	OS.set_environment(LAYERED_OUTFIT_ENV, "")
	var default_player := Player.new()
	add_child(default_player)
	var default_creator := CharacterCreator.new()
	add_child(default_creator)
	default_creator.open(default_player, _layered_recipe(), false)
	if not _has_one_disabled_feet_picker(default_creator):
		_fail("the expansion build changed the default layered-recipe writer surface")
		return
	default_creator.free()
	default_player.free()

	# The separate contract release may now activate the already-baked writer,
	# but only behind the deliberate preview opt-in.
	OS.set_environment(LAYERED_OUTFIT_ENV, "1")
	var player := Player.new()
	add_child(player)
	var creator := CharacterCreator.new()
	add_child(creator)
	creator.open(player, _layered_recipe(), false)
	var feet_pickers := _feet_pickers(creator)
	var clothing := feet_pickers[0] as OptionButton
	var armour := feet_pickers[1] as OptionButton
	if clothing == null or armour == null or clothing == armour \
			or clothing.disabled or armour.disabled:
		_fail("the contract build did not expose distinct enabled clothing and armour controls")
		return

	if UpdateManifest.SAVE_CAPABILITY_READS != 2 \
			or UpdateManifest.SAVE_CAPABILITY_WRITES != 2:
		_fail("the contract build advertises read/write capabilities %d/%d instead of 2/2" % [
			UpdateManifest.SAVE_CAPABILITY_READS,
			UpdateManifest.SAVE_CAPABILITY_WRITES,
		])
		return

	var feet_layers := CharacterCreator.pickable_layers(
		CharacterFactory.equipment_registry(), "feet")
	if feet_layers != ["clothing", "armor"]:
		_fail("the baked contract-stage controls lost the feet layer order: %s" % str(feet_layers))
		return

	# Exercise the actual player control rather than calling the mutator directly:
	# selecting bare armour must leave the exact clothing value untouched.
	if not _select_item(armour, "bare"):
		return
	var equipment: Dictionary = creator._recipe.get("equipment", {})
	if equipment.get("feet", null) != "shoes_cloth":
		_fail("removing feet armour changed the clothing layer: %s" % str(equipment.get("feet", null)))
		return

	if not _select_item(armour, "boots_worn"):
		return
	equipment = creator._recipe.get("equipment", {})
	if equipment.get("feet", null) != ["shoes_cloth", "boots_worn"] \
			or int(creator._recipe.get("version", 0)) != CharacterFactory.LAYERED_EQUIPMENT_VERSION:
		_fail("the capability-2 writer did not persist and stamp both layers: %s" % str(creator._recipe))
		return

	if not _select_item(clothing, "bare"):
		return
	equipment = creator._recipe.get("equipment", {})
	if equipment.get("feet", null) != "boots_worn":
		_fail("removing feet clothing changed the armour layer: %s" % str(equipment.get("feet", null)))
		return
	if int(creator._recipe.get("version", 0)) != 2:
		_fail("the single remaining armour piece did not return to recipe version 2")
		return

	print("TEST PASS — capability-2 writer edits independent outfit controls without flattening player state")
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


func _has_one_disabled_feet_picker(creator: CharacterCreator) -> bool:
	var pickers := _feet_pickers(creator)
	var clothing := pickers[0] as OptionButton
	var armour := pickers[1] as OptionButton
	return clothing != null and clothing == armour and clothing.disabled


## Returns [clothing picker, armour picker]. During expansion both entries point
## at the same read-only region picker. A later contract release may expose two.
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


func _select_item(picker: OptionButton, item_name: String) -> bool:
	for i in picker.item_count:
		if picker.get_item_text(i) == item_name:
			picker.select(i)
			picker.item_selected.emit(i)
			return true
	_fail("the picker does not offer '%s': %s" % [item_name, str(_item_names(picker))])
	return false


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _exit_tree() -> void:
	OS.set_environment(LAYERED_OUTFIT_ENV, _original_flag)
