class_name PrivateStaging
extends RefCounted
## Shared mechanics for persisted writers' private staging files.
##
## This class owns only the name shape and prefix scan. Whether a matching file
## is safe to reclaim belongs to the writer: shipping order gives SaveVault and
## BootRecovery an unconditional lock-held policy, while CharacterStore must
## permanently keep its age floor for retained pre-lock builds.

## Prefix shared by every private staging path.
const WRITE_TMP_SUFFIX := ".tmp-"


## A staging file PRIVATE to one write attempt.
static func write_path(path: String) -> String:
	return "%s%s%d-%d" % [
		path,
		WRITE_TMP_SUFFIX,
		OS.get_process_id(),
		Time.get_ticks_usec(),
	]


## Scan `path`'s private staging siblings and reclaim only candidates approved by
## `eligible`. An invalid predicate fails closed and removes nothing.
static func sweep(path: String, eligible: Callable) -> void:
	if not eligible.is_valid():
		return
	var parent := path.get_base_dir()
	var prefix := path.get_file() + WRITE_TMP_SUFFIX
	for entry: String in DirAccess.get_files_at(parent):
		if not entry.begins_with(prefix):
			continue
		var candidate := parent.path_join(entry)
		if eligible.call(candidate) as bool:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(candidate))
