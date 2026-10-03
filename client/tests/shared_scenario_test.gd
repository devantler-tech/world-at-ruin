extends Node
## Verify the harness fails on sticky assertions and private expectation drift;
## test-owned raw observations must record mutations without judging them.
var _failed := false
var _probe := "user://shared_scenario_probe.process-%d" % OS.get_process_id()

func _ready() -> void:
	for mode: String in ["sticky", "scope", "teardown"]:
		var output: Array = []
		var code := OS.execute(OS.get_executable_path(), ["--headless", "--path",
			ProjectSettings.globalize_path("res://"), "res://tests/persistence_scenario_probe.tscn",
			"--", mode], output, true)
		var log := "\n".join(output)
		_check(code != 0 and log.contains("TEST FAIL") and not log.contains("TEST PASS")
			and not log.contains("SCRIPT ERROR"), mode + " failure was hidden: " + log)
	var observed := PersistenceTestSupport.interposed_write(_probe, "abc", func() -> bool:
		PersistenceTestSupport.write_text(_probe, "abd")
		return false)
	_check(observed["seeded"] and observed["before"] == "abc" and observed["after"] == "abd"
		and observed["result"] == false, "interposition did not expose refused byte mutation")
	var stage := PersistenceTestSupport.foreign_stage(_probe, "foreign", func() -> bool:
		PersistenceTestSupport.remove_file(_probe + ".tmp")
		return true)
	_check(stage["seeded"] and stage["result"] and not stage["exists"],
		"consumed foreign stage was hidden")
	var complete := PersistenceTestSupport.completed_write(_probe, ".stage-", func() -> bool:
		PersistenceTestSupport.write_text(_probe + ".stage-leftover", "leftover")
		return true)
	_check(complete["result"] and complete["stages"] == [_probe.get_file() + ".stage-leftover"],
		"completed write leftover was hidden")
	PersistenceTestSupport.remove_file(_probe)
	PersistenceTestSupport.remove_file(_probe + ".stage-leftover")
	# A suffix-free name consumes no draw; repeated collisions consume three.
	var rng := RandomNumberGenerator.new()
	rng.seed = 123
	var initial := rng.state
	_check(RecipeGeneration.ensure_unique("name", ["x"], rng, []) == "name" and rng.state == initial,
		"collision-free name consumed a draw")
	var reference := RandomNumberGenerator.new()
	reference.seed = 123
	for _i in 3:
		reference.randi_range(0, 0)
	_check(RecipeGeneration.ensure_unique("name", ["x"], rng, ["name", "namex", "namexx"]) == "namexxx"
		and rng.state == reference.state, "repeated collisions changed suffix or draw count")
	if not _failed:
		print("TEST PASS — shared scenario verdicts, raw observations and collision draw boundaries remain observable")
		get_tree().quit(0)

func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error("TEST FAIL — " + message)
		get_tree().quit(1)
