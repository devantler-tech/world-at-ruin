extends Node
## Regression test for controller support (issue #181, Part of #8).
##
## Phase 1's exit gate is played "on a controller", so the input map must make
## the whole existing slice reachable from a gamepad: left stick walks (analog
## magnitude respected), right stick pans/tilts the camera inside the same
## pitch clamps the mouse honours, and every player-facing verb sits on a pad
## button. Keyboard bindings must survive unchanged.
##
## The teeth: bindings are asserted structurally AND the outcome is exercised —
## synthetic joypad events go through Input.parse_input_event(), and the
## resulting action vectors / camera rotation are asserted exactly (the camera
## path is driven by calling Player._process with fixed deltas, so no frame
## timing is involved).
##
## Safe headless: instantiates Player directly (no main.tscn boot, no save IO).
##
## Run: godot --headless --path client res://tests/controller_input_test.tscn

## Independent literal on purpose: asserting against Player.STICK_DEADZONE
## would let the test and the code share one wrong value. Sticks need a
## deadzone well under the 0.5 digital-press threshold or analog walking
## degrades into a switch.
const MAX_STICK_DEADZONE := 0.25
const EPS := 0.001

var _failed := false


func _ready() -> void:
	Player.ensure_input_actions()

	_check_bindings()
	if _failed:
		return
	_check_movement_actions()
	if _failed:
		return
	_check_camera()
	if _failed:
		return
	_check_keyboard_regression()
	if _failed:
		return
	_check_creator_focus()
	if _failed:
		return

	print("TEST PASS — controller support: sticks move and look (analog, deadzoned, pitch-clamped), verbs on pad buttons, creator pad-navigable, keyboard untouched")
	get_tree().quit(0)


# --- structural: the bindings exist ----------------------------------------

func _check_bindings() -> void:
	# Direction-actions carry the expected stick axis with the expected sign.
	var axes := {
		"move_left": [JOY_AXIS_LEFT_X, -1.0],
		"move_right": [JOY_AXIS_LEFT_X, 1.0],
		"move_forward": [JOY_AXIS_LEFT_Y, -1.0],
		"move_back": [JOY_AXIS_LEFT_Y, 1.0],
		"look_left": [JOY_AXIS_RIGHT_X, -1.0],
		"look_right": [JOY_AXIS_RIGHT_X, 1.0],
		"look_up": [JOY_AXIS_RIGHT_Y, -1.0],
		"look_down": [JOY_AXIS_RIGHT_Y, 1.0],
	}
	for action: String in axes:
		_check(InputMap.has_action(action), "action '%s' exists" % action)
		if _failed:
			return
		var expected: Array = axes[action]
		var found := false
		for ev: InputEvent in InputMap.action_get_events(action):
			var motion := ev as InputEventJoypadMotion
			if motion == null:
				continue
			if motion.axis == expected[0] and signf(motion.axis_value) == signf(expected[1]):
				found = true
		_check(found, "action '%s' is bound to joypad axis %d (sign %+.0f)" % [action, expected[0], expected[1]])
		_check(InputMap.action_get_deadzone(action) <= MAX_STICK_DEADZONE,
			"stick action '%s' keeps an analog deadzone (<= %.2f)" % [action, MAX_STICK_DEADZONE])

	# Verbs sit on pad buttons.
	var buttons := {
		"jump": JOY_BUTTON_A,
		"sprint": JOY_BUTTON_LEFT_STICK,
		"interact": JOY_BUTTON_X,
		"toggle_devlog": JOY_BUTTON_BACK,
		"character_editor": JOY_BUTTON_Y,
	}
	for action: String in buttons:
		var found := false
		for ev: InputEvent in InputMap.action_get_events(action):
			var btn := ev as InputEventJoypadButton
			if btn != null and btn.button_index == buttons[action]:
				found = true
		_check(found, "action '%s' is on joypad button %d" % [action, buttons[action]])


# --- outcome: left stick drives the movement vector -------------------------

func _stick(axis: JoyAxis, value: float) -> void:
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = value
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func _move_vector() -> Vector2:
	return Input.get_vector("move_left", "move_right", "move_forward", "move_back")


func _check_movement_actions() -> void:
	# Full deflection right: the vector saturates at (1, 0).
	_stick(JOY_AXIS_LEFT_X, 1.0)
	_check(_move_vector().distance_to(Vector2(1, 0)) < EPS,
		"full right deflection yields movement vector (1, 0), got %s" % _move_vector())

	# Partial deflection: analog magnitude survives (strictly between 0 and 1) —
	# this is what makes walk speed follow the stick.
	_stick(JOY_AXIS_LEFT_X, 0.6)
	var partial := _move_vector()
	_check(partial.y == 0.0 and partial.x > 0.0 and partial.x < 1.0 - EPS,
		"partial deflection stays analog, got %s" % partial)

	# Inside the deadzone: no movement at all.
	_stick(JOY_AXIS_LEFT_X, 0.1)
	_check(_move_vector() == Vector2.ZERO,
		"deflection inside the deadzone is ignored, got %s" % _move_vector())

	# Stick up = forward (negative y, matching the keyboard convention).
	_stick(JOY_AXIS_LEFT_X, 0.0)
	_stick(JOY_AXIS_LEFT_Y, -1.0)
	_check(_move_vector().distance_to(Vector2(0, -1)) < EPS,
		"stick up yields forward vector (0, -1), got %s" % _move_vector())
	_stick(JOY_AXIS_LEFT_Y, 0.0)


