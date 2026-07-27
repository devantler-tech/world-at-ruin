extends Node
## Controlled process probe for vault_restore_boot_test's failure teardown.
##
## Corrupts only SaveIsolation's recorded baseline, never the player's real
## files, then invokes the actual failure helper. The outer shell guard expects
## the helper to report that the mismatch was detected before cleanup.

const TARGET_SCRIPT := preload("res://tests/vault_restore_boot_test.gd")
const FORCED_FAILURE := "forced failure-path probe"


func _ready() -> void:
	var target := Node.new()
	add_child(target)
	# Attach the script after the node's normal ready point so its full boot test
	# does not start; this probe calls only the real failure helper.
	await get_tree().process_frame
	target.set_script(TARGET_SCRIPT)

	var isolation := SaveIsolation.new("user://vault_restore_failure_path_probe.json")
	if not isolation.begin():
		push_error("failure-path probe could not establish save isolation")
		get_tree().quit(2)
		return
	# A deliberately impossible prior hash makes real_save_untouched() report a
	# breach without changing character.json or any other real player file.
	isolation.set("_default_before_sha", "forced-isolation-breach")
	target.set("_save", isolation)
	target.call("_fail", FORCED_FAILURE)
