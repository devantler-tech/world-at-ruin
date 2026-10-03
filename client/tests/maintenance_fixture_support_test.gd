extends Node
## Literal refusal controls for the extracted fixture observations. The
## consumer scenes separately retain the historical gameplay/state assertions.

var _paths: Array[String] = []


func _ready() -> void:
	if not _check_stream_refusals():
		return
	if not _check_recipe_observation():
		return
	if not _check_edge_directions():
		return
	if not _check_probe_cleanup():
		return
	_cleanup()
	print("TEST PASS — fixture observations reject malformed anchors, preserve recipe fields and edge directions, and clean only each caller's probe")
	get_tree().quit(0)


func _check_stream_refusals() -> bool:
	var path := _private_path("stream")
	for control: Array in [
		["", "empty anchor"],
		["[]", "fixture %s did not parse as a JSON object" % path],
		["{", "fixture %s did not parse as a JSON object" % path],
		["{}", "missing stream"],
		['{"stream":[]}', "missing stream"],
		['{"stream":{"frames":[],"end_state":{}}}', "fixture stream has no frames"],
		['{"stream":{"frames":{},"end_state":{}}}', "fixture stream has no frames"],
		['{"stream":{"frames":[1],"end_state":[]}}', "fixture stream has no end_state"],
	]:
		if not _write(path, control[0]):
			return false
		var observed := StreamFixtureSupport.load_stream(path, "empty anchor", "missing stream")
		if observed.get("problem") != control[1] or observed.has("stream"):
			return _fail("stream refusal changed for %s: %s" % [control[0], observed])
	var bytes := '{"stream":{"frames":[{"hex":"00","unknown":"kept"}],"end_state":{"tick":"nine"},"unknown":"eleven"}}'
	if not _write(path, bytes):
		return false
	var result := StreamFixtureSupport.load_stream(path, "empty anchor", "missing stream")
	if result.get("problem") != "" or JSON.stringify(result.get("stream")) != (
		'{"end_state":{"tick":"nine"},"frames":[{"hex":"00","unknown":"kept"}],"unknown":"eleven"}'
	):
		return _fail("fixture observer changed the accepted stream: %s" % result)
	return true


func _check_recipe_observation() -> bool:
	var path := _private_path("recipe")
	for bytes: String in ["", "null", "[]", "{"]:
		if not _write(path, bytes):
			return false
		var refused := LocomotionTestSupport.recipe_fixture(path)
		if refused.get("problem") != "could not load %s" % path or refused.has("recipe"):
			return _fail("recipe refusal changed: %s" % refused)
	if not _write(path, '{"unknown":{"kept":["third","first"]},"version":"future"}'):
		return false
	var observed := LocomotionTestSupport.recipe_fixture(path)
	if observed.get("problem") != "" or JSON.stringify(observed.get("recipe")) != (
		'{"unknown":{"kept":["third","first"]},"version":"future"}'
	):
		return _fail("recipe observation changed caller-owned fields: %s" % observed)
	return true


func _check_edge_directions() -> bool:
	for reversed: bool in [false, true]:
		var a := Vector2(9, 19) if reversed else Vector2(11, 19)
		var b := Vector2(11, 19) if reversed else Vector2(9, 19)
		var edge := PlateProbeSupport.edge(a, b, Vector2(10, 20))
		var tangent := Vector2.RIGHT if reversed else Vector2.LEFT
		if edge[&"mid"] != Vector2(10, 19) or edge[&"outward"] != Vector2(0, -1) or edge[&"along"] != tangent:
			return _fail("edge direction changed with winding or translation: %s" % edge)
	return true


func _check_probe_cleanup() -> bool:
	for scene_name: String in ["character_persistence", "save_fixture_guard", "save_vault_guard"]:
		var script: Script = load("res://tests/%s_test.gd" % scene_name)
		var probe: String = script.get_script_constant_map()["PROBE"]
		if FileAccess.file_exists(probe):
			return _fail("caller probe already exists; refusing to overwrite it: %s" % probe)
		_paths.append(probe)
		var sibling := _private_path(scene_name + "_sibling")
		if not _write(probe, "test-owned probe") or not _write(sibling, "retained sibling"):
			return false
		var caller: Node = script.new()
		caller.call("_cleanup_probe")
		caller.call("_cleanup_probe")
		caller.free()
		if FileAccess.file_exists(probe) or FileAccess.get_file_as_string(sibling) != "retained sibling":
			return _fail("caller cleanup left its probe or removed a sibling: %s" % scene_name)
	return true


func _private_path(label: String) -> String:
	var path := "user://maintenance_fixture_%d_%s.json" % [OS.get_process_id(), label]
	_paths.append(path)
	return path


func _write(path: String, bytes: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _fail("could not seed test-owned fixture: %s" % path)
	file.store_string(bytes)
	file.close()
	return true


func _cleanup() -> void:
	for path in _paths:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _exit_tree() -> void:
	_cleanup()


func _fail(message: String) -> bool:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
	return false
