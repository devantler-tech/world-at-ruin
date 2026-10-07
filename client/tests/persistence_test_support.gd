class_name PersistenceTestSupport
extends RefCounted
## Test-only raw-file and private-stage observations. Suites own their failure
## handling, refusal resets and environment restoration; no production sweep is
## used as the oracle for whether a stage survived or a refused write changed bytes.


static func read_text(path: String, check_exists: bool = true) -> String:
	if check_exists and not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text


static func write_text(path: String, text: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	file.close()
	return true


static func remove_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


static func staging_names(path: String, suffix: String) -> Array[String]:
	var found: Array[String] = []
	var prefix := path.get_file() + suffix
	for entry: String in DirAccess.get_files_at(path.get_base_dir()):
		if entry.begins_with(prefix):
			found.append(entry)
	return found


static func staging_paths(path: String, suffix: String) -> Array[String]:
	var found: Array[String] = []
	for entry in staging_names(path, suffix):
		found.append(path.get_base_dir().path_join(entry))
	return found


static func remove_lock_copies(lock: String, suffixes: Array[String]) -> void:
	for entry: String in DirAccess.get_directories_at(lock.get_base_dir()):
		for suffix in suffixes:
			if entry.begins_with(lock.get_file() + suffix):
				FileLock.remove_dir(lock.get_base_dir().path_join(entry))


static func private_name_errors(first: String, second: String, path: String, suffix: String) -> Array[String]:
	var errors: Array[String] = []
	if first == path + ".tmp":
		errors.append("staging name is the derivable <path>.tmp")
	if first == second:
		errors.append("two staging attempts share one name (%s)" % first)
	if not first.begins_with(path + suffix):
		errors.append("staging name does not carry the sweepable prefix (%s)" % first)
	if not first.contains(str(OS.get_process_id())):
		errors.append("staging name does not carry this process id (%s)" % first)
	return errors

## Read a test-owned historical object without reserializing its original bytes.
## The filename's version remains independent of the production reader.
static func historical_fixture(path: String, version: int) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"problem": "unreadable"}
	var raw := file.get_as_text()
	file.close()
	var expected = JSON.parse_string(raw)
	if expected is not Dictionary:
		return {"problem": "not a JSON object"}
	if int(expected.get("version", -1)) != version:
		return {"problem": "declares version %s but its filename says v%d — a stale copy cannot stand in for v%d coverage" % [
			str(expected.get("version", "none")), version, version]}
	return {"problem": "", "raw": raw, "expected": expected}


## Interpose caller-owned bytes without a production writer or serializer.
## Results are observations; each scene states its own success/refusal oracle.
static func interposed_write(path: String, foreign_bytes: String, write: Callable) -> Dictionary:
	if not write_text(path, foreign_bytes):
		return {"seeded": false}
	var before := read_text(path)
	var result: Variant = write.call()
	return {"seeded": true, "before": before, "after": read_text(path), "result": result}


## Preserve a test-owned squatter observation even when the attempted save fails.
static func foreign_stage(path: String, bytes: String, write: Callable) -> Dictionary:
	var foreign := path + ".tmp"
	if not write_text(foreign, bytes):
		return {"seeded": false}
	var result: Variant = write.call()
	var observation := {"seeded": true, "result": result,
		"exists": FileAccess.file_exists(foreign), "bytes": read_text(foreign)}
	remove_file(foreign)
	return observation


static func completed_write(path: String, suffix: String, write: Callable) -> Dictionary:
	var result: Variant = write.call()
	return {"result": result, "stages": staging_names(path, suffix)}
