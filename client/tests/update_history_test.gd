extends Node
## Durable authority is read inside the real locked acceptance boundary.
var _history: GDScript
var _path := "user://update_history_probe.process-%d.json" % OS.get_process_id()
var _config: Dictionary
var _installed: Dictionary
var _manifest: Dictionary
var _head: Dictionary
var _before_enabled := ""


func _ready() -> void:
	_before_enabled = OS.get_environment("WAR_UPDATE_CHECK")
	OS.set_environment("WAR_UPDATE_CHECK", "1")
	if not FileAccess.file_exists("res://scripts/shell/update_history.gd"):
		_fail("durable update history is missing")
		return
	_history = load("res://scripts/shell/update_history.gd")
	var vector: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/data/update_trust_chain_vector.json"))
	_config = {"channel": "live", "manifest_url": "https://updates.worldatruin.example/live/manifest.json",
		"revocation_head_url": vector["revocation_head"]["head_url"],
		"root_public_key": FileAccess.get_file_as_string(vector["root_public_key_path"])}
	_installed = vector["installed"]
	_manifest = vector["manifest"]
	_head = vector["revocation_head"]
	_clean()
	for malformed: String in ["01", "+1", "-1", "0", "1 0", "1\n02", "1\n+2", "2", "1\n1"]:
		if not _reader_versions(malformed).is_empty():
			_fail("noncanonical or noncontiguous history ledger was accepted: " + malformed)
			return
	if _reader_versions(" # reader versions\n \t1\t \n") != [1]:
		_fail("canonical history version with surrounding whitespace was refused")
		return
	for alias: String in ["01", "+1", "-1", "0", " 1", "1 "]:
		if _registered_fixture_number(alias, [1]):
			_fail("noncanonical history fixture alias was accepted: " + alias)
			return
	var fixture_error := _historical_fixtures_error()
	if not fixture_error.is_empty():
		_fail(fixture_error)
		return
	var accepted: Dictionary = _accept()
	if not accepted.get("trusted", false):
		_fail("fresh authenticated history was refused: " + str(accepted.get("error")))
		return
	var read: Dictionary = _history.read_state(_path, _config)
	var state: Dictionary = read["state"]
	# A transient foreign replacement cannot separate the hashed authority from
	# the parsed authority, even when the original bytes are later restored.
	var captured: Dictionary = _history._snapshot(_path)
	var lowered := state.duplicate(true)
	lowered["sequence"] = 1
	_seed(lowered)
	var captured_read: Dictionary = _history._state_from_snapshot(_path, _config, captured)
	_seed(state)
	if captured_read["state"]["sequence"] != 42:
		_fail("acceptance parsed a different history than its captured identity")
		return
	if state.get("key_epoch") != 7 or state.get("sequence") != 42 or state.get("revocation_floor") != 4 or state.get("accepted_at") != _installed["observed_at"]:
		_fail("authenticated counters or accepted time were not retained")
		return
	# A current signing key cannot replay a lower sequence in its own epoch.
	state["sequence"] = 43
	_seed(state)
	if not _refuses_unchanged():
		_fail("signed manifest replay reset the retained sequence")
		return
	# Rotation starts a new sequence line, never a new revocation/time line.
	state["key_epoch"] = 6
	state["sequence"] = 999
	_seed(state)
	if not _accept().get("trusted", false) or _history.read_state(_path, _config)["state"]["sequence"] != 42:
		_fail("authenticated key rotation did not reset only the sequence line")
		return
	state = _history.read_state(_path, _config)["state"]
	state["key_epoch"] = 8
	_seed(state)
	if not _refuses_unchanged():
		_fail("superseded signing epoch was accepted")
		return
	state["key_epoch"] = 7
	state["revocation_floor"] = 5
	_seed(state)
	if not _refuses_unchanged():
		_fail("independent revocation floor regressed across a launch")
		return
	state["revocation_floor"] = 4
	state["accepted_at"] = "2030-02-02T00:00:00Z"
	_seed(state)
	if not _refuses_unchanged():
		_fail("clock rollback resurrected expired signed evidence")
		return
	state["accepted_at"] = "2030-01-20T00:00:00Z"
	_seed(state)
	if not _accept().get("trusted", false) or _history.read_state(_path, _config)["state"]["accepted_at"] != state["accepted_at"]:
		_fail("accepted observation time regressed")
		return
	var old := FileAccess.get_sha256(_path)
	var migration := _config.duplicate(true)
	migration["manifest_url"] = "https://updates.worldatruin.example/live/new-manifest.json"
	if not _history.read_state(_path, migration)["error"].is_empty() or FileAccess.get_sha256(_path) != old:
		_fail("manifest endpoint migration reset stream history")
		return
	# Valid crypto is insufficient when the decision would strand the save.
	var incompatible := _installed.duplicate(true)
	incompatible["save_capability"] = 999
	var refused: Dictionary = _history.accept(_path, incompatible, _config, _manifest, _head, _installed["observed_at"])
	if refused.get("trusted", true) or FileAccess.get_sha256(_path) != old:
		_fail("ineligible signed advice advanced durable authority")
		return
	# A foreign, readable write between staging and replacement is preserved.
	var foreign := state.duplicate(true)
	foreign["sequence"] = 100
	refused = _history.accept(_path, _installed, _config, _manifest, _head, _installed["observed_at"], func() -> void: _seed(foreign))
	if refused.get("trusted", true) or _history.read_state(_path, _config)["state"]["sequence"] != 100:
		_fail("acceptance replaced a foreign history write")
		return
	_clean()
	# Losing the actual lock refuses a commit even if destination bytes match.
	refused = _history.accept(_path, _installed, _config, _manifest, _head, _installed["observed_at"], func() -> void: FileLock.remove_dir(FileLock.path_for(_path)))
	if refused.get("trusted", true) or FileAccess.file_exists(_path):
		_fail("lost lock admitted unpersisted trust")
		return
	_clean()
	if not _accept().get("trusted", false):
		_fail("stage-corruption control could not establish prior history")
		return
	old = FileAccess.get_sha256(_path)
	refused = _history.accept(_path, _installed, _config, _manifest, _head, _installed["observed_at"], _corrupt_stage)
	if refused.get("trusted", true) or FileAccess.get_sha256(_path) != old:
		_fail("corrupt private stage replaced retained history")
		return
	# Future/corrupt documents latch read-only even if their file later vanishes.
	var future := state.duplicate(true)
	future["version"] = 99
	var malformed: Array[String] = [str(JCS.canonicalize(future)["text"]), '{broken', "x".repeat(_history.MAX_BYTES + 1)]
	var unknown := state.duplicate(true)
	unknown["unsupported"] = true
	malformed.append(str(JCS.canonicalize(unknown)["text"]))
	for counter: String in ["key_epoch", "sequence", "revocation_floor"]:
		var outside := state.duplicate(true)
		outside[counter] = 9007199254740992
		malformed.append(str(JCS.canonicalize(outside)["text"]))
	for bytes: String in malformed:
		_clean()
		_write(bytes)
		old = FileAccess.get_sha256(_path)
		if _history.read_state(_path, _config)["error"].is_empty() or FileAccess.get_sha256(_path) != old:
			_fail("unreadable history was normalized or treated as fresh")
			return
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_path))
		if _accept().get("trusted", true) or FileAccess.file_exists(_path):
			_fail("history refusal latch reset after file removal")
			return
	_clean()
	var deep := ProjectSettings.globalize_path(_path) + ".deep"
	var deepest := deep + "/d".repeat(130)
	if DirAccess.make_dir_recursive_absolute(deepest) != OK:
		_fail("deep-path refusal control could not start")
		return
	var deep_read: Dictionary = _history.read_state(deepest + "/history.json", _config)
	var component := deepest
	while component.begins_with(deep):
		DirAccess.remove_absolute(component)
		component = component.get_base_dir()
	if deep_read.get("error") != "history authority or path is invalid":
		_fail("incomplete ancestry inspection admitted a history path")
		return
	var alias := "user://CHARACTER.json"
	refused = _history.accept(alias, _installed, _config, _manifest, _head, _installed["observed_at"])
	if refused.get("error") != "history path or observation time is invalid":
		_fail("case alias of player state reached history acceptance")
		return
	if not _accept().get("trusted", false):
		_fail("link control could not establish prior history")
		return
	alias = _path + ".alias"
	var directory := DirAccess.open("user://")
	if directory.create_link(ProjectSettings.globalize_path(_path), ProjectSettings.globalize_path(alias)) != OK:
		_fail("native history symlink control could not start")
		return
	var linked: Dictionary = _history.read_state(alias, _config)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(alias))
	if linked.get("error") != "history authority or path is invalid":
		_fail("history symlink reached document parsing")
		return
	_clean()
	if not _accept().get("trusted", false):
		_fail("isolated path did not recover between test cases")
		return
	var other := _config.duplicate(true)
	other["revocation_head_url"] = "https://updates.worldatruin.example/other/head.json"
	if _history.read_state(_path, other)["error"].is_empty():
		_fail("another revocation stream reused this history")
		return
	_clean()
	OS.set_environment("WAR_UPDATE_CHECK", _before_enabled)
	print("TEST PASS — durable update trust retains epochs, sequences, revocation and time; unreadable and concurrent evidence stays intact")
	get_tree().quit(0)


