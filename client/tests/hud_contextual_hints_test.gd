extends Node
## Regression test for contextual control hints (issue #271, Part of #227).
##
## The product problem: the HUD listed the whole control set along the bottom of
## every frame forever, so a wall of text sat over the world whether or not the
## player still needed it.
##
## `WAR_CONTEXTUAL_HINTS` is the opt-in flag for the replacement. Both states are
## tested here, because a flag whose OFF path is untested silently becomes the
## only path anyone verifies:
##
##  1. OFF — the shipped default is byte-for-byte the old behaviour: the bar is
##     built full, opaque, and STAYS opaque past any dwell. This is the
##     assertion a "the flag leaked into the default" regression trips.
##  2. ON — the bar reveals, then fades to nothing after its dwell. The label
##     keeps its TEXT while faded, so the #194 device-exclusivity guard in
##     `input_device_prompts_test` still reads a real line.
##  3. ON — a device change re-reveals it, with the NEW device's bindings. This
##     is #194 preserved through the fade: picking up a pad is exactly when the
##     bindings changed under the player and are worth showing again.
##  4. ON — discoverability. A permanent affordance names the key that brings
##     the full set back, and its label is DERIVED from `InputMap` rather than
##     written out, so a rebinding moves it and the two cannot drift.
##  5. ON — that key, pressed through the real input dispatch, pins the bar
##     against the fade and unpins it again.
##  6. Both — every HUD colour and font size comes from `UiTheme` (#270), not
##     from engine defaults or a second copy of the palette.
##
## Safe headless: no main.tscn boot and no save IO — the HUD is instantiated
## directly. The dwell is shortened through `WAR_HINT_DWELL_SECONDS` so the
## timing is exercised for real rather than simulated, without costing the
## suite six seconds per case.
##
## Run: godot --headless --path client res://tests/hud_contextual_hints_test.tscn

const FLAG_ENV := "WAR_CONTEXTUAL_HINTS"
const DWELL_ENV := "WAR_HINT_DWELL_SECONDS"

## Short enough to keep the suite fast, long enough that a frame hitch cannot
## make the bar fade before the "it starts visible" assertion reads it.
const TEST_DWELL := "0.12"

## Comfortably past dwell + fade (0.12 + `Hud.HINT_FADE_SECONDS`), so "it faded"
## is never a race with the tween's last frames. Measured at 0.9 the fade was
## still mid-flight at alpha 0.02.
const SETTLE_SECONDS := 1.8

## Independent literals. Reading `InputDevice`'s own tables here would let the
## test and the code share one wrong value.
const KEYBOARD_TOGGLE := "H"
const PAD_TOGGLE := "RB"

## The shipped viewport (project.godot's `window/size/viewport_*`), restated
## here so a placement assertion is measured against the size the player runs
## rather than whatever window the harness happened to open.
const WINDOW_WIDTH := 1600
const WINDOW_HEIGHT := 900

var _failed := false


func _ready() -> void:
	Player.ensure_input_actions()
	# Headless boots a 64x64 dummy window, which is SMALLER than the hint labels'
	# own minimum size — every Control's rect is then clamped up to its content
	# and the placement assertions below would fail on correct code while
	# telling us nothing. Ask for the shipped viewport so the layout under test
	# is the layout the player gets.
	get_tree().root.size = Vector2i(WINDOW_WIDTH, WINDOW_HEIGHT)
	await get_tree().process_frame
	if get_tree().root.size.x != WINDOW_WIDTH:
		print("TEST FAIL — could not size the test window to %dx%d (got %s); "
			% [WINDOW_WIDTH, WINDOW_HEIGHT, get_tree().root.size]
			+ "the placement assertions would be measuring the dummy window")
		get_tree().quit(1)
		return

	_test_env_names_are_the_documented_ones()
	if _failed:
		return
	await _test_default_stays_permanent()
	if _failed:
		return
	await _test_flag_on_reveals_then_fades()
	if _failed:
		return
	await _test_device_change_rereveals()
	if _failed:
		return
	await _test_affordance_is_derived()
	if _failed:
		return
	await _test_toggle_pins_against_the_fade()
	if _failed:
		return
	await _test_styling_comes_from_the_theme()
	if _failed:
		return

	print("TEST PASS — control hints are contextual behind WAR_CONTEXTUAL_HINTS: "
		+ "the default bar is still permanent, the opt-in bar fades after its dwell, "
		+ "a device change and the derived toggle key both bring it back, "
		+ "and every HUD colour and size comes from UiTheme")
	get_tree().quit(0)


