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
	if not _has_method(script, "freeze_light_response_animation"):
		_fail("frame capture cannot freeze foliage wind and ash drift across each light-response pair")
		return
	if not _has_method(script, "ash_contribution_verdict"):
		_fail("frame capture has no rendered with/without-volume verdict for the ash evidence")
		return
	if not _has_method(script, "visible_fog_volume_count"):
		_fail("frame capture cannot distinguish a renderable ash pool from placement metadata")
		return
	if not source.contains("_capture_light_response"):
		_fail("the light_response scenario is declared but never reaches a capture path")
		return
	if source.count("freeze_light_response_animation()") < 2:
		_fail("the capture defines an animation freeze but never applies it to the light-response scenario")
		return
	if not source.contains("hollow_fog_placements") or not source.contains("\"ash-source-side\""):
		_fail("the moving-key proof never captures a real hollow FogVolume up close")
		return
	for frame_name: String in ["foliage-source-side", "foliage-far-side"]:
		if not source.contains("\"%s\"" % frame_name):
			_fail("the capture does not regenerate documented evidence frame %s.png" % frame_name)
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

	var original_time_scale := Engine.time_scale
	script.call("freeze_light_response_animation")
	if not is_zero_approx(Engine.time_scale):
		var actual_time_scale := Engine.time_scale
		Engine.time_scale = original_time_scale
		_fail("light-response animation freeze left Engine.time_scale at %.3f instead of zero" %
			actual_time_scale)
		return
	Engine.time_scale = original_time_scale

	var ash_live := Image.create(16, 12, false, Image.FORMAT_RGBA8)
	ash_live.fill(Color(0.25, 0.20, 0.18))
	var ash_hidden := ash_live.duplicate()
	var absent: Variant = script.call("ash_contribution_verdict", ash_live, ash_hidden)
	if absent is not Dictionary or bool((absent as Dictionary).get("ok", true)):
		_fail("identical with/without-volume frames passed as rendered ash contribution")
		return
	for y in range(4, 8):
		for x in range(6, 10):
			ash_hidden.set_pixel(x, y, Color(0.40, 0.34, 0.30))
	var present: Variant = script.call("ash_contribution_verdict", ash_live, ash_hidden)
	if present is not Dictionary or not bool((present as Dictionary).get("ok", false)):
		_fail("a visible ash-sized image contribution did not pass the rendered-volume verdict")
		return

	var fog_root := Node3D.new()
	fog_root.name = "HollowFogTest"
	add_child(fog_root)
	if int(script.call("visible_fog_volume_count", fog_root)) != 0:
		_fail("an empty fog root was treated as rendered ash")
		return
	var fog_volume := FogVolume.new()
	fog_root.add_child(fog_volume)
	if int(script.call("visible_fog_volume_count", fog_root)) != 1:
		_fail("a visible FogVolume was not recognised as renderable ash")
		return
	fog_volume.visible = false
	if int(script.call("visible_fog_volume_count", fog_root)) != 0:
		_fail("a hidden FogVolume was treated as rendered ash evidence")
		return
	fog_root.queue_free()

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
	if not Vector2(
			(source_side.x + far_side.x) * 0.5,
			(source_side.z + far_side.z) * 0.5
		).is_equal_approx(Vector2(target.x, target.z)):
		_fail("the two light positions are not horizontally symmetric around the subject")
		return
	var view_ray := (target - eye).normalized()
	var source_ray := (target - source_side).normalized()
	var far_ray := (target - far_side).normalized()
	if source_ray.dot(view_ray) < 0.999:
		_fail("source-side light does not travel with the camera ray")
		return
	if not is_equal_approx(far_side.y, source_side.y):
		_fail("far-side light changed elevation from %.2f to %.2f and can end up below terrain" %
			[source_side.y, far_side.y])
		return
	var source_horizontal := Vector2(source_ray.x, source_ray.z).normalized()
	var far_horizontal := Vector2(far_ray.x, far_ray.z).normalized()
	if far_horizontal.dot(source_horizontal) > -0.999:
		_fail("far-side light azimuth is not opposite the camera-side azimuth")
		return
	if source_ray.y >= 0.0 or far_ray.y >= 0.0:
		_fail("both key directions must remain downward toward the terrain")
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