func _historical_fixtures_error() -> String:
	var ledger_path := "res://tests/data/shipped_update_history_versions.txt"
	if not FileAccess.file_exists(ledger_path):
		return "update-history reader ledger is missing"
	var versions := _reader_versions(FileAccess.get_file_as_string(ledger_path))
	if versions.is_empty() or versions[-1] != _history.VERSION:
		return "update-history reader and ledger disagree"
	var directory := DirAccess.open("res://tests/data")
	for name: String in directory.get_files():
		if name.begins_with("golden_update_history_v") and name.ends_with(".json"):
			var number := name.trim_prefix("golden_update_history_v").trim_suffix(".json")
			if not _registered_fixture_number(number, versions):
				return "unregistered historical update-history fixture"
	for version: int in versions:
		var fixture := "res://tests/data/golden_update_history_v%d.json" % version
		if not FileAccess.file_exists(fixture):
			return "registered update-history version has no historical fixture"
		var raw := FileAccess.get_file_as_string(fixture)
		_write(raw)
		var before := FileAccess.get_sha256(_path)
		var loaded: Dictionary = _history.read_state(_path, _config)
		if not loaded["error"].is_empty() or loaded["state"]["version"] != version or FileAccess.get_sha256(_path) != before:
			return "historical update history became unreadable or churned on load: " + str(loaded["error"])
	_clean()
	return ""


