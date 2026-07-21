class_name CharacterCreator
extends CanvasLayer
## The character creation screen — the first thing a new wanderer ever does,
## and (early-build testing, maintainer direction 2026-07-17) reachable any
## time with C to reshape the character.
##
## No separate scene, no loading screen: the world stays live behind it. The
## player's own in-world body is the preview — shape sliders drive its blend
## weights immediately; bone sliders rebuild the body on release (bone edits
## are rest-pose surgery, not a per-frame knob). A portrait camera and a
## soft key light are brought along and removed on close.

signal applied(recipe: Dictionary)
signal closed

## One palette for the screen, owned by the theme — these are the two marks the
## theme cannot express as a control style (a heading's colour, the blurb's).
const COL_DIM := UiTheme.BONE_DIM
const COL_EMBER := UiTheme.EMBER

const PRESET_DIR := "res://recipes/"
const PRESETS := ["wanderer", "villager", "elder", "brute"]

## What each archetype is, in the player's terms. The recipes carry their own
## `comment`, but those are written for whoever maintains the kit ("first recipe
## on the gender/phenotype axes") — not for someone choosing a body.
const PRESET_BLURBS := {
	"wanderer": "Heroic but human. You wake in the rags the Ruin left you.",
	"villager": "An ordinary body for ordinary people — most of the living are these.",
	"elder": "The village matriarch's silhouette. A woman the Ruin could not kill.",
	"brute": "Mass, reach, and a head built for headbutting.",
}

## How the kit's shape sliders are grouped in the panel, in display order:
## section title, then the shape-name prefixes that belong to it. First match
## wins, so a shape lands in exactly one section.
##
## The kit exposes 29 shape sliders and the panel used to place all of them in
## one undifferentiated run under a single BUILD heading — the "debug panel"
## the first screen of the game read as (#270). Grouping is keyed on the shape
## NAMES rather than a hand-maintained list of them, for the same reason
## `_shape_names()` reads the live mesh: the creator must not go stale when the
## kit gains shapes. Anything unmatched falls into SHAPE_GROUP_FALLBACK, so a
## new shape always appears somewhere — never silently vanishes.
const SHAPE_GROUPS := [
	["ARCHETYPE", ["body_"]],
	["HERITAGE", ["phenotype_"]],
	["TORSO", ["torso_", "shoulders_", "waist_", "belly", "hips_", "buttocks_", "neck_"]],
	["LIMBS", ["arms_", "legs_"]],
	["FACE", ["head_", "chin_", "jaw_", "nose_"]],
]
const SHAPE_GROUP_FALLBACK := "OTHER"

## Bone sliders: label, recipe field, bone key, range. Kept deliberately
## short — the interesting range of each op before skinning artifacts.
const BONE_SLIDERS := [
	["shoulders", "joint_push", "upperarm", 0.94, 1.15],
	["hands", "bone_scale", "hand", 0.9, 1.35],
	["feet", "bone_scale", "foot", 0.9, 1.25],
	["head", "bone_scale", "head", 0.92, 1.12],
	["forearms", "bone_girth", "lowerarm", 0.9, 1.25],
	["calves", "bone_girth", "calf", 0.9, 1.25],
]

var first_run := false

var _player: Player
var _recipe: Dictionary
var _shape_sliders := {}
var _bone_sliders := {}
var _outfit_pickers := {}
var _skin_picker: OptionButton
var _sections: Array[Button] = []
var _portraits: Array[ArchetypePortrait] = []
var _camera: Camera3D
var _light: DirectionalLight3D
var _syncing := false


## Builds and shows the creator over a live player. `initial` is the starting
## recipe (the saved character, or the wanderer preset for a first run).
func open(player: Player, initial: Dictionary, p_first_run: bool) -> void:
	_player = player
	_recipe = initial.duplicate(true)
	first_run = p_first_run
	_player.control_enabled = false
	_player.set_character(_recipe)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_portrait_rig()
	_build_panel()
	_sync_sliders_from_recipe()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and not first_run:
		_close(false)
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	# Track the body — it settles onto the floor for a few ticks after spawn.
	if _camera != null and _player != null:
		var eye := _player.global_position + Vector3(0, 1.0, 0)
		_camera.look_at(eye, Vector3.UP)
	realize_next_portrait()


