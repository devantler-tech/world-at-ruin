extends Node
## Contract test for #465: persisted writers share the private-staging mechanics
## while retaining ownership of the policy that decides which stages are safe
## to reclaim.
##
## Run: godot --headless --path client res://tests/private_staging_test.tscn

const PRIVATE_STAGING_PATH := "res://scripts/private_staging.gd"

var _eligible_path := ""
var _failures: Array[String] = []
var _helper: GDScript
var _probe: String
var _seen: Array[String] = []


func _ready() -> void:
	_probe = "user://private_staging_probe.process-%d.json" % OS.get_process_id()
	_cleanup()

	if not ResourceLoader.exists(PRIVATE_STAGING_PATH):
		_fail("the shared private-staging primitive is absent")
		_finish()
		return
	_helper = load(PRIVATE_STAGING_PATH) as GDScript
	if _helper == null:
		_fail("the shared private-staging primitive did not load")
		_finish()
		return

	_check_name_shape()
	_check_predicate_controls_reclamation()

	_finish()


func _check_name_shape() -> void:
	var first := str(_helper.call("write_path", _probe))
	var second := str(_helper.call("write_path", _probe))
	if first == second:
		_fail("two staging attempts share one name (%s)" % first)
	if not first.begins_with(_probe + ".tmp-"):
		_fail("staging name does not carry the shared sweepable prefix (%s)" % first)
	# A clock is not a uniqueness source: two attempts can begin inside one
	# microsecond, and a later process can reuse a pid after the monotonic clock
	# restarts. Require pid, process-start nonce, tick, and attempt sequence so
	# either incomplete identity shape fails deterministically.
	var stamp_parts := first.trim_prefix(_probe + ".tmp-").split("-")
	var second_parts := second.trim_prefix(_probe + ".tmp-").split("-")
	if stamp_parts.size() != 4 or second_parts.size() != 4:
		_fail("staging name has no complete process-lifetime identity (%s, %s)" % [first, second])
		return
	if stamp_parts[0] != str(OS.get_process_id()) or second_parts[0] != stamp_parts[0]:
		_fail("staging name does not carry this process id (%s, %s)" % [first, second])
	if stamp_parts[1].length() != 16 or second_parts[1] != stamp_parts[1]:
		_fail("staging process nonce is absent or unstable (%s, %s)" % [first, second])
	if not stamp_parts[2].is_valid_int() or not second_parts[2].is_valid_int():
		_fail("staging monotonic tick is malformed (%s, %s)" % [first, second])
	if not stamp_parts[3].is_valid_int() or not second_parts[3].is_valid_int():
		_fail("process-local attempt sequence is malformed (%s, %s)" % [first, second])
		return
	var first_sequence := stamp_parts[3].to_int()
	var second_sequence := second_parts[3].to_int()
	if second_sequence <= first_sequence:
		_fail("process-local attempt sequence did not advance (%s, %s)" % [first, second])


func _check_predicate_controls_reclamation() -> void:
	var remove := str(_helper.call("write_path", _probe))
	var keep := str(_helper.call("write_path", _probe))
	var foreign := _probe + ".tmp"
	_write_text(remove, "abandoned")
	_write_text(keep, "live")
	_write_text(foreign, "foreign")

	_eligible_path = remove
	_seen.clear()
	_helper.call("sweep", _probe, Callable(self, "_is_eligible"))

	if FileAccess.file_exists(remove):
		_fail("the predicate-approved stage was not reclaimed")
	if not FileAccess.file_exists(keep):
		_fail("the predicate-refused stage was reclaimed")
	if not FileAccess.file_exists(foreign):
		_fail("the prefix scan touched a foreign writer's fixed stage")
	if not _seen.has(remove) or not _seen.has(keep) or _seen.size() != 2:
		_fail("the predicate did not decide every and only matching stage (%s)" % str(_seen))


func _is_eligible(candidate: String) -> bool:
	_seen.append(candidate)
	return candidate == _eligible_path


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("could not seed %s" % path)
		return
	file.store_string(text)
	file.close()


func _finish() -> void:
	_cleanup()
	if _failures.is_empty():
		print("TEST PASS — private staging shares mechanics, not policy (2 checks)")
		get_tree().quit(0)
		return
	print("TEST FAIL — %s" % "; ".join(_failures))
	get_tree().quit(1)


func _cleanup() -> void:
	for path: String in _seen:
		_remove(path)
	_remove(_eligible_path)
	_remove(_probe + ".tmp")
	if _probe.is_empty():
		return
	var parent := _probe.get_base_dir()
	var prefix := _probe.get_file() + ".tmp-"
	for entry: String in DirAccess.get_files_at(parent):
		if entry.begins_with(prefix):
			_remove(parent.path_join(entry))


func _remove(path: String) -> void:
	if not path.is_empty() and FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _fail(message: String) -> void:
	push_error("private_staging_test: " + message)
	_failures.append(message)


func _exit_tree() -> void:
	_cleanup()
