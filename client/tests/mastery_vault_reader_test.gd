extends Node
## Reader-expansion contract for vault-v5 weapon mastery (issue #655).
##
## This release may READ and APPLY the complete mastery snapshot while every
## production vault writer remains capped at v4/capability 6. The split is the
## rollback gate: a later writer can activate only after this reader ships.

const JSON_SAFE_MAX := 9_007_199_254_740_991

var _failed := false


func _ready() -> void:
	_check(SaveVault.VAULT_VERSION == 4,
		"the expansion build started writing vault v5")
	_check(SaveVault.VAULT_READ_VERSION == 5,
		"the expansion build does not advertise vault-v5 reads")
	_check(UpdateManifest.SAVE_CAPABILITY_WRITES == 6,
		"the expansion build advanced the production save writer")
	_check(UpdateManifest.SAVE_CAPABILITY_READS == 7,
		"the expansion build does not advertise mastery read capability 7")
	if _failed:
		return

	var snapshot := _snapshot()
	var vault := _vault(snapshot)
	_check(SaveVault.validate(vault) == "",
		"the vault reader refused the valid mastery snapshot: %s" % SaveVault.validate(vault))
	if _failed:
		return

	var mastery := Mastery.new()
	if not mastery.has_method("restore"):
		_fail("Mastery has no reader application path for a retained v5 snapshot")
		return
	_check(bool(mastery.call("restore", snapshot)),
		"Mastery refused the vault-v5 snapshot after SaveVault accepted it")
	_check(mastery.weapons() == ["future_blade", "staff"],
		"restore did not preserve stable future weapon ids")
	_check(mastery.banked("future_blade") == 200,
		"restore changed the banked ratchet floor")
	_check(mastery.unbanked("future_blade") == 37,
		"restore changed the at-risk current bar")
	_check(mastery.banked("staff") == 0 and mastery.unbanked("staff") == 75,
		"restore lost an independent weapon track")
	_check(mastery.bloodstain() == {"future_blade": 12},
		"restore lost or changed the one standing bloodstain")
	if _failed:
		return

	# Restore owns a deep copy: mutating the parsed vault after boot may not edit
	# the live progression ledger behind its API.
	snapshot["weapons"]["future_blade"]["banked"] = 0
	snapshot["bloodstain"]["future_blade"] = 99
	_check(mastery.banked("future_blade") == 200,
		"the live mastery ledger aliases the parsed vault track")
	_check(mastery.bloodstain() == {"future_blade": 12},
		"the live mastery ledger aliases the parsed vault bloodstain")

	var before_weapons := mastery.weapons()
	var before_banked := mastery.banked("future_blade")
	var before_unbanked := mastery.unbanked("future_blade")
	var before_stain := mastery.bloodstain()
	var invalid_restore := _snapshot()
	invalid_restore["weapons"]["future_blade"]["banked"] = -100
	_check(not bool(mastery.call("restore", invalid_restore)),
		"Mastery restored a snapshot with a negative banked floor")
	_check(mastery.weapons() == before_weapons
			and mastery.banked("future_blade") == before_banked
			and mastery.unbanked("future_blade") == before_unbanked
			and mastery.bloodstain() == before_stain,
		"a refused restore partially mutated live mastery")
	if _failed:
		return

	_check_invalid_shapes()
	_check_reader_only_writeback()
	if _failed:
		return

	print("TEST PASS — vault-v5 mastery reads and applies complete state while every production writer remains on v4/capability 6")
	get_tree().quit(0)


