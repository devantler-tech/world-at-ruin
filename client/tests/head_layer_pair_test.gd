extends Node
## End-to-end contract for the first eyewear-under-helm pair (#329, epic #222).
##
## The feet pair proved the generic layer resolver with existing garments. This
## test pins the case the rule was designed for:
##  1. eyewear and a helm are real baked pieces sharing the head region;
##  2. the helm occludes eyewear through registry data, including a real build;
##  3. both names are anchored in every forward-only equipment ledger;
##  4. the new below-bar pair is not offered by the default creator, while the
##     existing layered-outfit preview exposes independent clothing/armour
##     controls and can originate the pair without flattening either layer;
##  5. turning the preview off never makes an already-authored recipe unreadable.
##
## Run: godot --headless --path client res://tests/head_layer_pair_test.tscn

const EYEWEAR := "relic_goggles"
const HELM := "ruin_drake_helm"
const PREVIEW_ENV := "WAR_LAYERED_OUTFIT_PICKERS"
const SHIPPED := "res://tests/data/shipped_equipment.txt"
const SLOTS := "res://tests/data/shipped_piece_slots.txt"
const LAYERS := "res://tests/data/shipped_piece_layers.txt"

var _original_preview := ""


func _ready() -> void:
	_original_preview = OS.get_environment(PREVIEW_ENV)
	var registry := CharacterFactory.equipment_registry()
	var pieces: Dictionary = registry.get("pieces", {})
	if EYEWEAR not in pieces or HELM not in pieces:
		_fail("the baked head pair is missing: eyewear=%s helm=%s" \
			% [EYEWEAR in pieces, HELM in pieces])
		return

	var eyewear: Dictionary = pieces[EYEWEAR]
	var helm: Dictionary = pieces[HELM]
	if String(eyewear.get("slot", "")) != "head" \
			or String(eyewear.get("layer", "")) != "clothing" \
			or "armor" not in eyewear.get("occluded_by", []):
		_fail("eyewear is not clothing in head occluded by armour: %s" % str(eyewear))
		return
	if String(helm.get("slot", "")) != "head" \
			or String(helm.get("layer", "")) != "armor":
		_fail("helm is not armour in head: %s" % str(helm))
		return

	var eyewear_only := CharacterFactory.pieces_to_wear({"head": EYEWEAR})
	if EYEWEAR not in eyewear_only:
		_fail("eyewear does not render when no helm is worn: %s" % str(eyewear_only))
		return
	var both := CharacterFactory.pieces_to_wear({"head": [EYEWEAR, HELM]})
	if HELM not in both or EYEWEAR in both:
		_fail("helm did not data-occlude eyewear: %s" % str(both))
		return

	# A real layered recipe must keep building even when the authoring preview
	# is disabled. Flags control origination, never whether saved state survives.
	OS.set_environment(PREVIEW_ENV, "")
	var built := CharacterFactory.build({
		"version": CharacterFactory.LAYERED_EQUIPMENT_VERSION,
		"equipment": {"head": [EYEWEAR, HELM]},
	})
	if built == null:
		_fail("an already-authored head pair stopped building with the preview off")
		return
	add_child(built)
	var skeleton := CharacterFactory.find_skeleton(built)
	if skeleton.get_node_or_null(NodePath(CharacterFactory.EQUIP_PREFIX + HELM)) == null:
		_fail("the real build did not attach the helm")
		return
	if skeleton.get_node_or_null(NodePath(CharacterFactory.EQUIP_PREFIX + EYEWEAR)) != null:
		_fail("the real build attached eyewear beneath the occluding helm")
		return
	built.free()

	for contract: Array in [
		[SHIPPED, EYEWEAR], [SHIPPED, HELM],
		[SLOTS, EYEWEAR + " head"], [SLOTS, HELM + " head"],
		[LAYERS, EYEWEAR + " clothing"], [LAYERS, HELM + " armor"],
	]:
		if not _has_ledger_line(contract[0], contract[1]):
			_fail("%s does not anchor '%s'" % [contract[0], contract[1]])
			return

	# Default-off means a new character cannot originate the below-bar pieces
	# through the ordinary creator. The reader/build path above stays live.
	var default_player := Player.new()
	add_child(default_player)
	var default_creator := CharacterCreator.new()
	add_child(default_creator)
	default_creator.open(default_player, {"version": 1}, false)
	if _picker_with(default_creator, EYEWEAR) != null \
			or _picker_with(default_creator, HELM) != null:
		_fail("the default creator offered the experimental head pair")
		return
	default_creator.free()
	default_player.free()

	# The existing opt-in layered editor exposes one control per head layer and
	# writes both names without one replacing the other.
	OS.set_environment(PREVIEW_ENV, "1")
	var player := Player.new()
	add_child(player)
	var creator := CharacterCreator.new()
	add_child(creator)
	creator.open(player, {"version": 1}, false)
	var clothing := _picker_with(creator, EYEWEAR)
	var armour := _picker_with(creator, HELM)
	if clothing == null or armour == null or clothing == armour \
			or clothing.disabled or armour.disabled:
		_fail("the opted-in creator did not expose independent head-layer controls")
		return
	if not _select(clothing, EYEWEAR) or not _select(armour, HELM):
		return
	var authored: Variant = (creator._recipe.get("equipment", {}) as Dictionary).get("head")
	if authored != [EYEWEAR, HELM] \
			or int(creator._recipe.get("version", 0)) != CharacterFactory.LAYERED_EQUIPMENT_VERSION:
		_fail("the head controls flattened or misstamped the pair: %s" % str(creator._recipe))
		return

	print("TEST PASS — first head pair is baked, ledgered, data-occluded and opt-in authorable without making saved state flag-dependent")
	get_tree().quit(0)


func _picker_with(creator: CharacterCreator, item_name: String) -> OptionButton:
	for node: Node in creator.find_children("*", "OptionButton", true, false):
		var picker := node as OptionButton
		for index in picker.item_count:
			if picker.get_item_text(index) == item_name:
				return picker
	return null


func _select(picker: OptionButton, item_name: String) -> bool:
	for index in picker.item_count:
		if picker.get_item_text(index) == item_name:
			picker.select(index)
			picker.item_selected.emit(index)
			return true
	_fail("picker does not offer '%s'" % item_name)
	return false


func _has_ledger_line(path: String, expected: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	while not file.eof_reached():
		if file.get_line().strip_edges() == expected:
			return true
	return false


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _exit_tree() -> void:
	OS.set_environment(PREVIEW_ENV, _original_preview)
