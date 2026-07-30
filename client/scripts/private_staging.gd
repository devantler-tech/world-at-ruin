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

## Disambiguates attempts when the monotonic clock returns the same microsecond
## twice.
static var _attempt_sequence := 0

## Separates this process lifetime from abandoned stages left by an older process
## that used the same process id before its monotonic clock restarted.
static var _process_nonce := Crypto.new().generate_random_bytes(8).hex_encode()


## A staging file PRIVATE to one write attempt.
static func write_path(path: String) -> String:
	_attempt_sequence += 1
	return "%s%s%d-%s-%d-%d" % [
		path,
		WRITE_TMP_SUFFIX,
		OS.get_process_id(),
		_process_nonce,
		Time.get_ticks_usec(),
		_attempt_sequence,
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
