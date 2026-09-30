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
	_check(_persist_guarded(_snapshot(1, {}), null) == OK, "absent-vault mastery seed failed")
	_check(SaveVault.load_saved().get("mastery") == _json(_snapshot(1, {})),
		"absent-vault writer lost mastery")
	var old := {
		"version": 4, "attuned": ["future_shrine"], "discoveries": ["future_place"],
		"reward_claims": ["future_reward"], "quests": {"future_quest": {"arrive": 12}},
	}
	_check(SaveVault.save_to(SaveVault.vault_path(), old), "could not seed old-state vault")
	var first := _snapshot(50, {})
	_check(_persist_guarded(first, null) == OK, "first real mastery mutation did not persist")
	var written: Dictionary = SaveVault.load_saved()
	_check(written.get("version") == 5 and written.get("mastery") == _json(first),
		"writer did not originate the complete v5 snapshot")
	for field: String in old:
		if field != "version":
			_check(written.get(field) == _json(old[field]), "mastery write changed %s" % field)
	# Another subsystem writes after the mastery observation. That unrelated
	# progress must survive the mastery transaction's latest-document merge.
	var prior_identity := SaveVault.document_identity(SaveVault.vault_path())
	_check(SaveVault.persist_quests({"future_quest": {"arrive": 20}}), "quest seed failed")
	_check(SaveVault.document_identity(SaveVault.vault_path()) != prior_identity,
		"unrelated quest advance did not change the transaction's byte identity")
	var died := _snapshot(25, {"sword": 25})
	_check(_persist_guarded(died, first) == OK, "death could not replace its exact prior mastery")
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
	_check_large_quest_progress()
	_check_oversized_writes()
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


func _check_large_quest_progress() -> void:
	# Seed literal historical bytes: encoding a parsed float with the same writer
	# under test would hide rounding before the mastery transaction even begins.
	var file := FileAccess.open(SaveVault.vault_path(), FileAccess.WRITE)
	file.store_string('{"version":4,"attuned":[],"discoveries":[],"reward_claims":[],"quests":{"future_quest":{"arrive":9007199254740991}}}')
	file.close()
	var before: Dictionary = SaveVault.load_saved()
	_check(int(before["quests"]["future_quest"]["arrive"]) == 9007199254740991, "literal quest seed was not exact")
	_check(_persist(_snapshot(1, {}), null) == OK, "mastery could not preserve a large quest counter")
	var after: Dictionary = SaveVault.load_saved()
	_check(int(after["quests"]["future_quest"]["arrive"]) == 9007199254740991,
		"mastery serialization rounded unrelated progression")


func _check_oversized_writes() -> void:
	var old := {
		"version": 4, "attuned": [], "discoveries": [], "reward_claims": [], "quests": {},
	}
	_seed_near_limit(old)
	var path := SaveVault.vault_path()
	var before := FileAccess.get_sha256(path)
	_check(_persist(_snapshot(1, {}), null) == ERR_PARAMETER_RANGE_ERROR,
		"oversized mastery was classified as retryable storage trouble")
	_check(FileAccess.get_sha256(path) == before, "oversized mastery changed accepted bytes")
	_check(SaveVault.load_saved() is Dictionary, "size refusal made the accepted vault unreadable")
	var ledger := Mastery.new()
	var writer := MasteryPersistence.new(ledger, null)
	var notices: Array[bool] = []
	writer.saving_failed.connect(func(conflict: bool) -> void: notices.append(conflict))
	ledger.accrue("sword", 1)
	_check(notices == [false], "size refusal did not report session-only mastery")
	_check(FileAccess.get_sha256(path) == before, "size refusal changed the prior vault")
	# Free space in the same accepted document. A permanent refusal must still
	# fence this owner through ticks, later mutations and a clean-exit flush.
	_check(SaveVault.save_to(path, old), "could not restore a smaller accepted vault")
	before = FileAccess.get_sha256(path)
	writer.tick(1000.0)
	writer.flush()
	ledger.accrue("sword", 1)
	writer.tick(1000.0)
	writer.flush()
	_check(FileAccess.get_sha256(path) == before, "oversized owner resumed writing after its refusal")
	# A new waking can save once the prospective document fits again.
	var reopened := Mastery.new()
	var reopened_writer := MasteryPersistence.new(reopened, null)
	reopened.accrue("sword", 2)
	reopened_writer.flush()
	_check(SaveVault.load_saved().get("mastery") == _json(reopened.snapshot()),
		"a new owner could not save after size pressure cleared")
	# Same-width totals fit in the original compact representation; the normal
	# pretty encoding alone can exceed the limit and is permanent trouble too.
	var prior := _snapshot(20, {})
	var compact := old.duplicate(true)
	compact["version"] = 5
	compact["mastery"] = prior
	_seed_near_limit(compact)
	before = FileAccess.get_sha256(path)
	_check(_persist(_snapshot(21, {}), prior) == ERR_PARAMETER_RANGE_ERROR,
		"pretty-encoding growth was classified as retryable storage trouble")
	_check(FileAccess.get_sha256(path) == before, "pretty-encoding refusal changed accepted bytes")


func _seed_near_limit(doc: Dictionary) -> void:
	var seed := doc.duplicate(true)
	seed["comment"] = ""
	var overhead := JSON.stringify(seed, "", true, true).to_utf8_buffer().size()
	seed["comment"] = "x".repeat(SaveVault.MAX_VAULT_BYTES - overhead - 1)
	var bytes := JSON.stringify(seed, "", true, true).to_utf8_buffer()
	_check(bytes.size() == SaveVault.MAX_VAULT_BYTES - 1, "near-limit fixture has the wrong byte size")
	var file := FileAccess.open(SaveVault.vault_path(), FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()
	_check(SaveVault.load_saved() is Dictionary, "near-limit historical fixture was not accepted")


func _snapshot(points: int, stain: Dictionary) -> Dictionary:
	return {"weapons": {"sword": {"banked": 200, "unbanked": points}}, "bloodstain": stain}


func _persist(snapshot: Dictionary, expected: Variant) -> int:
	return SaveVault.new().call("persist_mastery", snapshot, expected)


func _persist_guarded(snapshot: Dictionary, expected: Variant) -> int:
	var identity := SaveVault.document_identity(SaveVault.vault_path())
	SaveVault._last_write_expectation = SaveVault.IDENTITY_UNCHECKED
	var result := _persist(snapshot, expected)
	_check(result == OK, "guarded mastery write failed")
	_check(SaveVault._last_write_expectation == identity,
		"mastery replaced the vault without its original byte identity")
	return result


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
