extends Node
## Pins the Reach atmosphere as one production rig shared by the live world and
## the telegraph readability preview.
##
## Run: godot --headless --path client res://tests/reach_atmosphere_test.tscn

const MAIN_SCRIPT := preload("res://scripts/main.gd")
const PREVIEW_SCRIPT := preload("res://scripts/telegraph_preview.gd")
const BUILDER_CALL := "ReachAtmosphere.build("
const CONSUMERS := [
	"res://scripts/main.gd",
	"res://scripts/telegraph_preview.gd",
]


func _ready() -> void:
	var main := MAIN_SCRIPT.new()
	main.call("_build_environment")
	var preview := PREVIEW_SCRIPT.new()
	preview.call("_build_lighting")

	var main_environment := _environment_from(main)
	var preview_environment := _environment_from(preview)
	if main_environment == null or preview_environment == null:
		main.free()
		preview.free()
		_fail("both consumers must build a WorldEnvironment")
		return

	# One deep comparison covers the whole stored Environment surface, including
	# the nested Sky and ProceduralSkyMaterial. A newly-added shared field joins
	# this assertion automatically instead of needing another hand-maintained
	# property name in the test.
	if _resource_snapshot(main_environment) != _resource_snapshot(preview_environment):
		main.free()
		preview.free()
		_fail("the live world and telegraph preview must build the same Reach atmosphere")
		return

	# The equality above proves today's values. This pins the ownership that
	# prevents tomorrow's drift: both production consumers must delegate to the
	# one builder rather than keep equal hand-copies.
	for path: String in CONSUMERS:
		var source := FileAccess.get_file_as_string(path)
		if source.count(BUILDER_CALL) != 1:
			main.free()
			preview.free()
			_fail("%s must call the shared Reach atmosphere builder exactly once" % path)
			return

	main.free()
	preview.free()
	print("TEST PASS — Main and TelegraphPreview share one complete Reach atmosphere")
	get_tree().quit(0)


func _environment_from(parent: Node) -> Environment:
	var world_environment := parent.get_node_or_null("WorldEnvironment") as WorldEnvironment
	return null if world_environment == null else world_environment.environment


func _resource_snapshot(resource: Resource) -> Dictionary:
	var snapshot := {
		"class": resource.get_class(),
		"properties": {},
	}
	var properties: Dictionary = snapshot["properties"]
	for property: Dictionary in resource.get_property_list():
		if (int(property["usage"]) & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var name := String(property["name"])
		properties[name] = _snapshot_value(resource.get(name))
	return snapshot


func _snapshot_value(value: Variant) -> Variant:
	if value is Resource:
		return _resource_snapshot(value)
	if value is Array:
		var items: Array = []
		for item: Variant in value:
			items.append(_snapshot_value(item))
		return items
	if value is Dictionary:
		var items: Dictionary = {}
		for key: Variant in value:
			items[key] = _snapshot_value(value[key])
		return items
	return value


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
