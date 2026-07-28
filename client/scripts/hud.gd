class_name Hud
extends CanvasLayer
## Minimal diegetic-adjacent HUD: build identity, control hints, a toast line,
## and the F1 dev log — the panel the owner opens to watch development
## progress by playing.

## Opt-in: contextual control hints (#271). Default-off, so the shipped build is
## unchanged until this is proven by eye.
##
## OFF — the bar lists every verb along the bottom of every frame, forever.
## ON  — the bar reveals, dwells, and fades, giving the composition back to the
##       world; a device change reveals it again (the bindings just changed
##       under the player), and a permanent one-token affordance names the key
##       that brings it back for good.
const CONTEXTUAL_HINTS_ENV := "WAR_CONTEXTUAL_HINTS"

## How long the full set stays up before fading. Long enough to read eight short
## verbs without hurrying; tests shorten it through `WAR_HINT_DWELL_SECONDS`
## rather than simulating the timing, so the real tween is what gets exercised.
const HINT_DWELL_ENV := "WAR_HINT_DWELL_SECONDS"
const HINT_DWELL_SECONDS := 6.0

## Slow enough to read as the HUD stepping back rather than a draw glitch.
const HINT_FADE_SECONDS := 0.8

## The affordance's box, as offsets from the bottom-right of the window. It sits
## a row BELOW the hint bar's 46px so a pinned bar and it never overlap.
const AFFORDANCE_SIDE_MARGIN := 18.0
const AFFORDANCE_BASELINE := 26.0
const AFFORDANCE_HEIGHT := 20.0

## Clear space either side of a toast, in pixels from the viewport edge. At the
## shipped 1600-wide viewport this leaves an 1100px column — the longest message
## this build can produce is a combined boot notice measuring 1249px, so it wraps
## to two comfortable lines instead of reaching for the edges.
const TOAST_SIDE_MARGIN := 250.0

## How tall the toast's box is. Only a bound for wrapped text: a toast is one or
## two lines, and this leaves room for more without the label ever growing into
## the rest of the HUD.
const TOAST_HEIGHT := 120.0

var _toast: Label
var _prompt: Label
var _hints: Label
## Only built in contextual mode: with the full set permanently on screen there
## is nothing for an affordance to reveal.
var _hint_affordance: Label
var _devlog_panel: PanelContainer
var _devlog_label: RichTextLabel
var _toast_tween: Tween
var _hints_tween: Tween
var _device: InputDevice
var _contextual_hints := false
## Set by the player through `toggle_hints`: the bar stays up until they say
## otherwise, so anyone who wants the old permanent bar can simply have it.
var _hints_pinned := false

func _ready() -> void:
	# The hint bar is derived from the live input map, so make sure the map
	# exists before reading it: HUD and Player are siblings and this must not
	# depend on which of them reaches _ready first. The call is idempotent.
	Player.ensure_input_actions()
	_contextual_hints = OS.get_environment(CONTEXTUAL_HINTS_ENV) == "1"
	_device = InputDevice.new()
	_device.name = "InputDevice"
	_device.device_changed.connect(_on_device_changed)
	add_child(_device)

	_build_title()
	_build_hints()
	_build_toast()
	_build_prompt()
	_build_devlog()


## Which device class the player last used. The InteractionController reads it
## to format its prompt for the same device the hint bar is showing.
func active_device() -> int:
	return _device.active() if _device != null else InputDevice.KEYBOARD


func _on_device_changed(device: int) -> void:
	# The interaction prompt re-renders itself every frame from the controller,
	# so only the static hint bar needs redrawing here.
	if _hints != null:
		_hints.text = InputDevice.hint_line(device)
	if _hint_affordance != null:
		_hint_affordance.text = _affordance_text(device)
	# Every binding on screen just changed under the player's hands, which is
	# precisely when the set is worth showing again (#194 through the fade).
	reveal_hints()

func _unhandled_input(event: InputEvent) -> void:
	# Gated on the flag, not just on `toggle_hints()`'s own guard: consuming the
	# event in a build that then does nothing with it would be a change to the
	# default path, and the whole point of default-off is that there is none.
	if _contextual_hints and event.is_action_pressed("toggle_hints"):
		toggle_hints()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("toggle_devlog"):
		if _devlog_label.text.is_empty():
			_devlog_label.text = _render_devlog()
		_devlog_panel.visible = not _devlog_panel.visible
		get_viewport().set_input_as_handled()

