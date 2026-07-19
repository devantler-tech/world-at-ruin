extends Node
## Regression test for device-aware prompts (issue #194, Part of #8).
##
## The product law under test: the player is only ever told about the device
## they are actually holding. Before this, both surfaces showed both devices at
## once, so half the text was always irrelevant.
##
## The teeth, in order of how much they would catch:
##  1. `classify` is pure and refuses to flip on noise — a resting stick and a
##     settling mouse must not steal the surfaces from the device in use.
##  2. Tracking flips on the first event of the other class and announces the
##     change exactly once per real switch.
##  3. Labels are DERIVED from the live `InputMap`, so a rebinding in
##     `Player.ensure_input_actions()` moves the text with it. The drift guard
##     asserts every hint row still resolves — a renamed action fails loudly
##     here rather than silently rendering a blank hint bar in the shipped game.
##  4. EXCLUSIVITY: the keyboard surfaces contain no pad token and the pad
##     surfaces contain no keyboard token. This is the acceptance criterion
##     itself, and it is what a "show both" regression would trip.
##  5. End to end on the real nodes: a synthetic pad event through
##     `Input.parse_input_event()` re-renders the live HUD hint bar, and the
##     real InteractionController writes a pad-only prompt for a real
##     Interactable — then a key event swaps both back.
##
## Safe headless: no main.tscn boot and no save IO — HUD, Player and
## Interactable are instantiated directly.
##
## Run: godot --headless --path client res://tests/input_device_prompts_test.tscn

## Independent literals on purpose. Asserting against InputDevice's own
## constants would let the test and the code share one wrong value — the point
## is that a stick at rest is well under any sane deadzone.
const RESTING_STICK := 0.05
const FULL_DEFLECTION := 1.0
const TINY_MOUSE_NUDGE := 1.0
const REAL_MOUSE_MOVE := 40.0

## Tokens that may only ever appear on one device's surfaces. Written out
## literally rather than read from InputDevice so a bug that empties the name
## tables cannot also empty this list.
const PAD_ONLY_TOKENS := ["left stick", "right stick", "L3", "Back"]
const KEYBOARD_ONLY_TOKENS := ["Shift", "Space", "Escape", "mouse"]

var _failed := false
var _device_changes := 0


func _ready() -> void:
	Player.ensure_input_actions()

	_test_classify()
	if _failed:
		return
	_test_tracking()
	if _failed:
		return
	_test_labels_derived()
	if _failed:
		return
	_test_hint_rows_resolve()
	if _failed:
		return
	_test_exclusivity()
	if _failed:
		return
	_test_live_surfaces()
	if _failed:
		return

	# Print what a player actually reads, so a reviewer can judge the wording
	# from the CI log without booting the game.
	print("  keyboard: %s" % InputDevice.hint_line(InputDevice.KEYBOARD))
	print("  pad:      %s" % InputDevice.hint_line(InputDevice.PAD))
	print("TEST PASS — prompts follow the active device: derived from the live input map, exclusive per device, and swapped end to end on the real HUD and InteractionController")
	get_tree().quit(0)


# --- 1. classification is pure and noise-resistant ---------------------------

func _test_classify() -> void:
	var key := InputEventKey.new()
	key.physical_keycode = KEY_E
	_check(InputDevice.classify(key) == InputDevice.KEYBOARD, "a key press reads as keyboard")

	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	_check(InputDevice.classify(click) == InputDevice.KEYBOARD,
		"a mouse click reads as keyboard (one seating position)")

	var pad_button := InputEventJoypadButton.new()
	pad_button.button_index = JOY_BUTTON_X
	_check(InputDevice.classify(pad_button) == InputDevice.PAD, "a pad button reads as pad")

	var stick := InputEventJoypadMotion.new()
	stick.axis = JOY_AXIS_LEFT_X
	stick.axis_value = FULL_DEFLECTION
	_check(InputDevice.classify(stick) == InputDevice.PAD, "a deflected stick reads as pad")

	# The two noise cases. A pad left on the desk and a mouse settling must both
	# say nothing, or the surfaces would flicker between devices unprompted.
	var resting := InputEventJoypadMotion.new()
	resting.axis = JOY_AXIS_LEFT_X
	resting.axis_value = RESTING_STICK
	_check(InputDevice.classify(resting) == InputDevice.UNKNOWN,
		"a stick at rest says nothing about what the player is holding")

	var nudge := InputEventMouseMotion.new()
	nudge.relative = Vector2(TINY_MOUSE_NUDGE, 0.0)
	_check(InputDevice.classify(nudge) == InputDevice.UNKNOWN, "mouse drift says nothing")

	var move := InputEventMouseMotion.new()
	move.relative = Vector2(REAL_MOUSE_MOVE, 0.0)
	_check(InputDevice.classify(move) == InputDevice.KEYBOARD,
		"a real mouse movement reads as keyboard")


