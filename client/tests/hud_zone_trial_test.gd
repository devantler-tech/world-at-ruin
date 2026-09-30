extends Node
## The owner trial has a quiet, persistent status below the build identity.
## This test builds the real HUD at the shipped viewport size; no world or save
## is opened. The normal HUD must not allocate a trial label at all.

var _failed := false


func _ready() -> void:
	get_tree().root.size = Vector2i(1600, 900)
	var hud := Hud.new()
	add_child(hud)
	await get_tree().process_frame
	_check(hud.get_node_or_null("ZoneTrialStatus") == null,
		"the ordinary HUD must contain no private trial status")
	_check(hud.has_method("update_zone_trial_status"),
		"the opt-in trial has no visible connection status")
	if _failed:
		return

	hud.call("update_zone_trial_status", ZoneConnection.State.CONNECTING)
	var label := hud.get_node_or_null("ZoneTrialStatus") as Label
	_check(label != null, "an explicit trial must build its status label")
	if _failed:
		return
	_check(label.text == "Private server trial · connecting…", "connecting must remain provisional")
	hud.call("update_zone_trial_status", ZoneConnection.State.LIVE)
	_check(label.text == "Private server trial · waiting for world data",
		"an open socket without a snapshot must not claim live world data")
	hud.call("update_zone_trial_status", ZoneConnection.State.LIVE, 0, 0)
	_check(label.text == "Private server trial · live · tick 0 · 0 entities",
		"an initial empty snapshot is valid world data, including tick zero")
	hud.call("update_zone_trial_status", ZoneConnection.State.LIVE, 42, 2)
	_check(label.text == "Private server trial · live · tick 42 · 2 entities",
		"the status must name the last applied tick and replica count")
	for state: int in [ZoneConnection.State.FAILED, ZoneConnection.State.CLOSED,
			ZoneConnection.State.CLOSING, ZoneConnection.State.DISCONNECTED]:
		hud.call("update_zone_trial_status", state, 42, 2)
		_check(label.text == "Private server trial · disconnected · relaunch to connect",
			"a stopped stream must give the trial's real recovery action")
	_check(label.visible and label.modulate.a > 0.01, "the trial status must stay readable")
	_check(label.get_theme_font_size("font_size") == UiTheme.FONT_BODY,
		"the trial status must use the existing body font")
	_check(label.get_theme_color("font_color") == UiTheme.BONE,
		"the trial status must use the existing readable text palette")
	await get_tree().process_frame
	var box := label.get_global_rect()
	_check(box.position == Vector2(18, 62), "the trial status must sit below the build identity")
	_check(box.end.x <= 1582 and box.end.y < 120, "trial text must fit before the toast row")
	hud.show_prompt("[E] Speak")
	var prompt := hud.get("_prompt") as Label
	_check(not box.intersects(prompt.get_global_rect()), "trial status must not cover an interaction prompt")
	_check(hud.get_node("ZoneTrialStatus") == label, "status updates must reuse one label")
	if _failed:
		return
	print("TEST PASS — trial status is absent by default, provisional before data, live after a snapshot, and readable without covering existing HUD prompts")
	get_tree().quit(0)


func _check(condition: bool, message: String) -> void:
	if condition or _failed:
		return
	_failed = true
	print("TEST FAIL — " + message)
	get_tree().quit(1)
