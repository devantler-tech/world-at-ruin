extends Node
## Independent literal controls for test-owned ledger and closed-arc observers.

var _paths: Array[String] = []


func _ready() -> void:
	if not _check_mappings() or not _check_arcs():
		_cleanup()
		get_tree().quit(1)
		return
	_cleanup()
	print("TEST PASS — discovery ledgers refuse malformed rows and arc observers include the closing edge")
	get_tree().quit(0)


func _check_mappings() -> bool:
	var path := "user://durable_fixture_%d.tsv" % OS.get_process_id()
	if FileAccess.file_exists(path):
		return _fail("private probe already exists")
	_paths.append(path)
	if not LedgerTestSupport.mappings(path).is_empty():
		return _fail("missing ledger accepted")
	for bytes: String in ["", "# only a comment\n", "no separator\n", "=landmark\n", "id=\n", "id=first\nid=second\n"]:
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(bytes)
		file.close()
		if not LedgerTestSupport.mappings(path).is_empty():
			return _fail("malformed ledger accepted: %s" % bytes)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(" # comment\n second = valley=west \n first = cave \n")
	file.close()
	var got := LedgerTestSupport.mappings(path)
	if got.keys() != ["second", "first"] or got != {"second": "valley=west", "first": "cave"}:
		return _fail("mapping order, whitespace or first-separator semantics changed")
	return true


func _check_arcs() -> bool:
	var probe: Node = load("res://tests/plate_junction_test.gd").new()
	var constant := func(_uv: Vector2) -> float: return 7.0
	if probe.call("_max_scalar_arc_step", Vector2.ZERO, 3, constant) != 0.0:
		probe.free()
		return _fail("constant trace has a step")
	var scalar_index := [0]
	var scalar := func(_uv: Vector2) -> float:
		var values := [0.0, 1.0, -3.0, -15.0]
		var value: float = values[scalar_index[0]]
		scalar_index[0] += 1
		return value
	var scalar_step: float = probe.call("_max_scalar_arc_step", Vector2.ZERO, 3, scalar)
	var vector_index := [0]
	var vector := func(_uv: Vector2) -> PackedFloat64Array:
		var values := [PackedFloat64Array([0, 0]), PackedFloat64Array([1, -2]),
			PackedFloat64Array([1, 3]), PackedFloat64Array([-7, -5])]
		var value: PackedFloat64Array = values[vector_index[0]]
		vector_index[0] += 1
		return value
	var vector_step: float = probe.call("_max_vector_arc_step", Vector2.ZERO, 3, vector)
	probe.free()
	if scalar_step != 12.0 or vector_step != 8.0 or scalar_index[0] != 4 or vector_index[0] != 4:
		return _fail("closing sample or maximum component distance was lost")
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
	return false