func _check_invalid_shapes() -> void:
	var missing_mastery := _vault(_snapshot())
	missing_mastery.erase("mastery")
	if SaveVault.validate(missing_mastery).is_empty():
		_fail("vault validation accepted v5 without its complete mastery snapshot")
		return
	var cases := {
		"mastery is not an object": [],
		"missing weapons": {"bloodstain": {}},
		"missing bloodstain": {"weapons": {}},
		"unknown mastery field": {"weapons": {}, "bloodstain": {}, "rank": 1},
		"empty weapon id": {"weapons": {"": {"banked": 0, "unbanked": 1}}, "bloodstain": {}},
		"track is not an object": {"weapons": {"sword": 7}, "bloodstain": {}},
		"missing banked": {"weapons": {"sword": {"unbanked": 1}}, "bloodstain": {}},
		"missing unbanked": {"weapons": {"sword": {"banked": 0}}, "bloodstain": {}},
		"unknown track field": {"weapons": {"sword": {"banked": 0, "unbanked": 1, "level": 2}}, "bloodstain": {}},
		"negative banked": {"weapons": {"sword": {"banked": -100, "unbanked": 1}}, "bloodstain": {}},
		"fractional banked": {"weapons": {"sword": {"banked": 100.5, "unbanked": 1}}, "bloodstain": {}},
		"unsafe banked": {"weapons": {"sword": {"banked": JSON_SAFE_MAX + 1, "unbanked": 1}}, "bloodstain": {}},
		"partial banked step": {"weapons": {"sword": {"banked": 101, "unbanked": 1}}, "bloodstain": {}},
		"negative unbanked": {"weapons": {"sword": {"banked": 100, "unbanked": -1}}, "bloodstain": {}},
		"full unbanked bar": {"weapons": {"sword": {"banked": 100, "unbanked": Mastery.BANK_STEP}}, "bloodstain": {}},
		"bloodstain is not an object": {"weapons": {}, "bloodstain": []},
		"empty bloodstain id": {"weapons": {"sword": {"banked": 0, "unbanked": 0}}, "bloodstain": {"": 1}},
		"untracked bloodstain weapon": {"weapons": {}, "bloodstain": {"sword": 1}},
		"zero bloodstain": {"weapons": {"sword": {"banked": 0, "unbanked": 0}}, "bloodstain": {"sword": 0}},
		"fractional bloodstain": {"weapons": {"sword": {"banked": 0, "unbanked": 0}}, "bloodstain": {"sword": 1.5}},
		"unsafe bloodstain": {"weapons": {"sword": {"banked": 0, "unbanked": 0}}, "bloodstain": {"sword": JSON_SAFE_MAX + 1}},
		"bloodstain fills a bar": {"weapons": {"sword": {"banked": 0, "unbanked": 0}}, "bloodstain": {"sword": Mastery.BANK_STEP}},
	}
	for label: String in cases:
		var reason := SaveVault.validate(_vault(cases[label]))
		if reason.is_empty():
			_fail("vault validation accepted malformed mastery: %s" % label)
			return


func _check_reader_only_writeback() -> void:
	var original_snapshot := _snapshot()
	var expanded := _vault(original_snapshot)
	var ordinary_writes := [
		SaveVault.attune(expanded, "future_shrine"),
		SaveVault.record_discoveries(expanded, ["starter_cave"]),
		SaveVault.record_reward_claims(expanded, ["wardens_shrine"]),
		SaveVault.record_quests(expanded, {"future_quest": {"future_objective": 12}}),
	]
	for written: Dictionary in ordinary_writes:
		if int(written.get("version", -1)) != 5 \
				or written.get("mastery", {}) != original_snapshot:
			_fail("an ordinary older writer dropped or changed already-present v5 mastery: %s"
				% str(written))
			return

	var old_writes := [
		SaveVault.attune(SaveVault.empty(), "future_shrine"),
		SaveVault.record_discoveries(SaveVault.empty(), ["starter_cave"]),
		SaveVault.record_quests(SaveVault.empty(), {"future_quest": {"future_objective": 1}}),
	]
	for written: Dictionary in old_writes:
		if written.has("mastery") or int(written.get("version", -1)) > SaveVault.VAULT_VERSION:
			_fail("an old-state production writer originated reader-only mastery: %s" % str(written))
			return


func _snapshot() -> Dictionary:
	return {
		"weapons": {
			"future_blade": {"banked": 200, "unbanked": 37},
			"staff": {"banked": 0, "unbanked": 75},
		},
		"bloodstain": {"future_blade": 12},
	}


func _vault(snapshot: Variant) -> Dictionary:
	return {
		"version": 5,
		"comment": "vault-v5 mastery reader probe",
		"attuned": ["wardens_shrine"],
		"discoveries": ["starter_cave", "wardens_shrine"],
		"reward_claims": ["wardens_shrine"],
		"quests": {"future_quest": {"future_objective": 11}},
		"mastery": snapshot,
	}


func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	if _failed:
		return
	_failed = true
	push_error("TEST FAIL — " + message)
	get_tree().quit(1)
