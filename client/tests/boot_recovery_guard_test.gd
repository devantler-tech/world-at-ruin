extends Node
## Forward-only fixture guard for the immutable shell's recovery memory
## (#343, parent #256).
##
## The shipped unversioned document is v0 and remains readable forever. After
## the v0.51.1 reader expansion became the standing retained rollback target,
## first boot and the next real write of v0 state contract to explicit v1.
## Every ledger version must have a golden fixture that survives load without
## churn and write-back without loss. Newer or corrupt documents degrade
## path-latched read-only: their bytes are preserved and new updates are refused,
## but the recovery file may not veto an otherwise compatible retained rollback.
##
## Run: godot --headless --path client res://tests/boot_recovery_guard_test.tscn

const DATA_DIR := "res://tests/data/"
const SHIPPED_VERSIONS := DATA_DIR + "shipped_boot_recovery_versions.txt"
const PROBE := "user://boot_recovery_guard_probe.json"
const REPLACED_PROBE := "user://boot_recovery_replaced_probe.json"


func _ready() -> void:
	_cleanup_probe()
	var discovered: Variant = _discover_fixtures()
	if discovered is String:
		_fail(discovered)
		return
	var fixtures: Dictionary = discovered
	var shipped := _shipped_versions()
	if shipped.is_empty():
		_fail("shipped_boot_recovery_versions.txt is missing, empty, or malformed")
		return

	var fresh := BootRecovery.fresh_state()
	var write_version: Variant = fresh.get("version")
	var read_ceiling := BootRecovery.RECOVERY_VERSION
	if (
		not UpdateDecision.is_int_id(write_version)
		or int(write_version) != read_ceiling):
		_fail("the contract release must originate the baked recovery schema v%d" % read_ceiling)
		return
	if shipped != range(0, read_ceiling + 1):
		_fail("recovery version ledger must be contiguous from legacy v0 through v%d (got %s)" % [
			read_ceiling, str(shipped)])
		return
	for version: int in shipped:
		if version not in fixtures:
			_fail("shipped recovery v%d has no golden_boot_recovery_v%d.json fixture" % [
				version, version])
			return
	for version: int in fixtures:
		if version not in shipped:
			_fail("golden_boot_recovery_v%d.json is not anchored in the shipped-version ledger" % version)
			return

	for version: int in shipped:
		var reason := _check_fixture(version, fixtures[version], int(write_version))
		if reason != "":
			_fail("golden_boot_recovery_v%d.json: %s" % [version, reason])
			return

	var refusal := _check_read_only_degradation(fixtures[read_ceiling], read_ceiling)
	if refusal != "":
		_fail(refusal)
		return
	var replaced := _check_destination_revalidation(fixtures[0], fixtures[read_ceiling], read_ceiling)
	if replaced != "":
		_fail(replaced)
		return

	_cleanup_probe()
	print("TEST PASS — recovery v0..v%d loads without churn, real writes contract to v%d, and refused/replaced files preserve bytes without blocking rollback" % [
		read_ceiling, int(write_version)])
	get_tree().quit(0)


func _check_fixture(version: int, path: String, write_version: int) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "fixture is unreadable"
	var raw := file.get_as_text()
	file.close()
	var expected: Variant = JSON.parse_string(raw)
	if expected is not Dictionary:
		return "fixture is not a JSON object"
	var declared: Variant = (expected as Dictionary).get("version", 0)
	if not UpdateDecision.is_int_id(declared) or int(declared) != version:
		return "declares version %s but its filename says v%d" % [str(declared), version]
	if not _write_probe(raw):
		return "could not seed the probe"

	var loaded := BootRecovery.load_state(PROBE)
	if not (loaded["ok"] as bool):
		return "historical recovery state was refused: %s" % str(loaded["reason"])
	var state: Variant = loaded["state"]
	var lost := _diff(expected, state, "recovery")
	if lost != "":
		return "LOAD LOST DATA (no-resets law): %s" % lost
	if (
		state is not Dictionary
		or not UpdateDecision.is_int_id((state as Dictionary).get("version"))
		or int((state as Dictionary).get("version")) != version):
		return "reader churned recovery v%d before a real write" % version
	var saved := BootRecovery.save_state(PROBE, state)
	if not (saved["ok"] as bool):
		return "historical recovery state could not be re-saved: %s" % str(saved["reason"])
	var rewritten: Variant = JSON.parse_string(FileAccess.get_file_as_string(PROBE))
	var dropped := _diff(expected, rewritten, "recovery")
	if dropped != "":
		return "SAVE DROPPED DATA (no-resets law): %s" % dropped
	if (
		rewritten is not Dictionary
		or int((rewritten as Dictionary).get("version", 0)) != max(version, write_version)):
		return "real write of recovery v%d did not contract to the baked writer v%d" % [
			version, max(version, write_version)]
	return ""


func _check_read_only_degradation(fixture_path: String, current: int) -> String:
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(fixture_path))
	if doc is not Dictionary:
		return "refusal control fixture is unreadable"
	var future: Dictionary = (doc as Dictionary).duplicate(true)
	future["version"] = current + 1
	var future_raw := JSON.stringify(future)
	if not _write_probe(future_raw):
		return "could not seed a future-version probe"
	var newer := BootRecovery.load_state(PROBE)
	var reason := _assert_degraded(newer, future_raw, "newer-version")
	if reason != "":
		return reason

	var corrupt_raw := "{ this is not json"
	if not _write_probe(corrupt_raw):
		return "could not seed a corrupt probe"
	var corrupt := BootRecovery.load_state(PROBE)
	return _assert_degraded(corrupt, corrupt_raw, "corrupt")