## Builds ONE archetype portrait's body, if any still needs it. Called once per
## frame rather than building the whole roster in `open()`, because a character
## build is the expensive part and four of them in the frame the creator opens
## is exactly the stall the screen must not have. The roster fills in over the
## first few frames instead; every portrait is a backdrop until its turn.
##
## Returns the portrait it built, or null when the roster is complete.
func realize_next_portrait() -> ArchetypePortrait:
	var portrait := ArchetypePortrait.next_unrealized(_portraits)
	if portrait == null:
		return null
	portrait.realize()
	return portrait


func _build_portrait_rig() -> void:
	var eye := _player.global_position + Vector3(0, 1.25, 0)
	# The third-person camera sits behind the body looking the way it faces,
	# so "in front of the face" is one camera-forward step ahead of the body.
	var view := _player.get_viewport().get_camera_3d()
	var forward := -view.global_transform.basis.z if view != null else Vector3.FORWARD
	forward.y = 0.0
	forward = forward.normalized() if forward.length() > 0.01 else Vector3.FORWARD
	# Parent the rig next to the player — current_scene is null under test
	# harnesses that instance main.tscn by hand.
	var stage := _player.get_parent()
	_camera = Camera3D.new()
	_camera.fov = 45.0
	stage.add_child(_camera)
	_camera.global_position = eye + forward * 3.4 + Vector3(0.5, 0.0, 0.0).rotated(Vector3.UP, atan2(forward.x, forward.z))
	_camera.look_at(eye, Vector3.UP)
	_camera.make_current()

	_light = DirectionalLight3D.new()
	_light.light_color = Color(1.0, 0.9, 0.78)
	_light.light_energy = 1.4
	stage.add_child(_light)
	_light.global_position = _camera.global_position + Vector3(0, 2, 0)
	_light.look_at(eye, Vector3.UP)


