extends Node
## Contract test for #556's first-run backdrop clock pin.
##
## The creator is still while the live world behind it is not: foliage wind
## reads shader TIME, and several world systems advance from process delta.
## First-run capture must pin those scenery clocks after the player has booted
## normally but before the first shutter. Other scenarios keep ordinary motion.
##
## Loaded dynamically so the RED state reports the missing contract rather
## than failing to parse before it can explain what is absent.

const FRAME_CAPTURE_PATH := "res://tools/frame_capture.gd"
const CI_WORKFLOW_PATH := "res://../.github/workflows/ci.yaml"
const WORLD_GEN_PATH := "res://scripts/world_gen.gd"
const FOLIAGE_SHADER_PATH := "res://shaders/foliage.gdshader"
const PIN_MARKER := "BACKDROP PINNED — scenery clocks fixed before first-run capture"


class BackdropProbe:
	extends Node
	var freeze_calls := 0

	func freeze_first_run_backdrop_animation() -> bool:
		freeze_calls += 1
		return true


func _ready() -> void:
	var script := load(FRAME_CAPTURE_PATH) as Script
	if script == null:
		_fail("could not load %s" % FRAME_CAPTURE_PATH)
		return
	if not _has_method(script, "pin_first_run_backdrop_clock"):
		_fail("frame capture cannot pin the live backdrop clocks before the first shutter")
		return
	if _method_arg_count(script, "pin_first_run_backdrop_clock") != 2:
		_fail("backdrop pin must receive both the scenario and the normally booted main scene")
		return

	var original_time_scale := Engine.time_scale
	Engine.time_scale = 1.25
	var probe := BackdropProbe.new()
	var world_pinned: Variant = script.call("pin_first_run_backdrop_clock", "world", probe)
	if world_pinned != false or probe.freeze_calls != 0 \
			or not is_equal_approx(Engine.time_scale, 1.25):
		Engine.time_scale = original_time_scale
		probe.free()
		_fail("ordinary world capture changed a scenery clock")
		return

	var first_run_pinned: Variant = script.call("pin_first_run_backdrop_clock", "first_run", probe)
	if first_run_pinned != true or probe.freeze_calls != 1 \
			or not is_equal_approx(Engine.time_scale, 1.25):
		Engine.time_scale = original_time_scale
		probe.free()
		_fail("first-run capture did not pin exactly one backdrop without preserving player time")
		return
	Engine.time_scale = original_time_scale
	probe.free()

	var source := script.source_code
	if not source.contains("const UI_WARMUP_FRAMES := WARMUP_FRAMES"):
		_fail("first-run capture does not give its live 3D backdrop the world convergence window")
		return
	var pin_call := "pin_first_run_backdrop_clock(scenario, main)"
	var scene_construct := "load(main_scene).instantiate()"
	var first_shutter := "_capture_first_run(dir, main)"
	var pin_offset := source.find(pin_call)
	var construct_offset := source.find(scene_construct)
	var shutter_offset := source.find(first_shutter)
	if pin_offset < construct_offset or pin_offset > shutter_offset:
		_fail("first-run backdrop clocks are not pinned after scene construction and before capture")
		return
	if not source.contains(PIN_MARKER):
		_fail("first-run capture does not report the backdrop pin it applied")
		return

	var world_script := load(WORLD_GEN_PATH) as Script
	if world_script == null or not _has_method(world_script, "freeze_capture_animation"):
		_fail("WorldGen cannot fix its wind and brazier phases for evidence capture")
		return
	var world := world_script.new() as Node3D
	var foliage := MultiMeshInstance3D.new()
	foliage.name = "Foliage_Test"
	var material := ShaderMaterial.new()
	material.shader = load(FOLIAGE_SHADER_PATH) as Shader
	material.set_shader_parameter("wind_strength", 0.075)
	foliage.material_override = material
	world.add_child(foliage)
	if not (material.shader as Shader).code.contains(
			"uniform bool wind_time_override_enabled = false;"):
		world.free()
		_fail("shipping foliage enables the evidence-only wind phase override")
		return
	var pinned_materials := int(world.call("freeze_capture_animation"))
	if pinned_materials != 1:
		world.free()
		_fail("WorldGen pinned %d foliage materials instead of one" % pinned_materials)
		return
	if material.get_shader_parameter("wind_time_override_enabled") != true \
			or not is_equal_approx(float(material.get_shader_parameter("wind_time_override")), 1.0):
		world.free()
		_fail("WorldGen did not hold foliage wind at the documented capture phase")
		return
	world.free()

	var workflow := FileAccess.get_file_as_string(CI_WORKFLOW_PATH)
	if workflow.is_empty():
		_fail("could not read %s — the first-run delivery path is untestable" % CI_WORKFLOW_PATH)
		return
	if not workflow.contains(PIN_MARKER):
		_fail("visual CI does not require proof that first-run capture pinned its live backdrop")
		return

	print("TEST PASS — first-run capture fixes wind, light, and fog phases after normal boot without changing player time or other scenarios")
	get_tree().quit(0)


func _has_method(script: Script, wanted: String) -> bool:
	for method: Dictionary in script.get_script_method_list():
		if String(method.get("name", "")) == wanted:
			return true
	return false


func _method_arg_count(script: Script, wanted: String) -> int:
	for method: Dictionary in script.get_script_method_list():
		if String(method.get("name", "")) == wanted:
			return (method.get("args", []) as Array).size()
	return -1


func _fail(message: String) -> void:
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