func _assert_degraded(loaded: Dictionary, original: String, kind: String) -> String:
	if loaded["ok"] as bool:
		return "%s recovery state loaded instead of refusing" % kind
	var state: Variant = loaded["state"]
	if state is not Dictionary:
		return "%s refusal did not provide a rollback-safe degraded state" % kind
	var ledger: Variant = (state as Dictionary).get("quarantined")
	if not RollbackSelection.is_readable_ledger(ledger):
		return "%s recovery state made the rollback ledger unreadable" % kind
	var pick := RollbackSelection.select([_target("0.5.0")], _select_state(ledger))
	if pick["action"] != RollbackSelection.ROLLBACK:
		return "%s recovery state blocked an otherwise-compatible rollback: %s" % [
			kind, str(pick["reason"])]
	if BootRecovery.begin_attempt(state, "0.6.0")["ok"] as bool:
		return "%s recovery state admitted a new update attempt despite lost quarantine evidence" % kind
	if BootRecovery.save_state(PROBE, state)["ok"] as bool:
		return "%s recovery evidence was overwritten by degraded state" % kind
	if BootRecovery.save_state(PROBE, BootRecovery.fresh_state())["ok"] as bool:
		return "%s recovery refusal was bypassed with reconstructed fresh state" % kind
	if FileAccess.get_file_as_string(PROBE) != original:
		return "%s recovery evidence changed despite the read-only refusal" % kind
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROBE))
	if BootRecovery.save_state(PROBE, BootRecovery.fresh_state())["ok"] as bool:
		return "%s recovery path became writable after refused evidence disappeared" % kind
	if FileAccess.file_exists(PROBE):
		return "%s recovery path was recreated after its refusal latch fired" % kind
	return ""


func _check_destination_revalidation(
		v0_fixture: String, current_fixture: String, current: int) -> String:
	var v0_raw := FileAccess.get_file_as_string(v0_fixture)
	if not _write_probe_at(REPLACED_PROBE, v0_raw):
		return "could not seed the destination-revalidation probe"
	var loaded := BootRecovery.load_state(REPLACED_PROBE)
	if not (loaded["ok"] as bool):
		return "could not capture a valid v0 state before replacement"
	var future: Variant = JSON.parse_string(FileAccess.get_file_as_string(current_fixture))
	if future is not Dictionary:
		return "destination-revalidation control fixture is unreadable"
	(future as Dictionary)["version"] = current + 1
	var replacement := JSON.stringify(future)
	if not _write_probe_at(REPLACED_PROBE, replacement):
		return "could not replace the recovery path with a future document"
	if BootRecovery.save_state(REPLACED_PROBE, loaded["state"])["ok"] as bool:
		return "a state captured before another shell replaced the path overwrote newer recovery evidence"
	if FileAccess.get_file_as_string(REPLACED_PROBE) != replacement:
		return "destination revalidation changed the newer recovery evidence"
	return ""


func _target(version: String) -> Dictionary:
	return {
		"version": version,
		"url": "https://updates.example/%s.pck" % version,
		"sha256": "a".repeat(64),
		"size": 1,
		"read_ceiling": 1,
		"save_capability": 1,
		"speaks_protocol": {"min": 1, "max": 1},
		"shell_compat": {"min": "0.1.0", "max": "0.9.0"},
	}


func _select_state(quarantined: Variant) -> Dictionary:
	return {
		"save": {"schema": 1, "capability": 1},
		"protocol": {"min": 1, "max": 1},
		"shell_version": "0.5.0",
		"quarantined": quarantined,
	}


func _discover_fixtures() -> Variant:
	var dir := DirAccess.open(DATA_DIR)
	if dir == null:
		return "cannot open %s" % DATA_DIR
	var fixtures := {}
	for name in dir.get_files():
		var stem := name.trim_suffix(".remap")
		if not (stem.begins_with("golden_boot_recovery_v") and stem.ends_with(".json")):
			continue
		var digits := stem.trim_prefix("golden_boot_recovery_v").trim_suffix(".json")
		if not digits.is_valid_int():
			return "fixture '%s' does not carry an integer version" % name
		fixtures[int(digits)] = DATA_DIR + stem
	return fixtures


func _shipped_versions() -> Array:
	var file := FileAccess.open(SHIPPED_VERSIONS, FileAccess.READ)
	if file == null:
		return []
	var versions := []
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		if not line.is_valid_int():
			return []
		versions.append(int(line))
	file.close()
	versions.sort()
	return versions


func _diff(expected: Variant, actual: Variant, path: String) -> String:
	if expected is Dictionary:
		if actual is not Dictionary:
			return "%s changed from object to %s" % [path, type_string(typeof(actual))]
		for key: String in (expected as Dictionary):
			if not (actual as Dictionary).has(key):
				return "%s.%s is missing" % [path, key]
			var nested := _diff(
				(expected as Dictionary)[key],
				(actual as Dictionary)[key],
				"%s.%s" % [path, key])
			if nested != "":
				return nested
		return ""
	if expected is Array:
		if actual is not Array:
			return "%s changed from array to %s" % [path, type_string(typeof(actual))]
		for item: Variant in (expected as Array):
			if item not in (actual as Array):
				return "%s lost entry %s" % [path, str(item)]
		return ""
	if expected != actual:
		return "%s changed: %s -> %s" % [path, str(expected), str(actual)]
	return ""


func _write_probe(raw: String) -> bool:
	return _write_probe_at(PROBE, raw)


func _write_probe_at(path: String, raw: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(raw)
	file.close()
	return true


func _fail(message: String) -> void:
	_cleanup_probe()
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)


func _exit_tree() -> void:
	_cleanup_probe()


func _cleanup_probe() -> void:
	for path in [PROBE, REPLACED_PROBE]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