func _build_panel() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	panel.custom_minimum_size = Vector2(360, 0)
	# The authored look, applied at the panel root so every control below it
	# inherits — this is the whole screen's styling, not per-control overrides
	# scattered through the builders (#270).
	panel.theme = UiTheme.creator_theme()
	add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	panel.add_child(column)

	var title := Label.new()
	title.text = "SHAPE YOUR WANDERER" if first_run else "RESHAPE YOUR WANDERER"
	title.add_theme_font_size_override("font_size", UiTheme.FONT_TITLE)
	title.add_theme_color_override("font_color", COL_EMBER)
	column.add_child(title)

	var blurb := Label.new()
	blurb.text = "This body is yours to keep — it can always be reshaped here (C)."
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.add_theme_font_size_override("font_size", UiTheme.FONT_BODY)
	blurb.add_theme_color_override("font_color", COL_DIM)
	column.add_child(blurb)

	# The archetypes are the PRIMARY surface: named choices with a line saying
	# what each one is, not a row of terse buttons above a parameter dump. The
	# art direction is explicit that thirty-plus programmer-named sliders as the
	# primary surface is a developer inspector (docs/art-direction/README.md,
	# "UI and UX"), so the numeric controls live behind ADVANCED below.
	# EVERYTHING below the blurb scrolls, and the Wake/Cancel row sits outside it.
	#
	# The roster used to be laid out directly in the column, above a scroll region
	# of its own. That was safe while it was four buttons; adding a portrait to
	# each row made it ~160 px taller and pushed the Wake button off the bottom of
	# the screen at 1600x900 — a first-run player could not start the game with
	# the mouse. Anything that grows the roster would do it again, so the fix is
	# structural rather than a size that happens to fit: the scroll region EXPANDS
	# to take whatever space is left, its content scrolls, and the buttons are
	# pinned below it at every window height.
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(330, 0)
	# A gamepad navigates by moving focus, and a ScrollContainer does not follow
	# focus by default — so a controller reaching the OUTFIT/SKIN/ADVANCED rows
	# below the fold would send focus off the visible area with nothing scrolling
	# to meet it. follow_focus keeps the focused control in view (#293 review).
	scroll.follow_focus = true
	column.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 2)
	scroll.add_child(content)

	# Each archetype is a rendered portrait beside its name and blurb. A text
	# roster asks the player to imagine each option and lets them inspect only
	# the one body currently on screen; portraits make the four comparable at a
	# glance, which is the actual function of a character-choice surface (#293).
	var first_preset: Button = null
	for preset_name in PRESETS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		content.add_child(row)

		var portrait := ArchetypePortrait.new()
		row.add_child(portrait)
		portrait.setup(preset_name)
		_portraits.append(portrait)

		var text_column := VBoxContainer.new()
		text_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text_column.add_theme_constant_override("separation", 2)
		row.add_child(text_column)

		# The Button stays the focusable element and stays inside the container
		# layout, so the automatic focus neighbours a pad depends on are
		# unchanged by the portrait sitting next to it (controller_input_test).
		var choice := Button.new()
		choice.alignment = HORIZONTAL_ALIGNMENT_LEFT
		choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		choice.text = String(preset_name).to_upper()
		choice.add_theme_font_size_override("font_size", UiTheme.FONT_SECTION)
		choice.pressed.connect(_on_preset.bind(preset_name))
		text_column.add_child(choice)

		var blurb_text := String(PRESET_BLURBS.get(preset_name, ""))
		if blurb_text != "":
			var caption := Label.new()
			caption.text = blurb_text
			caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			caption.add_theme_color_override("font_color", COL_DIM)
			text_column.add_child(caption)

		if first_preset == null:
			first_preset = choice

	# Outfit and skin stay on the primary surface: they ARE named choices, which
	# is what the art direction asks the creator to lead with.
	var outfit := _add_section(content, "OUTFIT")
	# Only regions something can actually be put in. #251 declared the whole
	# specified wardrobe (#222) up front so the vocabulary is settled before the
	# garments arrive, which means most regions have no baked piece yet — and a
	# picker whose only entry is "none" is a row the player cannot use. Showing
	# all thirteen would have added nine dead rows to a screen already faulted
	# for reading as a debug panel (#227). Each region appears the moment a piece
	# is baked for it, with no change here.
	for slot: String in pickable_regions(CharacterFactory.equipment_registry()):
		_add_outfit_picker(outfit, slot)
	var skin := _add_section(content, "SKIN")
	_add_skin_picker(skin)

	# Everything numeric, folded away by default. Grouped rather than dumped, so
	# a player who does open it gets a structure instead of 35 identical rows.
	var advanced := _add_section(content, "ADVANCED — fine shaping", false)
	for group: Array in group_shape_names(_shape_names()):
		_add_heading(advanced, group[0])
		for shape_name: String in group[1]:
			_add_shape_slider(advanced, shape_name)
	_add_heading(advanced, "FRAME")
	for spec: Array in BONE_SLIDERS:
		_add_bone_slider(advanced, spec)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	column.add_child(buttons)
	var apply := Button.new()
	apply.text = "Wake" if first_run else "Apply"
	apply.pressed.connect(func() -> void: _close(true))
	buttons.add_child(apply)
	if not first_run:
		var cancel := Button.new()
		cancel.text = "Cancel (Esc)"
		cancel.pressed.connect(func() -> void: _close(false))
		buttons.add_child(cancel)

	# A pad has no pointer: without an initial focus owner the D-pad and
	# ui_accept have nothing to act on, so a first-run controller player could
	# never reach the mandatory Wake button. Focus the panel's first control —
	# the container layout gives every slider and button automatic focus
	# neighbours from there. (open() adds this node to the tree before calling
	# _build_panel, so the control is focusable here.)
	first_preset.grab_focus()


## Sorts shape names into the SHAPE_GROUPS sections, in declared order, keeping
## each section's shapes in the order the kit reports them. Pure and static so
## the grouping contract (every shape placed exactly once, unknown names kept)
## is testable without booting the game — see tests/creator_sections_test.gd.
##
## Returns an Array of [title, PackedStringArray] pairs; empty sections are
## dropped, so a kit that has no face shapes shows no FACE header.
static func group_shape_names(names: PackedStringArray) -> Array:
	# Plain Arrays, not PackedStringArrays: a PackedStringArray is a VALUE type,
	# so `buckets[title].append(...)` would mutate a copy and silently drop every
	# shape. Converted to packed form on the way out, where the copy is the point.
	var buckets := {}
	for spec: Array in SHAPE_GROUPS:
		buckets[spec[0]] = []
	buckets[SHAPE_GROUP_FALLBACK] = []

	for shape_name: String in names:
		var title := SHAPE_GROUP_FALLBACK
		for spec: Array in SHAPE_GROUPS:
			var matched := false
			for prefix: String in spec[1]:
				if shape_name.begins_with(prefix):
					matched = true
					break
			if matched:
				title = spec[0]
				break
		(buckets[title] as Array).append(shape_name)

	var out: Array = []
	var titles: Array = []
	for spec: Array in SHAPE_GROUPS:
		titles.append(spec[0])
	titles.append(SHAPE_GROUP_FALLBACK)
	for title: String in titles:
		var bucket: Array = buckets[title]
		if not bucket.is_empty():
			out.append([title, PackedStringArray(bucket)])
	return out


