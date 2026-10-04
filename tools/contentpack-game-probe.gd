extends SceneTree
## Real game resource closure readback after the experimental cumulative pack mounts.


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		_fail("one experimental game pack is required")
		return
	var shell_before := FileAccess.get_file_as_bytes("res://scripts/boot_recovery.gd")
	if not ProjectSettings.load_resource_pack(args[0], true):
		_fail("game pack could not mount")
		return
	var hound: PackedScene = ResourceLoader.load(
		"res://assets/characters/creature_kit/ash_hound.glb", "", ResourceLoader.CACHE_MODE_IGNORE)
	if hound == null:
		_fail("native imported game scene is missing")
		return
	var creature := hound.instantiate()
	if creature == null:
		_fail("native imported game scene cannot instantiate")
		return
	creature.free()
	var scene: PackedScene = ResourceLoader.load("res://scenes/main.tscn", "", ResourceLoader.CACHE_MODE_IGNORE)
	if scene == null:
		_fail("game content scene is missing")
		return
	if shell_before != FileAccess.get_file_as_bytes("res://scripts/boot_recovery.gd"):
		_fail("game recovery owner entered the replaceable pack")
		return
	print("GAME PACK PASS — full game scene and imported creature load; recovery stays base-owned")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
