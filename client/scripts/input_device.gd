class_name InputDevice
extends Node
## Tracks which device the player is actually holding, so every on-screen
## binding names that device and only that device.
##
## Before this existed both surfaces showed both devices at once — the
## interaction prompt read `[E · pad X] …` and the hint bar carried a keyboard
## line and a pad line simultaneously. A player is only ever holding one of
## them, so half of that text was always about a device they were not touching,
## and every new verb made it worse.
##
## Two halves, deliberately split:
##  * `classify`, `binding_label`, `action_prompt` and `hint_line` are PURE
##    statics — a test drives them with no tree, no player and no window.
##  * the node half listens on `_input` and remembers the last device class,
##    announcing `device_changed` so the HUD can re-render.
##
## The labels are read back out of `InputMap`, never hand-listed here. A
## rebinding in `Player.ensure_input_actions()` therefore moves the on-screen
## text with it, and the two cannot drift apart.

## Emitted only when the class actually changes, so a HUD can rebuild on it
## without re-rendering on every keystroke.
signal device_changed(device: int)

## Device classes. Keyboard and mouse are one class on purpose: they are a
## single seating position, and a player reaching for the mouse has not
## stopped using the keyboard.
const KEYBOARD := 0
const PAD := 1
## An event that says nothing about what the player is holding.
const UNKNOWN := -1

## A resting stick still emits motion events. Anything under the input map's
## own deadzone presses no action, so it must not steal the prompts either.
const PAD_MOTION_MIN := Player.STICK_DEADZONE

## A settling or nudged mouse must not yank the surfaces back from a pad that
## is being actively used. Deliberately a few pixels rather than zero: real
## mice emit sub-pixel drift, and a captured mouse reports motion whenever the
## window regains focus.
const MOUSE_MOTION_MIN_PIXELS := 4.0

## Pad button and axis NAMES. This is naming, not binding — which button a verb
## sits on comes from `InputMap` alone; this only turns `JOY_BUTTON_X` into the
## letter printed on the pad. Buttons absent here render as nothing, which is
## visible as a missing hint rather than a wrong one.
const PAD_BUTTON_NAMES := {
	JOY_BUTTON_A: "A",
	JOY_BUTTON_B: "B",
	JOY_BUTTON_X: "X",
	JOY_BUTTON_Y: "Y",
	JOY_BUTTON_BACK: "Back",
	JOY_BUTTON_START: "Start",
	JOY_BUTTON_LEFT_SHOULDER: "LB",
	JOY_BUTTON_RIGHT_SHOULDER: "RB",
	JOY_BUTTON_LEFT_STICK: "L3",
	JOY_BUTTON_RIGHT_STICK: "R3",
}

const PAD_AXIS_NAMES := {
	JOY_AXIS_LEFT_X: "left stick",
	JOY_AXIS_LEFT_Y: "left stick",
	JOY_AXIS_RIGHT_X: "right stick",
	JOY_AXIS_RIGHT_Y: "right stick",
}

## The hint bar, in reading order. Each row names the verb and the actions that
## perform it; the label is derived from whichever of those actions the active
## device is bound to, de-duplicated (all four move actions collapse to one
## "left stick").
##
## `keyboard_only` is the one honest exception: looking around with a mouse is
## not an action at all — the camera reads `InputEventMouseMotion` directly —
## so there is no binding to derive and the word is stated. A row is skipped
## entirely when the active device yields no label, which is why the pad line
## is shorter rather than padded with blanks.
const HINTS: Array[Dictionary] = [
	{"verb": "move", "actions": ["move_forward", "move_left", "move_back", "move_right"]},
	{"verb": "look", "actions": ["look_left", "look_up"], "keyboard_only": "mouse"},
	{"verb": "sprint", "actions": ["sprint"]},
	{"verb": "jump", "actions": ["jump"]},
	{"verb": "interact", "actions": ["interact"]},
	{"verb": "reshape character", "actions": ["character_editor"]},
	{"verb": "dev log", "actions": ["toggle_devlog"]},
	{"verb": "release mouse", "actions": ["ui_cancel"]},
]

var _active := KEYBOARD


## Which class the player last used. Starts on keyboard: a fresh boot with no
## input yet should read as the device the desktop build is launched with.
func active() -> int:
	return _active


func _input(event: InputEvent) -> void:
	note(event)


## The tracking seam. Returns the class now active, so a test can drive device
## switching without a viewport or a real pad. Separate from `_input` because
## `_input` cannot be called meaningfully outside the tree.
func note(event: InputEvent) -> int:
	var seen := classify(event)
	if seen != UNKNOWN and seen != _active:
		_active = seen
		device_changed.emit(_active)
	return _active


## What class of device produced this event, or UNKNOWN when it says nothing.
## Pure — no state, no tree.
static func classify(event: InputEvent) -> int:
	if event is InputEventJoypadButton:
		return PAD
	var motion := event as InputEventJoypadMotion
	if motion != null:
		return PAD if absf(motion.axis_value) >= PAD_MOTION_MIN else UNKNOWN
	if event is InputEventKey or event is InputEventMouseButton:
		return KEYBOARD
	var mouse := event as InputEventMouseMotion
	if mouse != null:
		return KEYBOARD if mouse.relative.length() >= MOUSE_MOTION_MIN_PIXELS else UNKNOWN
	return UNKNOWN


## The on-screen name of whatever `action` is bound to on `device`, or "" when
## that device has no binding for it. Read straight out of `InputMap`, so it is
## the live map that is described and never a copy of it.
static func binding_label(action: StringName, device: int) -> String:
	if not InputMap.has_action(action):
		return ""
	var labels := PackedStringArray()
	for event: InputEvent in InputMap.action_get_events(action):
		var label := _event_label(event, device)
		if label != "" and not labels.has(label):
			labels.append(label)
	return " / ".join(labels)


## The interaction prompt: the active device's binding, then what it does.
static func action_prompt(action: StringName, device: int, text: String) -> String:
	var label := binding_label(action, device)
	return text if label == "" else "[%s] %s" % [label, text]


## The whole hint bar for one device, as a single line.
static func hint_line(device: int) -> String:
	var parts := PackedStringArray()
	for row: Dictionary in HINTS:
		var label := _row_label(row, device)
		if label != "":
			parts.append("%s %s" % [label, row["verb"]])
	return " · ".join(parts)


## One hint row's binding label, or "" when this device cannot perform it.
## Public so the drift guard can assert per-row derivation rather than only the
## joined string.
static func row_label(row: Dictionary, device: int) -> String:
	return _row_label(row, device)


static func _row_label(row: Dictionary, device: int) -> String:
	var labels := PackedStringArray()
	for action: String in row.get("actions", [] as Array):
		var label := binding_label(action, device)
		if label != "" and not labels.has(label):
			labels.append(label)
	if labels.is_empty() and device == KEYBOARD:
		return String(row.get("keyboard_only", ""))
	return " ".join(labels)


static func _event_label(event: InputEvent, device: int) -> String:
	if device == KEYBOARD:
		var key := event as InputEventKey
		return "" if key == null else OS.get_keycode_string(key.physical_keycode)
	var button := event as InputEventJoypadButton
	if button != null:
		return String(PAD_BUTTON_NAMES.get(button.button_index, ""))
	var motion := event as InputEventJoypadMotion
	if motion != null:
		return String(PAD_AXIS_NAMES.get(motion.axis, ""))
	return ""
