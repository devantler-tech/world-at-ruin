extends Node
## Runs from a real exported base pack; the optional overlay is the only candidate content.


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		_fail("overlay argument is absent")
		return
	var base: Material = ResourceLoader.load("res://assets/material.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
	if base == null or base.resource_name != "base":
		_fail("exported base resource was not loaded")
		return
	if args.size() == 1 and not ProjectSettings.load_resource_pack(args[0], true):
		_fail("native overlay mount failed")
		return
	var candidate: Material = ResourceLoader.load("res://assets/material.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
	if candidate == null or candidate.resource_name != "candidate":
		_fail("candidate resource did not take precedence")
		return
	if FileAccess.get_file_as_string("res://assets/added.txt") != "new cumulative content\n":
		_fail("cumulative addition is missing from the old base")
		return
	var imported: Texture2D = ResourceLoader.load("res://assets/pixel.png", "", ResourceLoader.CACHE_MODE_IGNORE)
	if imported == null or imported.get_width() != 3 or imported.get_height() != 2:
		_fail("freshly imported resource closure cannot load")
		return
	if FileAccess.get_file_as_string("res://scripts/shell/identity.txt") != "immutable recovery\n":
		_fail("protected shell resource was replaced")
		return
	var recovery: Script = ResourceLoader.load("res://scripts/boot_recovery.gd", "", ResourceLoader.CACHE_MODE_IGNORE)
	if recovery == null or recovery.identity() != "base recovery":
		_fail("exact protected recovery owner was redirected through a remap")
		return
	var fresh_script: Script = ResourceLoader.load("res://assets/hijack.gd", "", ResourceLoader.CACHE_MODE_IGNORE)
	if fresh_script == null or fresh_script.identity() != "candidate recovery":
		_fail("fresh source script and generated native UID did not load")
		return
	print("PACK MOUNT PASS — native overlay precedence, cumulative additions, imported texture and protected shell")
	get_tree().quit(0)


func _fail(message: String) -> void:
	print("PACK MOUNT REFUSED — " + message)
	get_tree().quit(1)
