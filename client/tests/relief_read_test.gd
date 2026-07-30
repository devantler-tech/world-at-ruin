extends Node
## Pins the relief instrument's public row grammar: a sample the tool refused
## must never be serialised as the numeric zero a real measurement may produce.
##
## Run: godot --headless --path client res://tests/relief_read_test.tscn

const ReliefRead := preload("res://tools/relief_read.gd")
const ReliefProbe := preload("res://tests/relief_read_probe.gd")


class CameraStealer:
	extends Node

	var camera: Camera3D

	func _process(_delta: float) -> void:
		camera.make_current()


func _ready() -> void:
	var tool := ReliefRead.new()
	var readings := PackedFloat32Array([NAN, 0.0, 0.007, 0.014])
	var row: String = tool._row(readings)
	tool.free()
	var expected := "6m=REFUSED 12m=0.00000 24m=0.00700 48m=0.01400"
	if row != expected:
		_fail("refused and measured-zero samples are ambiguous: got `%s`, expected `%s`"
			% [row, expected])
		return

	var probe := ReliefProbe.new()
	add_child(probe)
	var expected_camera := Camera3D.new()
	probe.add_child(expected_camera)
	expected_camera.global_position = Vector3(0.0, 1.0, 1.0)
	probe._cam = expected_camera
	probe._anchor = Vector3.ZERO
	var competing_camera := Camera3D.new()
	probe.add_child(competing_camera)
	var stealer := CameraStealer.new()
	stealer.camera = competing_camera
	probe.add_child(stealer)
	competing_camera.make_current()

	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = "shader_type spatial; uniform float crack_relief = 1.1;"
	material.shader = shader
	var refused: PackedFloat32Array = await probe._settled_luma(material, 1.1)
	if refused.size() != 1 or not is_nan(refused[0]):
		_fail("a competing camera produced a numeric relief sample instead of an explicit refusal")
		return

	probe.queue_free()
	print("TEST PASS — relief_read distinguishes refusal from zero and refuses a stolen camera")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
