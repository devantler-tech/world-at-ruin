extends Node
## Contract test for #346's controlled moving-key frame proof.
##
## The ordinary world captures use different cameras, so they cannot isolate
## whether a material followed the light or merely looks different from another
## vantage. The `light_response` capture scenario holds the crossfield camera
## fixed and moves the real DirectionalLight3D between equal-and-opposite
## source positions. This headless test pins that geometry; the windowed
## scenario supplies the pixel evidence.
##
## Loaded dynamically on purpose: the first RED state is the method being
## absent, not this test failing to parse before it can explain the missing
## contract.

const FRAME_CAPTURE_PATH := "res://tools/frame_capture.gd"
const CI_WORKFLOW_PATH := "res://../.github/workflows/ci.yaml"


func _ready() -> void:
	var script := load(FRAME_CAPTURE_PATH) as Script
	if script == null:
		_fail("could not load %s" % FRAME_CAPTURE_PATH)
		return
	var source := script.source_code
	if not source.contains("\"light_response\""):
		_fail("frame capture has no light_response scenario — no fixed-camera moving-key evidence exists")
		return
	if not _has_method(script, "light_source_positions"):
		_fail("frame capture does not expose the two controlled light positions")
		return
	if not _has_method(script, "ash_response_vantage"):
		_fail("frame capture has no close view through a shipped ash pool")
		return
	if not source.contains("_capture_light_response"):
		_fail("the light_response scenario is declared but never reaches a capture path")
		return
	if not source.contains("hollow_fog_placements") or not source.contains("\"ash-source-side\""):
		_fail("the moving-key proof never captures a real hollow FogVolume up close")
		return
	var workflow := FileAccess.get_file_as_string(CI_WORKFLOW_PATH)
	if workflow.is_empty():
		_fail("could not read %s — the evidence delivery path is untestable" % CI_WORKFLOW_PATH)
		return
	for extension: String in ["png", "txt"]:
		var upload_glob := "shots/light-response/*.%s" % extension
		if not workflow.contains(upload_glob):
			_fail("visual CI renders moving-key frames but never uploads %s" % upload_glob)
			return

	var eye := Vector3(55.0, 11.0, 40.0)
	var target := Vector3(-10.0, 3.0, -20.0)
	var sources: Variant = script.call("light_source_positions", eye, target)
	if sources is not Array or (sources as Array).size() != 2:
		_fail("light_source_positions must return exactly source-side and far-side positions")
		return
	var pair := sources as Array
	var source_side := pair[0] as Vector3
	var far_side := pair[1] as Vector3
	if not source_side.is_equal_approx(eye):
		_fail("source-side light must sit at the fixed camera, got %s instead of %s" % [source_side, eye])
		return
	if not ((source_side + far_side) * 0.5).is_equal_approx(target):
		_fail("the two light positions are not symmetric around the subject")
		return
	var view_ray := (target - eye).normalized()
	var source_ray := (target - source_side).normalized()
	var far_ray := (target - far_side).normalized()
	if source_ray.dot(view_ray) < 0.999:
		_fail("source-side light does not travel with the camera ray")
		return
	if far_ray.dot(view_ray) > -0.999:
		_fail("far-side light is not opposite the camera ray")
		return

	var placement := {
		"pos": Vector3(-24.0, 1.0, 32.0),
		"extents": Vector3(18.0, 3.0, 18.0),
	}
	var ash_vantage: Variant = script.call("ash_response_vantage", placement)
	if ash_vantage is not Array or (ash_vantage as Array).size() != 2:
		_fail("ash_response_vantage must return exactly eye and target")
		return
	var ash_eye := (ash_vantage as Array)[0] as Vector3
	var ash_target := (ash_vantage as Array)[1] as Vector3
	if not ash_target.is_equal_approx(placement["pos"]):
		_fail("ash close-up must look through the centre of the shipped pool")
		return
	if ash_eye.distance_to(ash_target) <= (placement["extents"] as Vector3).z:
		_fail("ash close-up camera sits inside the FogVolume instead of looking through it")
		return
	if ash_eye.y <= ash_target.y:
		_fail("ash close-up must look down through the pool so terrain provides a visible backdrop")
		return

	print("TEST PASS — light-response capture holds each camera, moves the live key through opposite directions, and isolates a shipped ash pool")
	get_tree().quit(0)


func _has_method(script: Script, wanted: String) -> bool:
	for method: Dictionary in script.get_script_method_list():
		if String(method.get("name", "")) == wanted:
			return true
	return false


func _fail(message: String) -> void:
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
