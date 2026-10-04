class_name UpdateHistory
extends RefCounted
## Local anti-replay authority, separate from every player-data format.
## Acceptance reads current authority under the lock after network work ends.

const DEFAULT_PATH := "user://update_history.json"
const PATH_ENV := "WAR_UPDATE_HISTORY_PATH"
const VERSION := 1
const MAX_BYTES := 4096
const MAX_COUNTER := JCS.MAX_SAFE_INTEGER - 1
const FIELDS := ["version", "scope", "key_epoch", "sequence", "revocation_floor", "accepted_at"]
static var _refused_paths: Dictionary = {}


static func history_path() -> String:
	var override := OS.get_environment(PATH_ENV)
	return DEFAULT_PATH if override.is_empty() else override


## Stream identity excludes the manifest mirror: moving that document must not
## reset an epoch, sequence, independent revocation floor or accepted clock.
static func scope_for(config: Dictionary) -> String:
	if not UpdateCheck.validate_configuration(config).is_empty():
		return ""
	var key := CryptoKey.new()
	if key.load_from_string(config["root_public_key"], true) != OK:
		return ""
	var scope := {"root": key.save_to_string(true).sha256_text(),
		"channel": config["channel"], "revocation_head_url": config["revocation_head_url"]}
	return str(JCS.canonicalize(scope)["text"]).sha256_text()


static func read_state(path: String, config: Dictionary) -> Dictionary:
	if not _safe_path(path):
		return _read_error("history authority or path is invalid")
	return _state_from_snapshot(path, config, _snapshot(path))


## The authority being parsed is exactly the bounded snapshot being hashed.
## A second read here could mix two versions before a foreign writer restores
## the original bytes, defeating the final identity comparison.
static func _state_from_snapshot(path: String, config: Dictionary, snapshot: Dictionary) -> Dictionary:
	var scope := scope_for(config)
	if scope.is_empty() or not _safe_path(path):
		return _read_error("history authority or path is invalid")
	var path_key := _path_key(path)
	if _refused_paths.has(path_key):
		return _read_error("history path was refused earlier this process")
	if snapshot["identity"] == "":
		return {"error": "", "state": {"version": VERSION, "scope": scope,
			"key_epoch": 0, "sequence": 0, "revocation_floor": 0, "accepted_at": ""}}
	if not str(snapshot["error"]).is_empty():
		return _latch(path_key, snapshot["error"])
	var decoded := UpdateCheck.decode_document(snapshot["raw"])
	if not str(decoded["error"]).is_empty():
		return _latch(path_key, "history document is corrupt or noncanonical")
	var state: Dictionary = decoded["document"]
	var error := _state_error(state, scope)
	if not error.is_empty():
		return _latch(path_key, error)
	return {"error": "", "state": state}


## The hook is a deterministic test seam for foreign writes and lost locks.
## Shipped callers never provide it; fetched content cannot choose a callback.
static func accept(path: String, installed: Dictionary, configuration: Dictionary,
		manifest: Dictionary, head: Dictionary, observed_at: String,
		before_commit: Callable = Callable()) -> Dictionary:
	if not UpdateCheck.is_enabled():
		return _refused("experimental update history is disabled")
	if not _safe_path(path) or not UpdateDecision.is_utc_datetime(observed_at):
		return _refused("history path or observation time is invalid")
	if installed.has("observed_at") and not UpdateDecision.is_utc_datetime(installed["observed_at"]):
		return _refused("verified observation time is invalid")
	if not FileLock.acquire(path):
		return _refused("update history is locked by another acceptance")
	var result := _accept_locked(path, installed, configuration, manifest, head, observed_at, before_commit)
	FileLock.release(path)
	return result


static func _accept_locked(path: String, installed: Dictionary, config: Dictionary,
		manifest: Dictionary, head: Dictionary, observed_at: String,
		before_commit: Callable) -> Dictionary:
	var snapshot := _snapshot(path)
	if not str(snapshot["error"]).is_empty():
		_refused_paths[_path_key(path)] = true
		return _refused(snapshot["error"])
	var identity: String = snapshot["identity"]
	var loaded := _state_from_snapshot(path, config, snapshot)
	if not str(loaded["error"]).is_empty():
		return _refused(loaded["error"])
	var state: Dictionary = loaded["state"]
	var facts := installed.duplicate(true)
	facts["channel"] = config["channel"]
	facts["revocation_head_url"] = config["revocation_head_url"]
	facts["key_certificate_required"] = true
	facts["key_epoch_high_water"] = state["key_epoch"]
	facts["manifest_sequence_high_water"] = state["sequence"]
	# Neither a rollback during the handoff nor an older retained observation
	# can erase a time already used to authenticate this candidate.
	var verified_at: String = installed.get("observed_at", observed_at)
	var acceptance_at := verified_at if verified_at > observed_at else observed_at
	facts["observed_at"] = acceptance_at if acceptance_at > str(state["accepted_at"]) else str(state["accepted_at"])
	var verdict := UpdateTrust.verify_and_decide(facts, manifest, config["root_public_key"], head)
	if not verdict["trusted"]:
		return _refused(str(verdict["error"]))
	var action: Variant = verdict["decision"].get("action")
	if action not in [UpdateDecision.UP_TO_DATE, UpdateDecision.PACK_UPDATE, UpdateDecision.SHELL_UPDATE]:
		return _refused("authenticated update is not eligible: " + str(action))
	if int(manifest["revocation"]["version"]) < int(state["revocation_floor"]):
		return _refused("authenticated revocation list regressed below retained history")
	var next := state.duplicate(true)
	var epoch := int(manifest["key"]["epoch"])
	next["sequence"] = int(manifest["sequence"]) if epoch > int(state["key_epoch"]) else maxi(int(state["sequence"]), int(manifest["sequence"]))
	next["key_epoch"] = epoch
	next["revocation_floor"] = maxi(int(state["revocation_floor"]), maxi(int(head["version_floor"]), int(manifest["revocation"]["version"])))
	next["accepted_at"] = facts["observed_at"]
	var error := _state_error(next, state["scope"])
	if not error.is_empty():
		return _refused(error)
	error = _persist(path, next, identity, config, before_commit)
	if not error.is_empty():
		return _refused(error)
	verdict["history"] = next
	return verdict