func _reader_versions(text: String) -> Array[int]:
	var versions: Array[int] = []
	for line: String in text.split("\n"):
		var value := line.strip_edges()
		if value.is_empty() or value.begins_with("#"):
			continue
		if not value.is_valid_int() or value != str(int(value)) or int(value) != versions.size() + 1:
			return []
		versions.append(int(value))
	return versions


func _registered_fixture_number(number: String, versions: Array[int]) -> bool:
	return number.is_valid_int() and number == str(int(number)) and int(number) in versions


func _accept() -> Dictionary:
	return _history.accept(_path, _installed, _config, _manifest, _head, _installed["observed_at"])


func _refuses_unchanged() -> bool:
	var before := FileAccess.get_sha256(_path)
	var result := _accept()
	return not result.get("trusted", true) and FileAccess.get_sha256(_path) == before


func _seed(state: Dictionary) -> void:
	_write(JCS.canonicalize(state)["text"])


func _write(text: String) -> void:
	var file := FileAccess.open(_path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _corrupt_stage() -> void:
	for entry: String in DirAccess.get_files_at(_path.get_base_dir()):
		if entry.begins_with(_path.get_file() + PrivateStaging.WRITE_TMP_SUFFIX):
			var file := FileAccess.open(_path.get_base_dir().path_join(entry), FileAccess.WRITE)
			file.store_string("{broken")
			file.close()


func _clean() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_path))
	FileLock.remove_dir(FileLock.path_for(_path))
	FileLock.clear_for_test()
	if _history != null:
		_history.clear_refusals_for_test()


func _fail(message: String) -> void:
	_clean()
	OS.set_environment("WAR_UPDATE_CHECK", _before_enabled)
	print("TEST FAIL: " + message)
	get_tree().quit(1)
