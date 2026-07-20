class_name UiTheme
extends RefCounted
## The game's authored UI look, built in code like every other surface in this
## client ("as code" — see AGENTS.md). Before this existed every control in the
## character creator rendered in Godot's stock grey, which is what made the
## first screen of the game read as a debug panel (#270).
##
## The palette is the world's own: ash for surfaces, ember for anything the
## player is meant to act on, bone for text. Nothing here is decoration for its
## own sake — the styling exists so a control's STATE is legible at a glance
## (what has focus, what is being dragged, what is disabled), which stock grey
## does not convey.

## Ash — the dark rock the panels are cut from, darkest first.
const ASH_DEEP := Color(0.055, 0.05, 0.045)
const ASH := Color(0.09, 0.08, 0.072)
const ASH_RAISED := Color(0.135, 0.12, 0.107)

## Ember — heat. Reserved for what the player acts on and what has focus.
const EMBER := Color(1.0, 0.62, 0.25)
const EMBER_DIM := Color(0.55, 0.35, 0.18)

## Bone — text and inert marks.
const BONE := Color(0.88, 0.84, 0.76)
const BONE_DIM := Color(0.88, 0.84, 0.76, 0.55)

const FONT_BODY := 12
const FONT_SECTION := 13
const FONT_TITLE := 18


## The creator's theme. Built fresh per call: a Theme is a Resource, and a
## shared mutable one would let any screen's later override leak into every
## other screen that had already applied it.
static func creator_theme() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = FONT_BODY

	_style_panel(theme)
	_style_buttons(theme)
	_style_sliders(theme)
	_style_labels(theme)
	_style_scrollbar(theme)
	return theme


static func _flat(bg: Color, border: Color, width: int, radius: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.border_color = border
	box.set_border_width_all(width)
	box.set_corner_radius_all(radius)
	return box


static func _style_panel(theme: Theme) -> void:
	var panel := _flat(Color(0.07, 0.06, 0.055, 0.93), EMBER_DIM, 1, 0)
	panel.set_content_margin_all(14)
	theme.set_stylebox("panel", "PanelContainer", panel)


## Buttons and dropdowns read as cut stone that warms when the player reaches
## for them. Focus gets its OWN ember border rather than sharing hover's, so a
## pad player can always see where they are — the creator is reachable with no
## pointer at all, and stock grey gave that state no mark whatsoever.
static func _style_buttons(theme: Theme) -> void:
	for control in ["Button", "OptionButton"]:
		theme.set_stylebox("normal", control, _button_box(ASH_RAISED, EMBER_DIM, 1))
		theme.set_stylebox("hover", control, _button_box(ASH_RAISED.lightened(0.12), EMBER, 1))
		theme.set_stylebox("pressed", control, _button_box(ASH, EMBER, 1))
		theme.set_stylebox("focus", control, _button_box(Color(0, 0, 0, 0), EMBER, 2))
		theme.set_stylebox("disabled", control, _button_box(ASH_DEEP, Color(0.3, 0.28, 0.25), 1))
		theme.set_color("font_color", control, BONE)
		theme.set_color("font_hover_color", control, Color(1.0, 0.95, 0.86))
		theme.set_color("font_pressed_color", control, EMBER)
		theme.set_color("font_disabled_color", control, BONE_DIM)
		theme.set_font_size("font_size", control, FONT_BODY)


static func _button_box(bg: Color, border: Color, width: int) -> StyleBoxFlat:
	var box := _flat(bg, border, width, 2)
	box.content_margin_left = 10
	box.content_margin_right = 10
	box.content_margin_top = 4
	box.content_margin_bottom = 4
	return box


## A slider's track is a groove cut into the panel; the filled part glows ember
## so the player can read every value in the column at a glance instead of
## hunting for grabber positions against identical grey bars.
static func _style_sliders(theme: Theme) -> void:
	var track := _flat(ASH_DEEP, Color(0, 0, 0, 0), 0, 2)
	track.content_margin_top = 3
	track.content_margin_bottom = 3
	theme.set_stylebox("slider", "HSlider", track)

	var filled := _flat(EMBER_DIM, Color(0, 0, 0, 0), 0, 2)
	filled.content_margin_top = 3
	filled.content_margin_bottom = 3
	theme.set_stylebox("grabber_area", "HSlider", filled)
	theme.set_stylebox("grabber_area_highlight", "HSlider", _flat(EMBER, Color(0, 0, 0, 0), 0, 2))

	theme.set_icon("grabber", "HSlider", _grabber_icon(EMBER))
	theme.set_icon("grabber_highlight", "HSlider", _grabber_icon(Color(1.0, 0.82, 0.55)))
	theme.set_icon("grabber_disabled", "HSlider", _grabber_icon(Color(0.4, 0.37, 0.33)))


## The grabber is drawn rather than shipped as a PNG so the whole look stays in
## code with the rest of the client, and so it can never drift from the palette
## constants above.
static func _grabber_icon(color: Color) -> ImageTexture:
	var size := 12
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	var centre := (size - 1) * 0.5
	for y in size:
		for x in size:
			var distance := Vector2(x - centre, y - centre).length()
			if distance <= centre - 1.5:
				image.set_pixel(x, y, color)
			elif distance <= centre - 0.5:
				# One soft edge ring — a hard-edged circle at this size reads as
				# a square once the panel scales.
				image.set_pixel(x, y, Color(color.r, color.g, color.b, 0.45))
	return ImageTexture.create_from_image(image)


static func _style_labels(theme: Theme) -> void:
	theme.set_color("font_color", "Label", BONE)
	theme.set_font_size("font_size", "Label", FONT_BODY)


## The stock scrollbar is a bright grey slab that competes with the controls it
## scrolls. This one recedes into the panel until it is grabbed.
static func _style_scrollbar(theme: Theme) -> void:
	theme.set_stylebox("scroll", "VScrollBar", _flat(ASH_DEEP, Color(0, 0, 0, 0), 0, 3))
	theme.set_stylebox("grabber", "VScrollBar", _flat(ASH_RAISED, Color(0, 0, 0, 0), 0, 3))
	theme.set_stylebox("grabber_highlight", "VScrollBar", _flat(EMBER_DIM, Color(0, 0, 0, 0), 0, 3))
	theme.set_stylebox("grabber_pressed", "VScrollBar", _flat(EMBER, Color(0, 0, 0, 0), 0, 3))