# --- 2. tracking flips once per real switch ---------------------------------

func _test_tracking() -> void:
	var tracker := InputDevice.new()
	tracker.device_changed.connect(_on_device_changed)
	_device_changes = 0

	_check(tracker.active() == InputDevice.KEYBOARD, "a fresh boot reads as keyboard")

	var pad_button := InputEventJoypadButton.new()
	pad_button.button_index = JOY_BUTTON_X
	_check(tracker.note(pad_button) == InputDevice.PAD, "the first pad event flips to pad")
	_check(_device_changes == 1, "the flip is announced once")

	# A second pad event is not a switch and must not re-announce, or the HUD
	# would rebuild its hint bar on every button press.
	tracker.note(pad_button)
	_check(_device_changes == 1, "staying on the same device announces nothing")

	# Noise must not flip it back even though the player is on a pad.
	var nudge := InputEventMouseMotion.new()
	nudge.relative = Vector2(TINY_MOUSE_NUDGE, 0.0)
	_check(tracker.note(nudge) == InputDevice.PAD, "mouse drift does not steal the pad's surfaces")
	_check(_device_changes == 1, "noise announces nothing")

	var key := InputEventKey.new()
	key.physical_keycode = KEY_E
	_check(tracker.note(key) == InputDevice.KEYBOARD, "a key press flips back to keyboard")
	_check(_device_changes == 2, "the switch back is announced")

	tracker.free()


func _on_device_changed(_device: int) -> void:
	_device_changes += 1


# --- 3. labels come out of the live input map -------------------------------

func _test_labels_derived() -> void:
	# `interact` is bound to E and pad X in Player.ensure_input_actions. These
	# assertions read the map, so a rebinding there moves them.
	_check(InputDevice.binding_label("interact", InputDevice.KEYBOARD) == "E",
		"the keyboard interact label is read from the map")
	_check(InputDevice.binding_label("interact", InputDevice.PAD) == "X",
		"the pad interact label is read from the map")

	# The four move actions all sit on the left stick: the pad label must
	# collapse to one name rather than repeating it four times.
	var move_row := {"verb": "move",
		"actions": ["move_forward", "move_left", "move_back", "move_right"]}
	_check(InputDevice.row_label(move_row, InputDevice.PAD) == "left stick",
		"four actions on one stick render as one label")

	# Readability, and the reason the composite rule exists: rendering every
	# alternate for a four-action verb produces "W / Up A / Left S / Down D /
	# Right", which is the noise this change is meant to remove. A composite
	# verb shows primaries only.
	_check(InputDevice.row_label(move_row, InputDevice.KEYBOARD) == "W A S D",
		"a composite verb shows one key per direction (was '%s')"
			% InputDevice.row_label(move_row, InputDevice.KEYBOARD))

	# …but a single-action verb keeps its alternates, and this one has to:
	# F1 is fn-gated on Mac keyboards, so dropping L would strand the dev log
	# behind a chord the hint bar never mentions.
	var devlog_row := {"verb": "dev log", "actions": ["toggle_devlog"]}
	_check(InputDevice.row_label(devlog_row, InputDevice.KEYBOARD).contains("L"),
		"the dev log keeps its second binding (F1 is fn-gated on Mac)")

	# An action nothing is bound to on this device yields nothing, not a blank
	# bracket — that is what lets the pad hint line be genuinely shorter.
	_check(InputDevice.binding_label("look_left", InputDevice.KEYBOARD) == "",
		"an unbound device yields no label")
	_check(InputDevice.binding_label("no_such_action", InputDevice.PAD) == "",
		"an action that does not exist yields no label")

	# The prompt helper wraps the derived label and never invents one.
	_check(InputDevice.action_prompt("interact", InputDevice.PAD, "Attune") == "[X] Attune",
		"the prompt helper uses the active device's binding")
	_check(InputDevice.action_prompt("no_such_action", InputDevice.KEYBOARD, "Attune") == "Attune",
		"an unbindable prompt degrades to the bare verb, never an empty bracket")


# --- 4. the drift guard: every hint row still resolves -----------------------

