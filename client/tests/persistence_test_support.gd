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