static func _persist(path: String, state: Dictionary, identity: String,
		config: Dictionary, before_commit: Callable) -> String:
	var payload: String = JCS.canonicalize(state)["text"]
	PrivateStaging.sweep(path, func(_candidate: String) -> bool: return true)
	var stage := PrivateStaging.write_path(path)
	var file := FileAccess.open(stage, FileAccess.WRITE)
	if file == null:
		return "history cannot be staged"
	file.store_string(payload)
	file.flush()
	var written := file.get_error() == OK
	file.close()
	if not written or not _matches_payload(stage, payload):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(stage))
		return "history staging readback failed"
	if before_commit.is_valid():
		before_commit.call()
	var current := read_state(path, config)
	var current_snapshot := _snapshot(path)
	# Ownership and byte identity are point-in-time checks, matching the other
	# Godot stores. They do not promise an OS-atomic CAS against noncooperators.
	if not str(current["error"]).is_empty() or not str(current_snapshot["error"]).is_empty() or not _matches_payload(stage, payload) or not FileLock.owns(path) or current_snapshot["identity"] != identity:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(stage))
		return "history changed, became unreadable or lost its lock before acceptance"
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(stage), ProjectSettings.globalize_path(path)) != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(stage))
		return "history replacement failed"
	if not _matches_payload(path, payload):
		return "committed history readback failed"
	return ""


## Read and hash the same bounded bytes; a size check before an unbounded hash
## would still admit concurrent growth. Absence and failed reads stay distinct.
static func _snapshot(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"error": "", "identity": "", "raw": PackedByteArray()}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": "history identity cannot be read", "identity": "?", "raw": PackedByteArray()}
	var raw := file.get_buffer(MAX_BYTES + 1)
	var read_error := file.get_error()
	file.close()
	if raw.size() > MAX_BYTES or read_error not in [OK, ERR_FILE_EOF]:
		return {"error": "history bytes are oversized or unreadable", "identity": "?", "raw": PackedByteArray()}
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(raw)
	return {"error": "", "identity": hash.finish().hex_encode(), "raw": raw}


static func _matches_payload(path: String, payload: String) -> bool:
	var snapshot := _snapshot(path)
	return str(snapshot["error"]).is_empty() and snapshot["raw"] == payload.to_utf8_buffer()


static func _state_error(state: Dictionary, scope: String) -> String:
	if state.size() != FIELDS.size():
		return "history fields are missing or unsupported"
	for field: String in FIELDS:
		if not state.has(field):
			return "history field is missing"
	if state["version"] != VERSION or state["version"] is bool:
		return "history schema is unsupported"
	if state["scope"] != scope:
		return "history belongs to another root or revocation stream"
	for field: String in ["key_epoch", "sequence", "revocation_floor"]:
		var value: Variant = state[field]
		if not UpdateDecision.is_int_id(value) or value > MAX_COUNTER:
			return "history counter is outside the exact supported range"
	if state["accepted_at"] == "":
		if state["key_epoch"] != 0 or state["sequence"] != 0 or state["revocation_floor"] != 0:
			return "nonempty history is missing its accepted time"
	elif not UpdateDecision.is_utc_datetime(state["accepted_at"]):
		return "history accepted time is not canonical UTC"
	return ""


static func _safe_path(path: String) -> bool:
	if path.is_empty() or path.length() > 4096 or not (path.begins_with("user://") or path.is_absolute_path()):
		return false
	var key := _path_key(path)
	var absolute := ProjectSettings.globalize_path(path).simplify_path()
	if key.ends_with(".lock") or key.contains(PrivateStaging.WRITE_TMP_SUFFIX) or DirAccess.dir_exists_absolute(absolute):
		return false
	# Reject links at every component, including absent destinations below a
	# linked parent. Comparing only an existing final object misses first boot.
	var component := absolute
	var reached_root := false
	for _index in 128:
		var parent := component.get_base_dir()
		if parent == component or parent.is_empty():
			reached_root = true
			break
		var directory := DirAccess.open(parent)
		if directory == null or directory.is_link(component):
			return false
		component = parent
	if not reached_root:
		return false
	for protected: String in [CharacterStore.DEFAULT_PATH, CharacterStore.save_path(),
			SaveVault.DEFAULT_PATH, SaveVault.vault_path(), BootRecovery.DEFAULT_PATH,
			BootRecovery.recovery_path(), OS.get_environment(UpdateCheck.CONFIG_ENV)]:
		if not protected.is_empty() and (key == _path_key(protected) or key == _path_key(FileLock.path_for(protected))):
			return false
	return true


static func _path_key(path: String) -> String:
	# Conservatively fence case aliases on every platform, including APFS.
	return ProjectSettings.globalize_path(path).simplify_path().to_lower()


static func _latch(path: String, error: String) -> Dictionary:
	_refused_paths[path] = true
	return _read_error(error)


static func _read_error(error: String) -> Dictionary:
	return {"error": error, "state": {}}


static func _refused(error: String) -> Dictionary:
	return {"trusted": false, "error": error, "decision": {}, "manifest": {}, "head": {}}


static func clear_refusals_for_test() -> void:
	_refused_paths.clear()