## A named section the player can fold away, returning the container its rows
## go into. `open` is the section's default state — the numeric-shaping section
## opens CLOSED, because the art direction requires named choices as the primary
## surface with sliders demoted to an advanced section.
func _add_section(into: Container, text: String, open := true) -> Container:
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 2)
	body.visible = open

	var header := Button.new()
	header.toggle_mode = true
	header.button_pressed = open
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.text = ("▾  " if open else "▸  ") + text
	header.add_theme_font_size_override("font_size", UiTheme.FONT_SECTION)
	header.add_theme_color_override("font_color", COL_EMBER)
	header.add_theme_color_override("font_pressed_color", COL_EMBER)
	header.toggled.connect(func(is_open: bool) -> void:
		body.visible = is_open
		header.text = ("▾  " if is_open else "▸  ") + text)
	into.add_child(header)

	into.add_child(body)
	_sections.append(header)
	return body


## Opens every foldable section. The first-run capture evidence photographs the
## controls below the fold by scrolling to the bottom, and the advanced section
## is closed by default — so without this the evidence would silently stop
## depicting the shaping controls entirely (#231). Evidence follows the screen;
## the screen does not stay wrong to keep the evidence convenient.
func expand_all_sections() -> void:
	for header: Button in _sections:
		header.button_pressed = true


func _add_heading(into: Container, text: String) -> void:
	var heading := Label.new()
	heading.text = text
	heading.add_theme_font_size_override("font_size", UiTheme.FONT_SECTION)
	heading.add_theme_color_override("font_color", COL_EMBER)
	into.add_child(heading)


func _add_shape_slider(into: Container, shape_name: String) -> void:
	var slider := _labeled_slider(into, shape_name.replace("_", " "), -0.5, 1.2)
	slider.value_changed.connect(func(v: float) -> void:
		if _syncing:
			return
		_set_recipe_shape(shape_name, v)
		# Through the factory, not the body mesh directly: equipped pieces
		# carry the same shape names and must follow the slider live.
		if _player._character_body != null:
			CharacterFactory.set_shape_weight(_player._character_body, shape_name, v))
	_shape_sliders[shape_name] = slider


