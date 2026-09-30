extends SceneTree


func _initialize() -> void:
	var path := OS.get_environment("WAR_VAULT_PATH")
	if path.is_empty():
		push_error("TEST FAIL: the isolated vault path is required")
		quit(1)
		return
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if doc is not Dictionary or int(doc.get("version", -1)) != 5:
		push_error("TEST FAIL: the retained app lost the vault-v5 document")
		quit(1)
		return
	var expected := {
		"weapons": {"future_weapon": {"banked": 9007199254740900, "unbanked": 91}},
		"bloodstain": {"future_weapon": 1},
	}
	var actual: Dictionary = doc.get("mastery", {})
	var weapon: Dictionary = actual.get("weapons", {}).get("future_weapon", {})
	var exact := int(doc.get("quests", {}).get("future_quest", {}).get("arrive", -1)) == 9007199254740991
	exact = exact and int(weapon.get("banked", -1)) == expected.weapons.future_weapon.banked
	exact = exact and int(weapon.get("unbanked", -1)) == expected.weapons.future_weapon.unbanked
	exact = exact and int(actual.get("bloodstain", {}).get("future_weapon", -1)) == 1
	exact = exact and doc.get("discoveries", []).has("starter_cave")
	if not exact:
		push_error("TEST FAIL: the real app boot changed exact progression or dropped its discovery")
		quit(1)
		return
	print("TEST PASS: the retained app preserved quest 9007199254740991, mastery bank 9007199254740900, unbanked 91 and bloodstain 1 after an ordinary boot discovery")
	quit(0)
