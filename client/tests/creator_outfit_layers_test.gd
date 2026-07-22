extends Node
## Expansion-stage regression for independently editable outfit layers (#253,
## under wardrobe epic #222).
##
## Recipe schema v4 can already read and preserve layered equipment, but the
## rollout contract requires one published build to advertise capability-2
## reads while it still writes capability 1. This test pins that seam:
##
##  1. The shipped creator keeps its single read-only region control for a
##     layered recipe.
##  2. The reserved environment flag cannot bypass the write-capability gate.
##  3. The baked contract-stage mutator preserves every untouched layer.
##  4. This expansion build advertises read 2 / write 1.
##
## Run: godot --headless --path client res://tests/creator_outfit_layers_test.tscn

const LAYERED_OUTFIT_ENV := "WAR_LAYERED_OUTFIT_PICKERS"


var _original_flag := ""


func _ready() -> void:
	_original_flag = OS.get_environment(LAYERED_OUTFIT_ENV)

	# A plain boot retains the honest shipped limitation: one disabled region
	# picker for a recipe it cannot fully represent.
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

	# Even an explicit environment value may not activate the writer until a
	# later contract release raises SAVE_CAPABILITY_WRITES to 2.
	OS.set_environment(LAYERED_OUTFIT_ENV, "1")
	var player := Player.new()
	add_child(player)
	var creator := CharacterCreator.new()
	add_child(creator)
	creator.open(player, _layered_recipe(), false)
	if not _has_one_disabled_feet_picker(creator):
		_fail("the reserved flag bypasses the required read-2/write-1 bake release")
		return

	if UpdateManifest.SAVE_CAPABILITY_READS != 2 \
			or UpdateManifest.SAVE_CAPABILITY_WRITES != 1:
		_fail("the expansion build advertises read/write capabilities %d/%d instead of 2/1" % [
			UpdateManifest.SAVE_CAPABILITY_READS,
			UpdateManifest.SAVE_CAPABILITY_WRITES,
		])
		return

	var feet_layers := CharacterCreator.pickable_layers(
		CharacterFactory.equipment_registry(), "feet")
	if feet_layers != ["clothing", "armor"]:
		_fail("the baked contract-stage controls lost the feet layer order: %s" % str(feet_layers))
		return

	# Exercise the baked mutator directly. It is intentionally unreachable from
	# production UI in this release, but the later contract flip must not discover
	# that it silently rewrites the layer the player did not touch.
	creator._set_recipe_equipment("feet", "armor", "")
	var equipment: Dictionary = creator._recipe.get("equipment", {})
	if equipment.get("feet", null) != "shoes_cloth":
		_fail("removing feet armour changed the clothing layer: %s" % str(equipment.get("feet", null)))
		return

	creator._set_recipe_equipment("feet", "armor", "boots_worn")
	creator._set_recipe_equipment("feet", "clothing", "")
	equipment = creator._recipe.get("equipment", {})
	if equipment.get("feet", null) != "boots_worn":
		_fail("removing feet clothing changed the armour layer: %s" % str(equipment.get("feet", null)))
		return

	print("TEST PASS — capability-2 reads bake while the layered writer remains unreachable")
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


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _exit_tree() -> void:
	OS.set_environment(LAYERED_OUTFIT_ENV, _original_flag)