# --- 0. the env names are the ones we told players to use --------------------

## These two literals stay INDEPENDENT of `Hud`'s constants rather than
## referencing them, because the names are a PUBLIC contract, not an internal
## detail: `client/devlog/0.63.0.json` tells players to set
## `WAR_CONTEXTUAL_HINTS=1`, and `hud.gd` documents both. Referencing
## `Hud.CONTEXTUAL_HINTS_ENV` here would let a rename sail through green while
## silently breaking the name we published.
##
## Pinning them explicitly is what removes the drift risk that referencing would
## otherwise address. Note a rename is ALREADY caught loudly — it makes the flag
## read false, and the `flag-always-off` ablation shows that failing on "the
## opt-in hint bar faded out after its dwell". This turns that indirect,
## puzzling failure into one that names the actual cause.
func _test_env_names_are_the_documented_ones() -> void:
	_check(Hud.CONTEXTUAL_HINTS_ENV == FLAG_ENV,
		"the opt-in flag is still the published '%s' (Hud says '%s')"
			% [FLAG_ENV, Hud.CONTEXTUAL_HINTS_ENV])
	_check(Hud.HINT_DWELL_ENV == DWELL_ENV,
		"the dwell override is still '%s' (Hud says '%s')"
			% [DWELL_ENV, Hud.HINT_DWELL_ENV])


# --- 1. the default path is untouched ---------------------------------------

## The flag's whole promise: with it off, a player sees exactly what they saw
## before. A fade that leaked into the default would be a player-visible change
## nobody opted into, so this asserts on the alpha rather than on "is a tween
## running" — the observable, not the mechanism.
func _test_default_stays_permanent() -> void:
	var hud := await _build_hud("")

	_check(hud.hints_visible(), "the default hint bar is visible at boot")
	_check(hud.hint_text() == InputDevice.hint_line(InputDevice.KEYBOARD),
		"the default hint bar carries the full keyboard control set")
	_check(hud.get("_hint_affordance") == null,
		"the default HUD builds no affordance — the full set is already on screen")
	if _failed:
		return

	await _settle()
	_check(hud.hints_visible(),
		"the default hint bar is STILL visible long past any dwell (alpha %.2f)"
			% _hints_alpha(hud))
	if _failed:
		await _drop_hud(hud)
		return

	# The toggle key is registered in every build, so prove it is INERT here.
	# A default build that could hide its own control bar would be exactly the
	# player-visible change nobody opted into.
	#
	# TWICE, deliberately. One press of a live toggle only PINS the bar, leaving
	# alpha at 1.0 — indistinguishable from the permanent bar, so a single-press
	# check passes with every flag guard deleted (measured). The second press is
	# what would unpin and hide it, and that is the state this must never reach.
	await _press_key(KEY_H)
	await _press_key(KEY_H)
	_check(hud.hints_visible(),
		"the toggle key is inert on the default bar even pressed twice (alpha %.2f)"
			% _hints_alpha(hud))
	await _drop_hud(hud)


# --- 2. opt-in: reveal, then give the frame back ----------------------------

