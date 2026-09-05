extends Node
## Economic state cannot use the append-only/max merge suitable for discoveries
## and quests: merging the old stain with reclaimed points duplicates mastery.

var _failed := false
var _save: SaveIsolation


func _ready() -> void:
	if not SaveVault.new().has_method("persist_mastery"):
		_fail("the vault has no conditional complete-mastery writer")
		return
	_save = SaveIsolation.new("user://mastery_writer_probe.json")
	if not _save.begin():
		_fail("save isolation failed")
		return
	SaveVault.clear_refusals_for_test()
	var old := {
		"version": 4, "attuned": ["future_shrine"], "discoveries": ["future_place"],
		"reward_claims": ["future_reward"], "quests": {"future_quest": {"arrive": 12}},
	}
	_check(SaveVault.save_to(SaveVault.vault_path(), old), "could not seed old-state vault")
	var first := _snapshot(50, {})
	_check(_persist(first, null) == OK, "first real mastery mutation did not persist")
	var written: Dictionary = SaveVault.load_saved()
	_check(written.get("version") == 5 and written.get("mastery") == _json(first),
		"writer did not originate the complete v5 snapshot")
	for field: String in old:
		if field != "version":
			_check(written.get(field) == _json(old[field]), "mastery write changed %s" % field)
	# Another subsystem writes after the mastery observation. That unrelated
	# progress must survive the mastery transaction's latest-document merge.
	_check(SaveVault.persist_quests({"future_quest": {"arrive": 20}}), "quest seed failed")
	var died := _snapshot(25, {"sword": 25})
	_check(_persist(died, first) == OK, "death could not replace its exact prior mastery")
	written = SaveVault.load_saved()
	_check(written["quests"] == {"future_quest": {"arrive": 20.0}}, "mastery lost newer quest progress")
	var before := FileAccess.get_sha256(SaveVault.vault_path())
	_check(_persist(_snapshot(75, {}), first) == ERR_ALREADY_IN_USE,
		"stale mastery overwrote another session's death")
	_check(FileAccess.get_sha256(SaveVault.vault_path()) == before, "conflict changed persisted bytes")
	_check(_persist(died, first) == ERR_ALREADY_IN_USE,
		"identical independent outcomes were mistaken for this session's acknowledged write")
	_check(_persist(first, died) == OK, "reclaim did not consume the stain atomically")
	before = FileAccess.get_sha256(SaveVault.vault_path())
	_check(_persist(first, first) == OK, "already-current snapshot was not a no-op")
	_check(FileAccess.get_sha256(SaveVault.vault_path()) == before, "no-op rewrote the vault")
	var invalid := first.duplicate(true)
	invalid["weapons"]["sword"]["banked"] = -100
	_check(_persist(invalid, first) == ERR_INVALID_DATA, "malformed mastery was accepted")
	_check(FileAccess.get_sha256(SaveVault.vault_path()) == before, "invalid state changed the vault")
	# Changing unknown future tracks must conflict too, rather than dropping
	# the newer build's state when this build knows only the sword.
	var foreign := first.duplicate(true)
	foreign["weapons"]["future_weapon"] = {"banked": 100, "unbanked": 3}
	_check(_persist(foreign, first) == OK, "future weapon seed failed")
	_check(_persist(died, first) == ERR_ALREADY_IN_USE, "a stale snapshot dropped future weapon state")
	var file := FileAccess.open(SaveVault.vault_path(), FileAccess.WRITE)
	file.store_string('{"version":999,"mastery":{"future":true}}')
	file.close()
	before = FileAccess.get_sha256(SaveVault.vault_path())
	_check(_persist(first, foreign) == ERR_FILE_UNRECOGNIZED, "future vault was not refused")
	_check(FileAccess.get_sha256(SaveVault.vault_path()) == before, "future vault was replaced")
	_check(_save.real_save_untouched(), "writer test touched real player state")
	_save = null
	if _failed:
		return
	print("TEST PASS — mastery replaces only its observed snapshot and preserves unrelated progression")
	get_tree().quit(0)


func _snapshot(points: int, stain: Dictionary) -> Dictionary:
	return {"weapons": {"sword": {"banked": 200, "unbanked": points}}, "bloodstain": stain}


func _persist(snapshot: Dictionary, expected: Variant) -> int:
	return SaveVault.new().call("persist_mastery", snapshot, expected)


func _json(value: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(value))


func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failed = true
	push_error("TEST FAIL — " + message)
	get_tree().quit(1)


func _exit_tree() -> void:
	if _save != null:
		if not _save.real_save_untouched():
			push_error("TEST FAIL — mastery writer teardown detected real player-state changes")
