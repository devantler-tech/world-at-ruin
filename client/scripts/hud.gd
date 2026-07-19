class_name Hud
extends CanvasLayer
## Minimal diegetic-adjacent HUD: build identity, control hints, a toast line,
## and the F1 dev log — the panel the owner opens to watch development
## progress by playing.

const COL_BONE := Color(0.88, 0.84, 0.76)
const COL_DIM := Color(0.88, 0.84, 0.76, 0.55)
const COL_EMBER := Color(1.0, 0.62, 0.25)

var _toast: Label
var _prompt: Label
var _hints: Label
var _devlog_panel: PanelContainer
var _toast_tween: Tween
var _device: InputDevice

func _ready() -> void:
	# The hint bar is derived from the live input map, so make sure the map
	# exists before reading it: HUD and Player are siblings and this must not
	# depend on which of them reaches _ready first. The call is idempotent.
	Player.ensure_input_actions()
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

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_devlog"):
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
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", COL_BONE)
	title.position = Vector2(18, 14)
	add_child(title)

	var build := Label.new()
	build.text = "pre-alpha v%s · %s" % [DevLog.VERSION, DevLog.CODENAME]
	build.add_theme_font_size_override("font_size", 12)
	build.add_theme_color_override("font_color", COL_DIM)
	build.position = Vector2(18, 38)
	add_child(build)

func _build_hints() -> void:
	_hints = Label.new()
	_hints.text = InputDevice.hint_line(active_device())
	_hints.add_theme_font_size_override("font_size", 12)
	_hints.add_theme_color_override("font_color", COL_DIM)
	_hints.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_hints.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hints.position.y -= 46
	add_child(_hints)


## Read-only inspection of the hint bar, for the regression test.
func hint_text() -> String:
	return _hints.text if _hints != null else ""

func _build_toast() -> void:
	_toast = Label.new()
	_toast.text = ""
	_toast.modulate.a = 0.0
	_toast.add_theme_font_size_override("font_size", 16)
	_toast.add_theme_color_override("font_color", COL_EMBER)
	_toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.position.y = 120
	add_child(_toast)

## The interaction prompt: what pressing E would do right now, shown just above
## the control hints while something is in reach. The InteractionController
## drives it via show_prompt/hide_prompt.
func _build_prompt() -> void:
	_prompt = Label.new()
	_prompt.text = ""
	_prompt.visible = false
	_prompt.add_theme_font_size_override("font_size", 15)
	_prompt.add_theme_color_override("font_color", COL_EMBER)
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
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.06, 0.055, 0.94)
	style.border_color = Color(0.55, 0.35, 0.18)
	style.set_border_width_all(1)
	style.set_content_margin_all(18)
	_devlog_panel.add_theme_stylebox_override("panel", style)
	add_child(_devlog_panel)

	var log := RichTextLabel.new()
	log.bbcode_enabled = true
	log.scroll_active = true
	log.text = _render_devlog()
	_devlog_panel.add_child(log)

func _render_devlog() -> String:
	var ember := COL_EMBER.to_html(false)
	var bone := COL_BONE.to_html(false)
	var out := "[color=#%s][b]DEV LOG — watch the world grow[/b][/color]\n" % ember
	out += "[color=#%s]Every player-visible change lands here, newest first. F1 closes.[/color]\n\n" % COL_DIM.to_html(false)
	for entry: Dictionary in DevLog.ENTRIES:
		out += "[color=#%s][b]v%s — %s[/b]  ·  %s[/color]\n" % [ember, entry["version"], entry["title"], entry["date"]]
		for note: String in entry["notes"]:
			out += "[color=#%s]  • %s[/color]\n" % [bone, note]
		out += "\n"
	return out
