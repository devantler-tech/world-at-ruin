extends Node
## Regression test for LAYERED equipment (#246, first slice of #222).
##
## A registry `slot` is a body REGION; a `layer` is what sits over what within
## it. Before this split a region held exactly one piece, and the kit's own data
## already contradicted that: `shoes_cloth` and `boots_worn` both claim `feet`,
## so putting boots on a character silently took their shoes off.
##
## What is pinned here:
##  1. Both pieces are ACCEPTED on one region, and the armour one is what shows.
##  2. Occlusion is CONDITIONAL on the occluder being worn — cloth shoes render
##     perfectly well when there are no boots over them.
##  3. Occlusion is DATA, not a shoes/boots special case: the same call against
##     a synthetic registry differing ONLY in `occluded_by` flips the answer.
##  4. Render order comes from the KIT (clothing, then armour; then the kit's
##     slot order), never from the order a save serialised its keys in.
##  5. An occluded piece is not built AND does not tuck the body's skin under
##     it — otherwise removing the boots would reveal a dent where the shoes were.
##  6. The single-name form every shipped recipe uses is identical to a
##     one-element list, forever.
##  7. The list form is version 4 — a recipe claiming an older version may not
##     use it, or a rollback would strand the character.
##  8. The editor reads both layers and never downgrades a layered recipe on
##     save. The independent player controls are pinned separately by
##     `creator_outfit_layers_test`.
##  9. Each law has its own negative control, failing for its own reason.
##
## Pure logic + the baked registry for most of it; one real build for 5.
##
## Run: godot --headless --path client res://tests/equipment_layers_test.tscn

var _failed := false


