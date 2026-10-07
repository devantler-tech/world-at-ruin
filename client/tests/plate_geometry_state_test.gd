extends Node
## The GPU instrument's shader-only arm must not silently draw new cosmetics.

const INSTRUMENT := "res://tools/plate_geometry_budget.gd"


func _ready() -> void:
	var script := load(INSTRUMENT) as GDScript
	var instrument: Node = script.new()
	if not instrument.has_method(&"_set_measurement_state"):
		_fail("the shader-only instrument has no explicit cosmetic visibility boundary")
		instrument.free()
		return
	OS.set_environment("WAR_GROUND_PLATES", "1")
	var world := WorldGen.new()
	add_child(world)
	OS.unset_environment("WAR_GROUND_PLATES")
	instrument.set(&"_world", world)
	var top := world.get_node(WorldGen.GROUND_PLATES_NODE) as MeshInstance3D
	var rubble := world.get_node(WorldGen.GROUND_PLATE_RUBBLE_NODE) as MultiMeshInstance3D
	var material := world.get(&"_terrain_material") as ShaderMaterial
	instrument.call(&"_set_measurement_state", true, false)
	if top.visible or rubble.visible \
			or material.get_shader_parameter("plates_enabled") != true:
		_fail("shader-only measurement draws geometry or hides the shader path")
		instrument.free()
		return
	instrument.call(&"_set_measurement_state", true, true)
	if not top.visible or not rubble.visible \
			or material.get_shader_parameter("plates_enabled") != true:
		_fail("the full opt-in measurement omits part of the actual treatment")
		instrument.free()
		return
	instrument.call(&"_set_measurement_state", false, false)
	if top.visible or rubble.visible \
			or material.get_shader_parameter("plates_enabled") != false:
		_fail("the off measurement retains preview pixels")
		instrument.free()
		return
	instrument.free()
	print("TEST PASS: plate budget states — shader-only hides tops and rubble, full treatment includes both, off draws neither")
	get_tree().quit(0)


func _fail(message: String) -> void:
	print("TEST FAIL: " + message)
	get_tree().quit(1)