## One OptionButton per slot: "bare hands" plus every baked piece that goes
## there. Changing it rebuilds the body (equipping is composition, not a
## per-frame knob — same contract as the bone sliders).
func _add_outfit_picker(into: Container, slot: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	into.add_child(row)
	var label := Label.new()
	label.text = slot
	label.custom_minimum_size = Vector2(130, 0)
	row.add_child(label)
	var picker := OptionButton.new()
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.add_item("bare")
	for piece_name: String in _pieces_in_slot(CharacterFactory.equipment_registry(), slot):
		picker.add_item(piece_name)
	picker.item_selected.connect(func(index: int) -> void:
		if _syncing:
			return
		_set_recipe_equipment(slot, "" if index == 0 else picker.get_item_text(index))
		_player.set_character(_recipe))
	row.add_child(picker)
	_outfit_pickers[slot] = picker


## The regions the OUTFIT section offers a picker for: every declared region
## that something can actually be put in, in the kit's declared order.
##
## #251 declared the whole specified wardrobe (#222) up front so the vocabulary
## is settled before the garments arrive, which means most regions have no baked
## piece yet — and a picker whose only entry is "none" is a row the player
## cannot use. Showing all thirteen would have added nine dead rows to a screen
## already faulted for reading as a debug panel (#227).
##
## Pure and static, like `group_shape_names`, so the rule is checkable without
## standing up the UI — and a region appears the moment a piece is baked for it,
## with no change here.
static func pickable_regions(registry: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for slot: Variant in registry.get("slots", []):
		var region := str(slot)
		if _pieces_in_slot(registry, region).is_empty():
			continue
		out.append(region)
	return out


## Every baked piece that can be worn in this region, sorted so the picker's
## order — and the decision to show the picker at all — never depends on
## dictionary iteration order. Shared by both callers on purpose: the row is
## built from exactly the list that decided the row should exist, so a region
## can never be shown with nothing in it, or hidden while holding something.
static func _pieces_in_slot(registry: Dictionary, slot: String) -> Array[String]:
	var out: Array[String] = []
	var pieces: Dictionary = registry.get("pieces", {})
	for piece_name: String in pieces:
		var piece := pieces[piece_name] as Dictionary
		if String(piece.get("slot", "")) == slot and String(piece.get("layer", "")) != "base":
			out.append(piece_name)
	out.sort()
	return out


## Which skin the body wears — "clay" is the untextured kit body.
func _add_skin_picker(into: Container) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	into.add_child(row)
	var label := Label.new()
	label.text = "skin"
	label.custom_minimum_size = Vector2(130, 0)
	row.add_child(label)
	_skin_picker = OptionButton.new()
	_skin_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_skin_picker.add_item("clay")
	var names = CharacterFactory.skins_registry().get("skins", {}).keys()
	names.sort()
	for skin_name: String in names:
		_skin_picker.add_item(skin_name)
	_skin_picker.item_selected.connect(func(index: int) -> void:
		if _syncing:
			return
		if index == 0:
			_recipe.erase("skin")
		else:
			_recipe["skin"] = _skin_picker.get_item_text(index)
		_restamp_version()
		_player.set_character(_recipe))
	row.add_child(_skin_picker)


func _add_bone_slider(into: Container, spec: Array) -> void:
	var slider := _labeled_slider(into, spec[0], spec[3], spec[4])
	slider.drag_ended.connect(func(changed: bool) -> void:
		if changed and not _syncing:
			_set_recipe_bone(spec[1], spec[2], slider.value)
			_player.set_character(_recipe))
	_bone_sliders[spec[0]] = slider


func _labeled_slider(into: Container, text: String, minimum: float, maximum: float) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	into.add_child(row)
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(130, 0)
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = 0.01
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)
	return slider


## The kit's shape list, straight from the live mesh — the creator never goes
## stale when the kit gains shapes. equip_hide_* shapes are composition
## plumbing (skin tucked under a worn piece), never a slider.
func _shape_names() -> PackedStringArray:
	var names := PackedStringArray()
	var mesh := _player.character_mesh()
	if mesh != null:
		for i in mesh.mesh.get_blend_shape_count():
			var shape_name := String(mesh.mesh.get_blend_shape_name(i))
			if not shape_name.begins_with(CharacterFactory.HIDE_SHAPE_PREFIX):
				names.append(shape_name)
	return names


func _set_recipe_shape(shape_name: String, value: float) -> void:
	if not _recipe.has("shapes"):
		_recipe["shapes"] = {}
	if is_zero_approx(value):
		_recipe["shapes"].erase(shape_name)
	else:
		_recipe["shapes"][shape_name] = value


func _set_recipe_bone(field: String, key: String, value: float) -> void:
	if not _recipe.has(field):
		_recipe[field] = {}
	if is_equal_approx(value, 1.0):
		_recipe[field].erase(key)
	else:
		_recipe[field][key] = value


## Equipment entered the recipe format at version 2 and skin at version 3, so
## a recipe only claims the newest version its fields need — older saves stay
## untouched at their own version.
func _set_recipe_equipment(slot: String, piece_name: String) -> void:
	if not _recipe.has("equipment"):
		_recipe["equipment"] = {}
	if piece_name == "":
		# "bare" is an explicit choice to wear nothing on this region, so it
		# clears every layer there — the one picker speaks for the whole region.
		_recipe["equipment"].erase(slot)
	else:
		# One picker per region means this panel can only ever express ONE piece
		# there, so it only edits regions that hold one (a multi-piece region's
		# picker is disabled — see _add_outfit_row). Merging instead would let a
		# player build a layered region they could never take apart again:
		# picking the shoes would keep the boots and picking "bare" would remove
		# both, with no way back to shoes alone. Layer-specific controls are #253.
		_recipe["equipment"][slot] = piece_name
	if _recipe["equipment"].is_empty():
		_recipe.erase("equipment")
	_restamp_version()


## What is currently worn on a region, as layer -> piece. Accepts both recipe
## forms: a bare piece name, or the list a region-with-layers uses.
func _worn_by_layer(slot: String) -> Dictionary:
	var out: Dictionary = {}
	var pieces: Dictionary = CharacterFactory.equipment_registry().get("pieces", {})
	var value: Variant = (_recipe.get("equipment", {}) as Dictionary).get(slot, null)
	if value == null:
		return out
	var names: Array = value if value is Array else [value]
	for entry: Variant in names:
		var piece_name := String(entry)
		if piece_name in pieces:
			out[String((pieces[piece_name] as Dictionary).get("layer", ""))] = piece_name
	return out


## The outermost piece worn on a region — what the character actually shows
## there, and so what the single picker displays.
func _outermost(slot: String) -> String:
	var worn := _worn_by_layer(slot)
	var shown := ""
	for layer: String in CharacterFactory.LAYERS:
		if layer in worn:
			shown = worn[layer]
	return shown


func _restamp_version() -> void:
	# The layered list form is version 4 and is checked FIRST: a recipe that
	# uses it must never be stamped 3, or the save would understate its own
	# shape and a version-3 client would read the list as one piece name and
	# refuse to load the character (#246).
	if _uses_layered_equipment():
		_recipe["version"] = CharacterFactory.LAYERED_EQUIPMENT_VERSION
	elif _recipe.has("skin"):
		_recipe["version"] = 3
	elif _recipe.has("equipment"):
		_recipe["version"] = 2
	else:
		_recipe["version"] = 1


## Does any region hold more than one piece? This panel never creates that
## state, but it can LOAD a recipe that has it, and saving must not downgrade
## the version out from under it.
func _uses_layered_equipment() -> bool:
	for slot: String in (_recipe.get("equipment", {}) as Dictionary):
		if _recipe["equipment"][slot] is Array:
			return true
	return false


func _on_preset(preset_name: String) -> void:
	var recipe = CharacterFactory.load_recipe(PRESET_DIR + preset_name + ".json")
	if recipe == null:
		return
	_recipe = recipe.duplicate(true)
	_recipe.erase("comment")
	_player.set_character(_recipe)
	_sync_sliders_from_recipe()


func _sync_sliders_from_recipe() -> void:
	_syncing = true
	var shapes: Dictionary = _recipe.get("shapes", {})
	for shape_name: String in _shape_sliders:
		(_shape_sliders[shape_name] as HSlider).value = shapes.get(shape_name, 0.0)
	for spec: Array in BONE_SLIDERS:
		(_bone_sliders[spec[0]] as HSlider).value = _recipe.get(spec[1], {}).get(spec[2], 1.0)
	for slot: String in _outfit_pickers:
		var picker: OptionButton = _outfit_pickers[slot]
		picker.select(0)
		# Show the OUTERMOST piece worn on the region — the one actually visible
		# on the character. Reading the raw value here would stringify a layered
		# region's list into something no picker entry matches, so the slot would
		# read "bare" while the character plainly wears something (#246).
		var shown := _outermost(slot)
		for i in picker.item_count:
			if picker.get_item_text(i) == shown:
				picker.select(i)
		# A region wearing more than one layer cannot be expressed by one picker,
		# so it is shown read-only rather than edited into a state the player
		# could not undo. Explicit limitation, never a silent rewrite (#253).
		picker.disabled = _worn_by_layer(slot).size() > 1
	if _skin_picker != null:
		_skin_picker.select(0)
		for i in _skin_picker.item_count:
			if _skin_picker.get_item_text(i) == String(_recipe.get("skin", "")):
				_skin_picker.select(i)
	_syncing = false


func _close(apply_changes: bool) -> void:
	if apply_changes:
		applied.emit(_recipe)
	elif not first_run:
		# Rebuild the body the recipe on disk describes.
		var saved = CharacterStore.load_saved()
		if saved is Dictionary:
			_player.set_character(saved)
	_player.control_enabled = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _camera != null:
		_camera.queue_free()
	if _light != null:
		_light.queue_free()
	closed.emit()
	queue_free()
