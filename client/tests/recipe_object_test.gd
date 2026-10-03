extends Node
## Invalid inputs exercise both public loaders in children, so expected engine
## diagnostics cannot hide an unexpected error in the parent regression harness.
var _probe := "user://recipe_object_contract_probe.json.process-%d" % OS.get_process_id()
var _failed := false

func _ready() -> void:
	var object := {"probe": {"value": 7}}
	PersistenceTestSupport.write_text(_probe, JSON.stringify(object))
	for value: Variant in [CharacterFactory.load_recipe(_probe), CreatureFactory.load_recipe(_probe)]:
		_check(value is Dictionary and value.size() == 1 and value.get("probe") is Dictionary
			and value["probe"].size() == 1 and float(value["probe"].get("value", -1)) == 7.0,
			"recipe object changed")
	for kind in ["character", "creature"]:
		var owner := "CharacterFactory" if kind == "character" else "CreatureFactory"
		for raw in ["{", "[]", "17", "true", "\"text\"", "null"]:
			PersistenceTestSupport.write_text(_probe, raw)
			_child(kind, owner + ": recipe " + _probe + " is not a JSON object")
		PersistenceTestSupport.remove_file(_probe)
		_child(kind, owner + ": cannot open recipe " + _probe)
	if not _failed:
		print("TEST PASS — both recipe loaders retain object-only results and owner diagnostics")
		get_tree().quit(0)

func _child(kind: String, expected: String) -> void:
	var output: Array = []
	var code := OS.execute(OS.get_executable_path(), ["--headless", "--path",
		ProjectSettings.globalize_path("res://"), "--script", "res://tests/recipe_object_probe.gd",
		"--", kind, _probe], output, true)
	var log := "\n".join(output)
	_check(code == 0 and log.contains("RECIPE_NULL") and log.contains(expected)
		and not log.contains("RECIPE_NON_NULL") and not log.contains("SCRIPT ERROR"),
		"wrong refusal or diagnostic: " + log)

func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error("TEST FAIL — " + message)
		get_tree().quit(1)

func _exit_tree() -> void:
	PersistenceTestSupport.remove_file(_probe)