func _ready() -> void:
	var registry := CharacterFactory.equipment_registry()
	var pieces: Dictionary = registry.get("pieces", {})
	# Non-vacuity: an unreadable registry makes every assertion below pass
	# without comparing anything — a broken scanner reads like a clean one.
	if pieces.is_empty():
		_fail("the baked equipment registry is empty or unreadable — every check below would pass vacuously")
		return
	# The fixtures this test reasons about must actually be the shape it assumes,
	# or a kit change could make the checks below true for the wrong reason.
	if String(pieces.get("shoes_cloth", {}).get("layer", "")) != "clothing":
		_fail("fixture precondition broken: shoes_cloth is not a clothing piece")
		return
	if String(pieces.get("boots_worn", {}).get("layer", "")) != "armor":
		_fail("fixture precondition broken: boots_worn is not an armour piece")
		return
	if "armor" not in (pieces["shoes_cloth"] as Dictionary).get("occluded_by", []):
		_fail("fixture precondition broken: shoes_cloth does not declare that armour occludes it")
		return

	# 1. Clothing and armour are both accepted on ONE region — the capability
	#    that did not exist before — and the armour layer is what renders.
	var both := CharacterFactory.pieces_to_wear({ "feet": ["shoes_cloth", "boots_worn"] })
	if Array(both) != ["loincloth_ragged", "boots_worn"]:
		_fail("boots over cloth shoes should render after the implicit base, got %s" % str(both))
		return

	# 2. The occlusion is CONDITIONAL, not a blanket hide: with no armour on the
	#    region, the cloth shoes render. Without this the check above would also
	#    pass if `shoes_cloth` were simply never renderable.
	var alone := CharacterFactory.pieces_to_wear({ "feet": ["shoes_cloth"] })
	if Array(alone) != ["loincloth_ragged", "shoes_cloth"]:
		_fail("cloth shoes with no armour should render after the implicit base, got %s" % str(alone))
		return

	# 3. THE ABLATION: occlusion comes from kit DATA. Two synthetic registries
	#    differing ONLY in `occluded_by` must give opposite answers — if the rule
	#    were hardcoded for shoes-under-boots, both would agree.
	var worn := { "clothing": "inner", "armor": "outer" }
	var with_rule := {
		"inner": { "layer": "clothing", "occluded_by": ["armor"] },
		"outer": { "layer": "armor" },
	}
	var without_rule := {
		"inner": { "layer": "clothing" },
		"outer": { "layer": "armor" },
	}
	if not CharacterFactory._is_occluded("inner", worn, with_rule):
		_fail("a piece declaring occluded_by:[armor] was NOT occluded by armour in its region")
		return
	if CharacterFactory._is_occluded("inner", worn, without_rule):
		_fail("a piece declaring NO occluded_by was occluded anyway — the rule is not coming from the data")
		return
	# ...and a piece never occludes itself, however its own layer is named.
	var self_named := { "inner": { "layer": "clothing", "occluded_by": ["clothing"] } }
	if CharacterFactory._is_occluded("inner", { "clothing": "inner" }, self_named):
		_fail("a piece occluded itself — its own layer must never count as an occluder")
		return

	# 4. Render order is the KIT's, not the save's. The same outfit written with
	#    its keys (and its list) in the opposite order must build identically.
	var forward := CharacterFactory.pieces_to_wear({
		"torso": "shirt_ragged", "legs": "pants_wool", "feet": ["shoes_cloth", "boots_worn"] })
	var reversed_keys := CharacterFactory.pieces_to_wear({
		"feet": ["boots_worn", "shoes_cloth"], "legs": "pants_wool", "torso": "shirt_ragged" })
	if Array(forward) != Array(reversed_keys):
		_fail("key/list order changed the outfit: %s vs %s" % [str(forward), str(reversed_keys)])
		return
	# Clothing strictly before armour, so armour is composed over it.
	var last_clothing := -1
	var first_armor := forward.size()
	for i in forward.size():
		var layer := String((pieces[forward[i]] as Dictionary)["layer"])
		if layer == "clothing":
			last_clothing = i
		elif layer == "armor" and first_armor == forward.size():
			first_armor = i
	if last_clothing > first_armor:
		_fail("armour is not composed over clothing: order was %s" % str(forward))
		return

	# 5. An occluded piece is not built, and — the part a mesh check alone would
	#    miss — does not set its equip_hide_* shape either. A hidden piece that
	#    still tucked the skin would leave a dent when the boots came off.
	var built := CharacterFactory.build({ "version": 4,
		"equipment": { "torso": "shirt_ragged", "feet": ["shoes_cloth", "boots_worn"] } })
	if built == null:
		_fail("a character wearing boots over cloth shoes failed to build")
		return
	add_child(built)
	var skeleton := CharacterFactory.find_skeleton(built)
	var body := CharacterFactory.find_skinned_mesh(skeleton)
	if skeleton.get_node_or_null(NodePath(CharacterFactory.EQUIP_PREFIX + "boots_worn")) == null:
		_fail("the boots were not built onto the character")
		return
	if skeleton.get_node_or_null(NodePath(CharacterFactory.EQUIP_PREFIX + "shoes_cloth")) != null:
		_fail("the occluded cloth shoes were built anyway")
		return
	var shoes_hide := body.find_blend_shape_by_name("equip_hide_shoes_cloth")
	if shoes_hide < 0:
		_fail("fixture precondition broken: the body has no equip_hide_shoes_cloth shape")
		return
	if not is_zero_approx(body.get_blend_shape_value(shoes_hide)):
		_fail("the occluded cloth shoes still tucked the body's skin — removing the boots would reveal a dent")
		return
	# The boots, which ARE worn, must still tuck.
	var boots_hide := body.find_blend_shape_by_name("equip_hide_boots_worn")
	if boots_hide < 0 or not is_equal_approx(body.get_blend_shape_value(boots_hide), 1.0):
		_fail("the worn boots did not tuck the body's skin under them")
		return
	built.free()

	# 6. FORWARD-ONLY: the single-name form is exactly a one-element list. Every
	#    shipped recipe uses the single-name form, so this may never diverge.
	var single := CharacterFactory.build({ "version": 2, "equipment": { "legs": "pants_wool" } })
	var listed := CharacterFactory.build({ "version": 4, "equipment": { "legs": ["pants_wool"] } })
	if single == null or listed == null:
		_fail("the single-name and one-element-list forms do not both build")
		return
	if CharacterFactory.fingerprint(single) != CharacterFactory.fingerprint(listed):
		_fail("the single-name form and a one-element list produced different characters")
		return
	single.free()
	listed.free()

	# 7. Negative controls — each recipe violates exactly ONE law, so a refusal
	#    can only be for the reason named.
	for bad: Dictionary in [
		# two clothing pieces on one region: the second would silently win
		{ "version": 4, "equipment": { "feet": ["shoes_cloth", "shoes_cloth"] } },
		# an empty list is not "wear nothing" — omit the slot instead
		{ "version": 4, "equipment": { "feet": [] } },
		# a non-name entry
		{ "version": 4, "equipment": { "feet": [42] } },
		# a piece that belongs to another region
		{ "version": 4, "equipment": { "feet": ["shirt_ragged", "boots_worn"] } },
		# an unknown piece hiding inside an otherwise-valid list
		{ "version": 4, "equipment": { "feet": ["no_such_piece", "boots_worn"] } },
		# THE VERSION GATE: the list form is version 4, so a recipe claiming an
		# older version may not use it — a version-3 client would read the array
		# as one piece name and strand the character.
		{ "version": 3, "equipment": { "feet": ["shoes_cloth", "boots_worn"] } },
		{ "version": 2, "equipment": { "feet": ["shoes_cloth", "boots_worn"] } },
	]:
		var rejected := CharacterFactory.build(bad)
		if rejected != null:
			rejected.free()
			_fail("invalid layered recipe was accepted: %s" % JSON.stringify(bad))
			return

	# 8. THE EDITOR MUST NOT SILENTLY UNDRESS ANYONE. The creator has one picker
	#    per region, so editing a region of a layered outfit used to replace the
	#    whole list with one name — dropping the layer the picker cannot show.
	#    Nothing produces a layered recipe yet, but THIS change is what makes the
	#    array a valid persisted value, so the guard belongs with it.
	var creator := preload("res://scripts/character_creator.gd").new()
	creator._recipe = { "version": 4, "equipment": { "feet": ["shoes_cloth", "boots_worn"] } }
	# It reads BOTH layers rather than stringifying the list — that misread is
	# what made a layered region display as "bare".
	var worn_feet := creator._worn_by_layer("feet")
	if String(worn_feet.get("armor", "")) != "boots_worn" or String(worn_feet.get("clothing", "")) != "shoes_cloth":
		_fail("the editor misread a layered region: %s" % str(worn_feet))
		creator.free()
		return
	# 9. SAVING MUST NOT DOWNGRADE A LAYERED RECIPE. The panel can now create and
	#    edit this state; stamping it 3 would make the save
	#    understate its own shape and a version-3 client would refuse to load it.
	creator._restamp_version()
	if int(creator._recipe["version"]) != CharacterFactory.LAYERED_EQUIPMENT_VERSION:
		_fail("a layered recipe was stamped version %s, not %d"
			% [str(creator._recipe["version"]), CharacterFactory.LAYERED_EQUIPMENT_VERSION])
		creator.free()
		return
	# A single-piece recipe is NOT churned upward — it keeps its own version.
	creator._recipe = { "version": 2, "equipment": { "legs": "pants_wool" } }
	creator._restamp_version()
	if int(creator._recipe["version"]) != 2:
		_fail("a single-piece recipe was churned to version %s" % str(creator._recipe["version"]))
		creator.free()
		return
	creator.free()

	print("TEST PASS — layered equipment holds (%d baked pieces, layers %s; occlusion proven data-driven by ablation, order proven kit-driven, occluded pieces neither build nor tuck; list form gated at version %d; editor reads both layers and never downgrades)"
		% [pieces.size(), str(CharacterFactory.LAYERS), CharacterFactory.LAYERED_EQUIPMENT_VERSION])
	get_tree().quit(0)


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
