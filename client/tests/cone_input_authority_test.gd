extends Node
## Cone input authority — the client half (issue #1447, ADR 0059).
##
## The server resolves a cone from the shape its ConeTelegraph stores. This
## client paints a cone only when its wire codec and its cast factory both
## accept it, so a cone the server resolved but this tier refused would be an
## invisible danger. The server therefore canonicalises at construction, and
## both wire codecs refuse anything that is not canonical.
##
## This test reads the SAME vectors as server/wire/cone_authority_test.go
## (tests/data/cone_input_authority.json). For each raw input it asserts that
## the wire codec and the cast factory agree with the server's wire boundary,
## and that the canonical cone the server would store is accepted by both.
##
## Run: godot --headless --path client res://tests/cone_input_authority_test.tscn

const FIXTURE := "res://tests/data/cone_input_authority.json"
const CAST_TIME := 1.0

var _failed := false


func _ready() -> void:
	var fixture := _load_fixture()
	if fixture.is_empty():
		get_tree().quit(1)
		return
	if int(fixture["cos_scale"]) != Telegraph.COS_SCALE:
		_fail("vectors cos_scale %d is not Telegraph.COS_SCALE %d" % [int(fixture["cos_scale"]), Telegraph.COS_SCALE])
	var range_mm := int(fixture["range_mm"])
	var cases: Array = fixture["cases"]
	var valid := 0
	var invalid := 0
	for entry: Dictionary in cases:
		var case_name := String(entry["name"])
		var expected := bool(entry["wire_valid"])
		if expected:
			valid += 1
		else:
			invalid += 1
		var facing: Dictionary = entry["facing_mm"]
		var threshold := int(entry["cos_half_scaled"])
		var codec_accepts := WireCodec._validate_cast_shape(_cast(facing, threshold, range_mm)).is_empty()
		if codec_accepts != expected:
			_fail("%s: wire codec accepts raw cone = %s, want %s" % [case_name, codec_accepts, expected])
		var factory_accepts := _factory_builds(facing, threshold, range_mm)
		if factory_accepts != expected:
			_fail("%s: cast factory builds raw cone = %s, want %s" % [case_name, factory_accepts, expected])
		var canonical: Dictionary = entry["canonical_facing_mm"]
		var canonical_threshold := int(entry["canonical_cos_half_scaled"])
		if not WireCodec._validate_cast_shape(_cast(canonical, canonical_threshold, range_mm)).is_empty():
			_fail("%s: wire codec refuses the canonical cone the server sends" % case_name)
		if not _factory_builds(canonical, canonical_threshold, range_mm):
			_fail("%s: cast factory refuses the canonical cone the server resolves" % case_name)
	if valid == 0 or invalid == 0:
		_fail("vectors hold %d valid and %d invalid inputs; both classes are required" % [valid, invalid])

	if _failed:
		get_tree().quit(1)
		return
	print("TEST PASS — cone inputs: wire codec and cast factory agree with the server's boundary (%d vectors)" % cases.size())
	get_tree().quit(0)


func _load_fixture() -> Dictionary:
	var file := FileAccess.open(FIXTURE, FileAccess.READ)
	if file == null:
		_fail("cannot open the shared cone authority vectors %s" % FIXTURE)
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is not Dictionary or not (parsed as Dictionary).has("cases"):
		_fail("%s did not decode to an object with cases" % FIXTURE)
		return {}
	return parsed


## A wire cast dictionary in the shape the codec decodes, for one cone input.
func _cast(facing: Dictionary, threshold: int, range_mm: int) -> Dictionary:
	return {
		"kind": WireCodec.SHAPE_CONE,
		"origin_x": 0, "origin_y": 0, "origin_z": 0,
		"facing_x": int(facing["x"]), "facing_y": int(facing["y"]), "facing_z": int(facing["z"]),
		"outer": range_mm, "inner": 0, "half_width": 0, "cos_half": threshold,
	}


## Whether the client's cast factory builds a cone from these inputs, with the
## server's millimetres converted to metres.
func _factory_builds(facing: Dictionary, threshold: int, range_mm: int) -> bool:
	var heading := Vector3(int(facing["x"]), int(facing["y"]), int(facing["z"])) / 1000.0
	return TelegraphCast.cone(Vector3.ZERO, heading, range_mm / 1000.0, threshold, CAST_TIME) != null


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