func toast(message: String) -> void:
	_toast.text = message
	_toast.modulate.a = 1.0
	if _toast_tween and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(2.8)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 1.4)

func _build_title() -> void:
	var title := Label.new()
	title.text = "WORLD AT RUIN"
	title.add_theme_font_size_override("font_size", UiTheme.FONT_TITLE)
	title.add_theme_color_override("font_color", UiTheme.BONE)
	title.position = Vector2(18, 14)
	add_child(title)

	var build := Label.new()
	build.text = "pre-alpha v%s · %s" % [DevLog.VERSION, DevLog.CODENAME]
	build.add_theme_font_size_override("font_size", UiTheme.FONT_BODY)
	build.add_theme_color_override("font_color", UiTheme.BONE_DIM)
	build.position = Vector2(18, 38)
	add_child(build)

func _build_hints() -> void:
	_hints = Label.new()
	_hints.text = InputDevice.hint_line(active_device())
	_hints.add_theme_font_size_override("font_size", UiTheme.FONT_BODY)
	_hints.add_theme_color_override("font_color", UiTheme.BONE_DIM)
	_hints.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_hints.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hints.position.y -= 46
	add_child(_hints)

	if not _contextual_hints:
		return
	_build_hint_affordance()
	reveal_hints()


## The one line that stays: which key brings the full set back. Deliberately
## NOT a row in `InputDevice.HINTS` — that list is what this key reveals, so
## listing it there would hide its own discovery behind itself.
func _build_hint_affordance() -> void:
	_hint_affordance = Label.new()
	_hint_affordance.text = _affordance_text(active_device())
	_hint_affordance.add_theme_font_size_override("font_size", UiTheme.FONT_BODY)
	_hint_affordance.add_theme_color_override("font_color", UiTheme.BONE_DIM)
	_hint_affordance.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_hint_affordance.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	# Offsets from the window edges, never `position` — the same reasoning the
	# toast records. Assigning `position` to an anchored Control re-derives the
	# offsets from whatever size the rect is holding at that instant, so the
	# right edge lands wherever layout left it: measured at 1690px inside a
	# 1600px window, which pushed this right-aligned text clean off the screen
	# while `visible`, `modulate` and `text` all still read perfectly correct.
	_hint_affordance.offset_left = 0.0
	_hint_affordance.offset_right = -AFFORDANCE_SIDE_MARGIN
	# A row below the hint bar, so a pinned bar and this never collide.
	_hint_affordance.offset_top = -AFFORDANCE_BASELINE
	_hint_affordance.offset_bottom = -AFFORDANCE_BASELINE + AFFORDANCE_HEIGHT
	add_child(_hint_affordance)


## The affordance's wording, derived from the live map so a rebinding moves it.
## Empty when this device has no binding for the toggle — a missing hint rather
## than a wrong one, the same rule `InputDevice._row_label` follows.
func _affordance_text(device: int) -> String:
	var label := InputDevice.binding_label("toggle_hints", device, true)
	return "" if label == "" else "[%s] controls" % label


## Show the full set, then let it fade — unless the player has pinned it, or
## the build is on the permanent bar, in which case this only guarantees the
## bar is opaque.
func reveal_hints() -> void:
	if _hints == null:
		return
	if _hints_tween and _hints_tween.is_valid():
		_hints_tween.kill()
	_hints.modulate.a = 1.0
	if not _contextual_hints or _hints_pinned:
		return
	_hints_tween = create_tween()
	_hints_tween.tween_interval(_hint_dwell_seconds())
	_hints_tween.tween_property(_hints, "modulate:a", 0.0, HINT_FADE_SECONDS)


## Pin the full set up, or put it away. Inert on the permanent bar: there the
## set is already the frame's baseline and hiding it would be a change the
## player never opted into.
func toggle_hints() -> void:
	if not _contextual_hints or _hints == null:
		return
	_hints_pinned = not _hints_pinned
	if _hints_tween and _hints_tween.is_valid():
		_hints_tween.kill()
	_hints.modulate.a = 1.0 if _hints_pinned else 0.0


func _hint_dwell_seconds() -> float:
	var raw := OS.get_environment(HINT_DWELL_ENV)
	return float(raw) if raw.is_valid_float() else HINT_DWELL_SECONDS


