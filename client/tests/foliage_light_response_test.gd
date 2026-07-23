extends Node
## Regression test for the directional-light inversion reported in #346.
##
## The foliage cards are deliberately double-sided. That makes the normal of a
## visible fragment ambiguous: the camera can see either winding, while Godot
## still presents the mesh's stored normal to the lighting model. The material
## must orient that normal from FRONT_FACING before direct light is evaluated,
## or the side beside the sun can be shaded as though it faced away.
##
## Rendering is unavailable in the headless regression lane, so this test holds
## the shader contract that makes the windowed frame proof meaningful:
##   * double-sided geometry resolves FRONT_FACING instead of trusting winding;
##   * the moving light remains a renderer input, never a baked sun uniform;
##   * transmission is present but weaker than the directly lit base response.
##
## Run: godot --headless --path client res://tests/foliage_light_response_test.tscn

const FOLIAGE_SHADER_PATH := "res://shaders/foliage.gdshader"


func _ready() -> void:
	var shader := load(FOLIAGE_SHADER_PATH) as Shader
	if shader == null:
		_fail("could not load %s" % FOLIAGE_SHADER_PATH)
		return
	var source := shader.code

	if not source.contains("render_mode cull_disabled"):
		_fail("foliage must remain double-sided — crossed cards need to read from every approach")
		return
	if not source.contains("FRONT_FACING"):
		_fail("double-sided foliage never resolves FRONT_FACING — the sun-side can use the inward normal")
		return
	for forbidden: String in ["sun_direction", "light_direction"]:
		if source.contains("uniform") and source.contains(forbidden):
			_fail("foliage bakes '%s' as a uniform — moving the live light would not move the response" % forbidden)
			return

	for kind: int in [FoliageGen.Kind.ASH_SHRUB, FoliageGen.Kind.DEAD_GRASS]:
		var mat := FoliageArt.material_for(kind)
		var direct_luma := _luma(mat.get_shader_parameter("tint_low"))
		var transmitted_luma := _luma(mat.get_shader_parameter("backlight_tint"))
		if transmitted_luma <= 0.0:
			_fail("vegetation kind %d has no transmitted response — its far side would be a black cutout" % kind)
			return
		if transmitted_luma >= direct_luma:
			_fail("vegetation kind %d transmits %.3f luma against %.3f direct — the far side must stay dimmer than sunlight" %
				[kind, transmitted_luma, direct_luma])
			return

	print("TEST PASS — double-sided foliage resolves its visible normal, follows renderer lights, and keeps transmission below direct sunlight")
	get_tree().quit(0)


func _luma(value: Variant) -> float:
	if value is Color:
		var c := value as Color
		return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
	if value is Vector3:
		var v := value as Vector3
		return 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z
	return -1.0


func _fail(message: String) -> void:
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