func _test_flag_on_reveals_then_fades() -> void:
	var hud := await _build_hud("1")

	_check(hud.hints_visible(), "the opt-in hint bar still reveals at boot")
	if _failed:
		await _drop_hud(hud)
		return

	await _settle()
	_check(not hud.hints_visible(),
		"the opt-in hint bar faded out after its dwell (alpha %.2f)" % _hints_alpha(hud))
	# The #194 guard reads hint_text() on a live HUD. Blanking the TEXT to hide
	# the bar would leave that guard asserting on an empty string, which passes
	# every "contains no pad token" check vacuously.
	_check(hud.hint_text() == InputDevice.hint_line(InputDevice.KEYBOARD),
		"a faded bar keeps its text, so the device-exclusivity guard still has a real line")
	await _drop_hud(hud)


# --- 3. #194 preserved: the bindings changed, so show them ------------------

func _test_device_change_rereveals() -> void:
	var hud := await _build_hud("1")
	await _settle()
	_check(not hud.hints_visible(), "the bar faded before the device change")
	if _failed:
		await _drop_hud(hud)
		return

	await _press_pad(JOY_BUTTON_X)

	_check(hud.hints_visible(), "picking up a pad brings the hint bar back")
	_check(hud.hint_text() == InputDevice.hint_line(InputDevice.PAD),
		"the re-revealed bar shows the PAD bindings, not the keyboard's")
	_check(not hud.hint_text().contains("E interact"),
		"the re-revealed bar dropped the keyboard bindings (#194)")
	if _failed:
		await _drop_hud(hud)
		return

	# And it is a reveal, not a permanent unhide: it fades again.
	await _settle()
	_check(not hud.hints_visible(), "the re-revealed bar fades again on its own")
	await _drop_hud(hud)


# --- 4. discoverability, derived not written out ----------------------------

func _test_affordance_is_derived() -> void:
	var hud := await _build_hud("1")
	var affordance := hud.get("_hint_affordance") as Label

	_check(affordance != null, "the opt-in HUD builds a permanent affordance")
	if _failed:
		await _drop_hud(hud)
		return
	_check(affordance.visible and affordance.modulate.a > 0.01,
		"the affordance is on screen, so the control set is never unreachable")
	# PLACEMENT, not just presence. `visible`, `modulate` and `text` all read
	# correct on a label whose rect overhangs the window — and because this one
	# is right-aligned, the text then draws past the edge and the player sees
	# nothing at all. Measured on the first cut of this change: rect 1690px wide
	# in a 1600px viewport, every assertion above green, and the corner empty in
	# the captured frame. Geometry is the only assertion that catches it.
	var view := hud.get_viewport().get_visible_rect()
	var rect := affordance.get_global_rect()
	_check(view.encloses(rect),
		"the affordance's rect stays inside the window (rect %s, window %s)" % [rect, view])
	_check(affordance.text.contains(KEYBOARD_TOGGLE),
		"the affordance names the keyboard key that opens the set (was '%s')" % affordance.text)
	# Derivation, not duplication: the text must be built from the live map.
	_check(affordance.text.contains(InputDevice.binding_label("toggle_hints",
			InputDevice.KEYBOARD, true)),
		"the affordance label is read out of InputMap, so a rebinding moves it")
	if _failed:
		await _drop_hud(hud)
		return

	await _press_pad(JOY_BUTTON_X)
	_check(affordance.text.contains(PAD_TOGGLE),
		"the affordance follows the active device to the pad (was '%s')" % affordance.text)
	_check(not affordance.text.contains(KEYBOARD_TOGGLE),
		"the pad affordance drops the keyboard key (#194 applies here too)")
	await _drop_hud(hud)


# --- 5. the player can pin it -----------------------------------------------

