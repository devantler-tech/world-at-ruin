extends SceneTree

var isolated: SaveIsolation
var main: Node

func _initialize() -> void:
	call_deferred("capture")

func capture() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("CAPTURE FAIL — windowed rendering required")
		quit(1)
		return
	root.size = Vector2i(1600, 900)
	isolated = SaveIsolation.new("user://mastery_warning_capture.json")
	if not isolated.begin():
		quit(1)
		return
	var seed := {"version": 5, "attuned": [], "discoveries": [], "reward_claims": [], "quests": {}, "mastery": {"weapons": {"sword": {"banked": 200, "unbanked": 50}}, "bloodstain": {}}}
	if not SaveVault.save_to(SaveVault.vault_path(), seed):
		quit(1)
		return
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for i in 8:
		await process_frame
	var path := SaveVault.vault_path()
	var ledger: Mastery = main.get("_mastery")
	OS.set_environment("WAR_VAULT_PATH", path + ".missing-parent/vault.json")
	ledger.accrue("sword", 1)
	OS.set_environment("WAR_VAULT_PATH", path)
	for i in 2:
		await process_frame
	await RenderingServer.frame_post_draw
	if root.get_texture().get_image().save_png("/private/tmp/war-658-temporary-warning.png") != OK:
		quit(1)
		return
	var foreign: Dictionary = SaveVault.load_saved()
	foreign["mastery"]["weapons"]["sword"]["unbanked"] = 28
	if not SaveVault.save_to(path, foreign):
		quit(1)
		return
	main.get("_mastery_persistence").tick(1.0)
	for i in 2:
		await process_frame
	await RenderingServer.frame_post_draw
	if root.get_texture().get_image().save_png("/private/tmp/war-658-conflict-warning.png") != OK:
		quit(1)
		return
	main.queue_free()
	await process_frame
	if not isolated.real_save_untouched():
		push_error("CAPTURE FAIL — player state changed")
		quit(1)
		return
	print("CAPTURE OK — actual Main temporary and conflict notices")
	quit(0)
