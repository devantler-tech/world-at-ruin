extends Node
## Public identities distinguish missing, unreadable and same-size changed bytes.
var _probe := "user://document_identity_contract_probe.process-%d" % OS.get_process_id()
const ABC := "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
const ABD := "a52d159f262b2c6ddb724a61840befc36eb30c88877a4030b65cbe86298449c9"
var _failed := false

func _ready() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_probe))
	_expect("", "absent")
	_check(PersistenceTestSupport.write_text(_probe, "abc"), "seed failed")
	_expect(ABC, "abc")
	_expect(ABC, "unchanged")
	_check(PersistenceTestSupport.write_text(_probe, "abd"), "same-size edit failed")
	_expect(ABD, "same-size changed bytes")
	var output: Array = []
	_check(OS.execute("chmod", ["000", ProjectSettings.globalize_path(_probe)], output) == 0,
		"permission fixture failed")
	_check(FileAccess.file_exists(_probe), "unreadable fixture must exist")
	_check(FileAccess.get_sha256(_probe).is_empty(), "fixture is still hashable")
	_expect("?", "present but unreadable")
	OS.execute("chmod", ["600", ProjectSettings.globalize_path(_probe)], output)
	PersistenceTestSupport.remove_file(_probe)
	if not _failed:
		print("TEST PASS — all three public stores retain exact byte identities and unreadable refusal")
		get_tree().quit(0)

func _expect(expected: String, stage: String) -> void:
	_check(CharacterStore.document_identity(_probe) == expected, "character " + stage)
	_check(SaveVault.document_identity(_probe) == expected, "vault " + stage)
	_check(BootRecovery.document_identity(_probe) == expected, "recovery " + stage)

func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error("TEST FAIL — " + message)
		get_tree().quit(1)

func _exit_tree() -> void:
	if not FileAccess.file_exists(_probe):
		return
	var output: Array = []
	OS.execute("chmod", ["600", ProjectSettings.globalize_path(_probe)], output)
	PersistenceTestSupport.remove_file(_probe)
