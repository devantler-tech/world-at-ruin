extends Node
## A transaction in one subsystem must preserve another subsystem's exact
## historical counters, including JSON's largest supported integer.

const MAX_POINTS := 9007199254740991
const HISTORICAL_VAULT := '{"version":4,"attuned":[],"discoveries":[],"reward_claims":[],"quests":{"future_quest":{"arrive":9007199254740991}}}'

var _failed := false
var _save: SaveIsolation


func _ready() -> void:
	_save = SaveIsolation.new("user://vault_precision_probe.json")
	if not _save.begin():
		_fail("save isolation failed")
		return
	SaveVault.clear_refusals_for_test()
	# Literal bytes avoid passing the fixture through the serializer under test.
	var file := FileAccess.open(SaveVault.vault_path(), FileAccess.WRITE)
	file.store_string(HISTORICAL_VAULT)
	file.close()
	_check_counter("literal historical save")
	_check(SaveVault.persist_attunement("new_shrine"), "attunement write failed")
	_check_counter("attunement")
	_check(SaveVault.persist_discoveries(["wardens_shrine"]), "discovery write failed")
	_check_counter("discovery")
	_check(SaveVault.persist_reward_claims(["wardens_shrine"]), "reward claim write failed")
	_check_counter("reward claim")
	_check(SaveVault.persist_quests({"other_quest": {"arrive": 1}}), "quest write failed")
	_check_counter("unrelated quest")
	var stored: Dictionary = SaveVault.load_saved()
	_check(int(stored["version"]) == 4, "precision repair advanced the writer contract")
	_check(stored["attuned"] == ["new_shrine"] and stored["discoveries"] == ["wardens_shrine"]
		and stored["reward_claims"] == ["wardens_shrine"]
		and int(stored["quests"]["other_quest"]["arrive"]) == 1,
		"preservation discarded the actual mutations")
	_check(_save.real_save_untouched(), "precision test touched real player state")
	_save = null
	if _failed:
		return
	print("TEST PASS — every progression writer preserves exact historical quest counters")
	get_tree().quit(0)


func _check_counter(stage: String) -> void:
	var stored = SaveVault.load_saved()
	if stored is not Dictionary:
		_fail(stage + " produced an unreadable vault")
		return
	_check(int(stored["quests"]["future_quest"]["arrive"]) == MAX_POINTS,
		stage + " rounded unrelated historical progress")


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
			push_error("TEST FAIL — precision teardown detected real player-state changes")