## Driven through `Input.parse_input_event`, so this exercises the real
## dispatch into `_unhandled_input`. Calling the handler directly would pass
## even if the action were never registered or never reached the HUD.
func _test_toggle_pins_against_the_fade() -> void:
	var hud := await _build_hud("1")
	await _settle()
	_check(not hud.hints_visible(), "the bar faded before the toggle")
	if _failed:
		await _drop_hud(hud)
		return

	await _press_key(KEY_H)
	_check(hud.hints_visible(), "the toggle key brings the full set back")
	if _failed:
		await _drop_hud(hud)
		return

	await _settle()
	_check(hud.hints_visible(),
		"a pinned bar survives its dwell — the player asked for it to stay (alpha %.2f)"
			% _hints_alpha(hud))
	if _failed:
		await _drop_hud(hud)
		return

	await _press_key(KEY_H)
	_check(not hud.hints_visible(), "pressing it again puts the frame back")
	await _drop_hud(hud)


# --- 6. the look comes from the authored theme ------------------------------

## #270 authored the palette; #271's other half is the HUD actually using it.
## Asserted on the built labels rather than by reading the source, so a second
## hard-coded copy of the same colours would still fail once either drifts.
func _test_styling_comes_from_the_theme() -> void:
	for flag: String in ["", "1"]:
		var hud := await _build_hud(flag)
		var state := "opt-in" if flag == "1" else "default"

		var hints := hud.get("_hints") as Label
		_check(hints.get_theme_color("font_color") == UiTheme.BONE_DIM,
			"[%s] the hint bar takes its colour from UiTheme.BONE_DIM" % state)
		_check(hints.get_theme_font_size("font_size") == UiTheme.FONT_BODY,
			"[%s] the hint bar takes its size from UiTheme.FONT_BODY" % state)

		var toast := hud.get("_toast") as Label
		_check(toast.get_theme_color("font_color") == UiTheme.EMBER,
			"[%s] the toast takes its colour from UiTheme.EMBER" % state)
		_check(toast.get_theme_font_size("font_size") == UiTheme.FONT_TOAST,
			"[%s] the toast takes its size from UiTheme.FONT_TOAST" % state)

		var prompt := hud.get("_prompt") as Label
		_check(prompt.get_theme_color("font_color") == UiTheme.EMBER,
			"[%s] the interaction prompt takes its colour from UiTheme.EMBER" % state)
		_check(prompt.get_theme_font_size("font_size") == UiTheme.FONT_PROMPT,
			"[%s] the interaction prompt takes its size from UiTheme.FONT_PROMPT" % state)

		await _drop_hud(hud)
		if _failed:
			return


# --- helpers ----------------------------------------------------------------

## A HUD built with the flag in the given state. The environment is set BEFORE
## the node enters the tree, because `_ready` is where the HUD reads it.
func _build_hud(flag: String) -> Hud:
	OS.set_environment(FLAG_ENV, flag)
	OS.set_environment(DWELL_ENV, TEST_DWELL)
	var hud := Hud.new()
	add_child(hud)
	await get_tree().process_frame
	return hud


func _drop_hud(hud: Hud) -> void:
	hud.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


func _hints_alpha(hud: Hud) -> float:
	var hints := hud.get("_hints") as Label
	return 0.0 if hints == null else hints.modulate.a


## Real elapsed time, not a frame count: the fade is a tween on wall-clock
## seconds, so counting frames would make the test's verdict depend on how
## fast the runner happens to be.
func _settle() -> void:
	await get_tree().create_timer(SETTLE_SECONDS).timeout


func _press_pad(button: int) -> void:
	var event := InputEventJoypadButton.new()
	event.button_index = button
	event.pressed = true
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	await get_tree().process_frame


func _press_key(key: Key) -> void:
	var down := InputEventKey.new()
	down.physical_keycode = key
	down.pressed = true
	Input.parse_input_event(down)
	Input.flush_buffered_events()
	await get_tree().process_frame
	var up := InputEventKey.new()
	up.physical_keycode = key
	up.pressed = false
	Input.parse_input_event(up)
	Input.flush_buffered_events()
	await get_tree().process_frame


func _check(condition: bool, what: String) -> void:
	if _failed:
		return
	if not condition:
		_failed = true
		print("TEST FAIL — %s" % what)
		get_tree().quit(1)