func _test_hint_rows_resolve() -> void:
	# THE point of this test. Every row must render on at least one device. A
	# renamed or deleted action in Player.ensure_input_actions silently empties
	# its row — the shipped game would just stop mentioning that verb — so the
	# failure is caught here instead of by a player.
	for row: Dictionary in InputDevice.HINTS:
		var keyboard := InputDevice.row_label(row, InputDevice.KEYBOARD)
		var pad := InputDevice.row_label(row, InputDevice.PAD)
		_check(keyboard != "" or pad != "",
			"hint row '%s' resolves on at least one device (drift with the input map)" % row["verb"])
		if _failed:
			return

		# Every action a row names must actually exist, so a typo in the table
		# fails here rather than quietly narrowing the hint bar.
		for action: String in row.get("actions", [] as Array):
			_check(InputMap.has_action(action),
				"hint row '%s' names a real action '%s'" % [row["verb"], action])
			if _failed:
				return

	# Non-vacuity floor: the guard above is only meaningful if the rows are
	# actually there and actually resolving.
	_check(InputDevice.HINTS.size() >= 6, "the hint table is populated")
	_check(InputDevice.hint_line(InputDevice.KEYBOARD).length() > 40, "the keyboard hint bar renders")
	_check(InputDevice.hint_line(InputDevice.PAD).length() > 20, "the pad hint bar renders")


# --- 5. exclusivity: the acceptance criterion itself ------------------------

func _test_exclusivity() -> void:
	var keyboard_line := InputDevice.hint_line(InputDevice.KEYBOARD)
	var pad_line := InputDevice.hint_line(InputDevice.PAD)

	for token: String in PAD_ONLY_TOKENS:
		_check(not keyboard_line.contains(token),
			"the keyboard hint bar never mentions '%s'" % token)
	for token: String in KEYBOARD_ONLY_TOKENS:
		_check(not pad_line.contains(token), "the pad hint bar never mentions '%s'" % token)
	if _failed:
		return

	# Each device's line must carry its OWN tokens, or "contains nothing of the
	# other device" would pass on an empty string.
	_check(keyboard_line.contains("E interact"), "the keyboard hint bar carries keyboard bindings")
	_check(pad_line.contains("X interact"), "the pad hint bar carries pad bindings")
	_check(pad_line.contains("left stick move"), "the pad hint bar names the stick")

	# The prompt surface, both directions.
	_check(not InputDevice.action_prompt("interact", InputDevice.KEYBOARD, "Attune").contains("X"),
		"the keyboard prompt never shows the pad binding")
	_check(not InputDevice.action_prompt("interact", InputDevice.PAD, "Attune").contains("E"),
		"the pad prompt never shows the keyboard binding")


# --- 6. end to end on the real HUD and controller ---------------------------

func _test_live_surfaces() -> void:
	var hud := Hud.new()
	add_child(hud)

	var player := Player.new()
	add_child(player)
	player.global_position = Vector3.ZERO

	var shrine := Interactable.new()
	shrine.prompt = "Attune"
	shrine.interact_range = 5.0
	shrine.facing_min = -1.0
	add_child(shrine)
	shrine.global_position = player.global_position + player.aim_forward() * 2.0

	var interaction := InteractionController.new()
	interaction.player = player
	interaction.hud = hud
	add_child(interaction)

	# Keyboard is the boot state: both surfaces speak keyboard only.
	interaction._process(0.0)
	_check(hud.active_device() == InputDevice.KEYBOARD, "the HUD boots on keyboard")
	_check(hud.prompt_text() == "[E] Attune",
		"the live prompt is keyboard-only (was '%s')" % hud.prompt_text())
	_check(hud.hint_text().contains("E interact"), "the live hint bar is keyboard-only")
	_check(not hud.hint_text().contains("left stick"), "the live hint bar shows no pad bindings")
	if _failed:
		return

	# Pick up a pad. This goes through the real _input path, not the test seam.
	var pad_button := InputEventJoypadButton.new()
	pad_button.button_index = JOY_BUTTON_X
	pad_button.pressed = true
	Input.parse_input_event(pad_button)
	Input.flush_buffered_events()

	_check(hud.active_device() == InputDevice.PAD, "a real pad event reaches the HUD's tracker")
	if _failed:
		return
	interaction._process(0.0)
	_check(hud.prompt_text() == "[X] Attune",
		"the live prompt swapped to the pad (was '%s')" % hud.prompt_text())
	_check(hud.hint_text().contains("X interact"), "the live hint bar swapped to the pad")
	_check(not hud.hint_text().contains("E interact"),
		"the live hint bar dropped the keyboard bindings")
	if _failed:
		return

	# Put it down again — the swap must work in both directions, within one
	# interaction, which is the issue's success signal.
	var key := InputEventKey.new()
	key.physical_keycode = KEY_E
	key.pressed = true
	Input.parse_input_event(key)
	Input.flush_buffered_events()

	interaction._process(0.0)
	_check(hud.active_device() == InputDevice.KEYBOARD, "a key press switches back")
	_check(hud.prompt_text() == "[E] Attune", "the live prompt swapped back to the keyboard")
	_check(hud.hint_text().contains("E interact"), "the live hint bar swapped back")


# --- helpers ----------------------------------------------------------------

func _check(condition: bool, what: String) -> void:
	if _failed:
		return
	if not condition:
		_failed = true
		print("TEST FAIL — %s" % what)
		get_tree().quit(1)