## Read-only inspection of the hint bar, for the regression test.
func hint_text() -> String:
	return _hints.text if _hints != null else ""


## Whether the player can actually read the control set right now. Keyed on the
## rendered alpha rather than on `visible`, because the bar is faded out rather
## than hidden — a `visible`-only check would report a fully transparent bar as
## on screen.
func hints_visible() -> bool:
	return _hints != null and _hints.modulate.a > 0.01

func _build_toast() -> void:
	_toast = Label.new()
	_toast.text = ""
	_toast.modulate.a = 0.0
	_toast.add_theme_font_size_override("font_size", UiTheme.FONT_TOAST)
	_toast.add_theme_color_override("font_color", UiTheme.EMBER)
	# Span the width and centre the TEXT inside it, rather than sizing a box to the
	# text and centring the box. A point-anchored Label grows from its anchor by
	# whatever its content demands, so a long line runs off the edges and the ends
	# become unreadable — and a toast is the only channel some messages have (a
	# boot notice that progression restarted, a seeded line from a person).
	#
	# The margins are offsets from the viewport edges, so the column is centred by
	# construction at any window size and narrows with the window instead of being
	# clipped by it. A fixed width on a point anchor does NOT survive that: the
	# rectangle's placement then depends on grow direction and on when the size is
	# assigned relative to entering the tree, which is how it ends up off-centre.
	_toast.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast.offset_left = TOAST_SIDE_MARGIN
	_toast.offset_right = -TOAST_SIDE_MARGIN
	_toast.offset_top = 120
	_toast.offset_bottom = 120 + TOAST_HEIGHT
	add_child(_toast)

## The interaction prompt: what pressing E would do right now, shown just above
## the control hints while something is in reach. The InteractionController
## drives it via show_prompt/hide_prompt.
func _build_prompt() -> void:
	_prompt = Label.new()
	_prompt.text = ""
	_prompt.visible = false
	_prompt.add_theme_font_size_override("font_size", UiTheme.FONT_PROMPT)
	_prompt.add_theme_color_override("font_color", UiTheme.EMBER)
	_prompt.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.position.y -= 64
	add_child(_prompt)

func show_prompt(text: String) -> void:
	_prompt.text = text
	_prompt.visible = true

func hide_prompt() -> void:
	_prompt.text = ""
	_prompt.visible = false

## Read-only inspection of the interaction prompt (used by the regression test
## to confirm the on-screen prompt actually appears).
func prompt_text() -> String:
	return _prompt.text if _prompt != null else ""

func prompt_shown() -> bool:
	return _prompt != null and _prompt.visible

func _build_devlog() -> void:
	_devlog_panel = PanelContainer.new()
	_devlog_panel.visible = false
	_devlog_panel.set_anchors_preset(Control.PRESET_CENTER)
	_devlog_panel.custom_minimum_size = Vector2(640, 480)
	# Grow out from the centre anchor in both directions, so the panel stays
	# centred whatever size it takes.
	_devlog_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_devlog_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_devlog_panel.add_theme_stylebox_override("panel", UiTheme.panel_box(18))
	add_child(_devlog_panel)

	_devlog_label = RichTextLabel.new()
	_devlog_label.bbcode_enabled = true
	_devlog_label.scroll_active = true
	# Left empty until the log is first opened. The panel starts hidden and most
	# launches never show it, so composing every entry here spent launch time
	# laying out text nobody is looking at.
	_devlog_panel.add_child(_devlog_label)

func _render_devlog() -> String:
	var ember := UiTheme.EMBER.to_html(false)
	var bone := UiTheme.BONE.to_html(false)
	var out := "[color=#%s][b]DEV LOG — watch the world grow[/b][/color]\n" % ember
	out += "[color=#%s]Every player-visible change lands here, newest first. F1 closes.[/color]\n\n" % UiTheme.BONE_DIM.to_html(false)
	for entry: Dictionary in DevLog.ENTRIES:
		out += "[color=#%s][b]v%s — %s[/b]  ·  %s[/color]\n" % [ember, entry["version"], entry["title"], entry["date"]]
		for note: String in entry["notes"]:
			out += "[color=#%s]  • %s[/color]\n" % [bone, note]
		out += "\n"
	return out
