extends Node
## Separate bounded scene: actual game boot and update/recovery facts for the
## reviewed reader-only stature expansion, with all played-state seams isolated.

const PLANNED := "res://tests/data/planned_recipe_v5.json"
var _failed := false
var _save: SaveIsolation
var _main: Node


func _ready() -> void:
	_check(CharacterFactory.RECIPE_VERSION in [4, 5], "only the reviewed reader stage may boot")
	_check(SaveContractStage.refusal_reason() == "", "actual stage remains reviewed")
	if not _failed and CharacterFactory.RECIPE_VERSION == 5:
		_check_update_metadata()
		var planned: Dictionary = CharacterFactory.load_recipe(PLANNED)
		var ordinary: Dictionary = CharacterFactory.load_recipe(CharacterCreator.PRESET_DIR + "wanderer.json")
		await _check_real_boot(planned, ordinary)
	_finish()


func _check_update_metadata() -> void:
	var manifest: Dictionary = UpdateManifest.build(10, "2030-01-01T00:00:00Z", WireCodec.VERSION, WireCodec.VERSION)["manifest"]
	var installed := {"shell_version": DevLog.VERSION, "pack_version": DevLog.VERSION,
		"save_schema": 4, "save_capability": 7, "save_reads_max": 5,
		"protocol": WireCodec.VERSION, "observed_at": "2029-01-01T00:00:00Z"}
	_check(UpdateDecision.decide(installed, manifest)["action"] == UpdateDecision.UP_TO_DATE, "expanded reader accepts its manifest for ordinary saved state")
	installed["pack_version"] = "0.1.0"
	_check(UpdateDecision.decide(installed, manifest)["action"] == UpdateDecision.PACK_UPDATE, "old recipe4 state can accept the reader expansion")
	installed["save_schema"] = 5
	installed["save_capability"] = 8
	_check(UpdateDecision.decide(installed, manifest)["action"] == UpdateDecision.INVALID_MANIFEST, "reader-only publication cannot downstamp pre-existing schema5 state")
	var target := {"version": "0.1.98", "url": "https://updates.example/stature.pck",
		"sha256": "0000000000000000000000000000000000000000000000000000000000000000", "size": 1,
		"read_ceiling": manifest["shell"]["reads_max"], "save_capability": manifest["shell"]["reads_capability_max"],
		"speaks_protocol": manifest["protocol"], "shell_compat": {"min": "0.1.0", "max": "9.0.0"}}
	var old := target.duplicate(true)
	old["version"] = "0.1.99"
	old["read_ceiling"] = 4
	old["save_capability"] = 7
	var state := {"save": {"schema": 5, "capability": 8}, "protocol": manifest["protocol"], "shell_version": DevLog.VERSION}
	var selected := RollbackSelection.select([old, target], state)
	_check(selected["action"] == RollbackSelection.ROLLBACK and selected["version"] == target["version"], "mixed catalogue skips the newer unreadable recipe4 target")
	_check(RollbackSelection.select([old], state)["action"] == RollbackSelection.NO_ELIGIBLE_TARGET, "old catalogue cannot claim expanded-state recovery")


func _check_real_boot(planned: Dictionary, ordinary: Dictionary) -> void:
	for recipe: Dictionary in [ordinary, planned]:
		_save = SaveIsolation.new("user://stature_real_boot_probe.json")
		if not _save.begin():
			_check(false, "stature probe must isolate all persistence seams")
			return
		_main = load("res://scenes/main.tscn").instantiate()
		var main := _main
		if main == null:
			_check(false, "stature probe must boot the actual isolated game")
			return
		var file := FileAccess.open(CharacterStore.save_path(), FileAccess.WRITE)
		file.store_string(JSON.stringify(recipe, "  ", true, true))
		file.close()
		var before := FileAccess.get_file_as_bytes(CharacterStore.save_path())
		add_child(main)
		for _frame in 3:
			await get_tree().process_frame
		_check(main.get("_creator") == null, "existing recipe never opens first-run creator")
		# Observe facts at the actual main -> UpdateCheck boundary, rather than
		# calling a helper that the product might never use. No network can run.
		main.child_entered_tree.connect(func(child: Node) -> void:
			if child is UpdateCheck:
				child.set_script(load("res://tests/stature_update_observer.gd")))
		var vector: Dictionary = CharacterFactory.load_recipe("res://tests/data/update_trust_chain_vector.json")
		var config := {"channel": "live", "manifest_url": "https://127.0.0.1:1/manifest.json",
			"revocation_head_url": "https://127.0.0.1:1/head.json",
			"root_public_key": FileAccess.get_file_as_string(vector["root_public_key_path"])}
		var config_path := "user://stature_check_config_%d.json" % OS.get_process_id()
		file = FileAccess.open(config_path, FileAccess.WRITE)
		file.store_string(JCS.canonicalize(config)["text"])
		file.close()
		var old_enable := OS.get_environment(UpdateCheck.ENABLE_ENV)
		var old_config := OS.get_environment(UpdateCheck.CONFIG_ENV)
		OS.set_environment(UpdateCheck.ENABLE_ENV, "1")
		OS.set_environment(UpdateCheck.CONFIG_ENV, config_path)
		await main.call("_check_updates_after_boot")
		OS.set_environment(UpdateCheck.ENABLE_ENV, old_enable)
		OS.set_environment(UpdateCheck.CONFIG_ENV, old_config)
		PersistenceTestSupport.remove_file(config_path)
		var result: Dictionary = main.get("_update_check_result")
		var facts: Dictionary = result.get("observed_installed", {})
		var expanded := int(recipe["version"]) == 5
		_check(facts.get("save_schema") == (5 if expanded else 4), "actual update entrypoint uses accepted recipe requirement")
		_check(facts.get("save_capability") == (8 if expanded else 7), "actual update entrypoint retains expanded capability requirement")
		_check(facts.get("save_reads_max") == 5, "actual update entrypoint advertises independent reader ceiling")

		var accepted: Dictionary = CharacterStore.load_saved()
		_check(accepted == recipe, "actual boot read preserves every seeded field")
		var expected := CharacterFactory.build(accepted)
		add_child(expected)
		await get_tree().process_frame
		var player := main.get_node("Wanderer") as Player
		var actual_fp := CharacterFactory.fingerprint(player.get("_character_body"))
		var expected_fp := CharacterFactory.fingerprint(expected)
		print("STATURE_BOOT version=%d actual=%s expected=%s" % [recipe["version"], actual_fp, expected_fp])
		_check(actual_fp == expected_fp, "real boot renders the exact saved character")
		expected.free()
		_check(FileAccess.get_file_as_bytes(CharacterStore.save_path()) == before, "boot leaves accepted character bytes intact")
		main.free()
		_main = null
		_check(_save.real_save_untouched(), "stature boot never touches played state")


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)


func _fail(message: String) -> void:
	if is_instance_valid(_main):
		_main.free()
		_main = null
	if _save != null and not _save.real_save_untouched():
		message += " — save isolation breach"
	print("TEST FAIL — " + message)
	get_tree().quit(1)


func _finish() -> void:
	if _failed:
		_fail("stature reader boot")
		return
	if _save != null and not _save.real_save_untouched():
		_fail("stature reader boot isolation")
		return
	print("TEST PASS — stature reader boot")
	get_tree().quit(0)