# --- outcome: right stick pans and tilts the camera, clamped ----------------

func _check_camera() -> void:
	var player := Player.new()
	add_child(player)

	# Baseline aim, then a right-stick pan driven with a fixed delta.
	var before := player.aim_forward()
	_stick(JOY_AXIS_RIGHT_X, 1.0)
	player._process(0.1)
	var after := player.aim_forward()
	var turned := before.signed_angle_to(after, Vector3.UP)
	_check(absf(absf(turned) - Player.STICK_LOOK_SPEED_YAW * 0.1) < EPS,
		"a 0.1 s full-right pan turns by yaw speed × delta, got %.4f rad" % turned)
	_check(turned < 0.0, "stick right turns the camera right (negative about UP), got %.4f" % turned)

	# Inside the deadzone the camera must not creep.
	_stick(JOY_AXIS_RIGHT_X, 0.1)
	var idle_before := player.aim_forward()
	player._process(0.1)
	_check(idle_before.angle_to(player.aim_forward()) < EPS,
		"right-stick deflection inside the deadzone leaves the camera still")
	_stick(JOY_AXIS_RIGHT_X, 0.0)

	# Held full-down tilt runs into the same pitch floor the mouse honours —
	# read via the spring arm the camera rig exposes to this scene tree.
	var spring: SpringArm3D = _find_spring(player)
	_check(spring != null, "player camera rig carries a SpringArm3D")
	if _failed:
		return
	_stick(JOY_AXIS_RIGHT_Y, 1.0)
	for i in range(5):
		player._process(1.0)
	_check(absf(spring.rotation.x - Player.PITCH_MIN) < EPS,
		"held down-tilt clamps at PITCH_MIN, got %.4f" % spring.rotation.x)
	_stick(JOY_AXIS_RIGHT_Y, -1.0)
	for i in range(5):
		player._process(1.0)
	_check(absf(spring.rotation.x - Player.PITCH_MAX) < EPS,
		"held up-tilt clamps at PITCH_MAX, got %.4f" % spring.rotation.x)
	_stick(JOY_AXIS_RIGHT_Y, 0.0)

	# While control is disabled (character creator owns the screen) the stick
	# must not move the camera — same rule the mouse path follows.
	player.control_enabled = false
	_stick(JOY_AXIS_RIGHT_X, 1.0)
	var locked_before := player.aim_forward()
	player._process(0.1)
	_check(locked_before.angle_to(player.aim_forward()) < EPS,
		"stick look is ignored while control is disabled")
	_stick(JOY_AXIS_RIGHT_X, 0.0)
	player.control_enabled = true

	player.queue_free()


func _find_spring(node: Node) -> SpringArm3D:
	if node is SpringArm3D:
		return node
	for child in node.get_children():
		var found := _find_spring(child)
		if found != null:
			return found
	return null


# --- outcome: the first-run creator is drivable by pad ----------------------

## A pad has no pointer: unless opening the creator assigns an initial focus
## owner, ui_* navigation has nothing to act on and a first-run controller
## player can never reach the mandatory Wake button.
func _check_creator_focus() -> void:
	var player := Player.new()
	add_child(player)
	var creator := CharacterCreator.new()
	add_child(creator)
	var initial = CharacterFactory.load_recipe("res://recipes/wanderer.json")
	if initial is not Dictionary:
		_fail("wanderer preset recipe failed to load")
		return
	initial.erase("comment")
	creator.open(player, initial, true)
	var focus := get_viewport().gui_get_focus_owner()
	_check(focus != null, "opening the creator assigns a focus owner for pad navigation")
	if not _failed:
		_check(creator.is_ancestor_of(focus), "the initial focus owner sits inside the creator panel")
	creator.queue_free()
	player.queue_free()


# --- regression: the keyboard path is untouched -----------------------------

func _check_keyboard_regression() -> void:
	var press := InputEventKey.new()
	press.physical_keycode = KEY_W
	press.pressed = true
	Input.parse_input_event(press)
	Input.flush_buffered_events()
	_check(_move_vector().distance_to(Vector2(0, -1)) < EPS,
		"W still walks forward, got %s" % _move_vector())
	var release := InputEventKey.new()
	release.physical_keycode = KEY_W
	release.pressed = false
	Input.parse_input_event(release)
	Input.flush_buffered_events()


# --- harness ----------------------------------------------------------------

func _check(condition: bool, label: String) -> void:
	if _failed:
		return
	if not condition:
		_fail(label)


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
