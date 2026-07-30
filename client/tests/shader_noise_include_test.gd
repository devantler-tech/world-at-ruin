extends Node
## Regression for #292: terrain and cave rock share one procedural-noise basis.
##
## Run: godot --headless --path client res://tests/shader_noise_include_test.tscn

const NOISE_INCLUDE_PATH := "res://shaders/noise.gdshaderinc"
const NOISE_INCLUDE := "#include \"%s\"" % NOISE_INCLUDE_PATH
const CONSUMERS := [
	"res://shaders/terrain.gdshader",
	"res://shaders/cave_rock.gdshader",
]
const SHARED_FUNCTIONS := ["hash3", "value_noise", "fbm"]


func _ready() -> void:
	var shared_source := FileAccess.get_file_as_string(NOISE_INCLUDE_PATH)
	if shared_source.is_empty():
		_fail("could not read %s" % NOISE_INCLUDE_PATH)
		return

	for function_name: String in SHARED_FUNCTIONS:
		var definition := "float %s(" % function_name
		if shared_source.count(definition) != 1:
			_fail("%s must define %s exactly once" % [NOISE_INCLUDE_PATH, function_name])
			return

	for shader_path: String in CONSUMERS:
		var shader := load(shader_path) as Shader
		if shader == null:
			_fail("could not load %s" % shader_path)
			return
		if NOISE_INCLUDE not in shader.code:
			_fail("%s does not include %s" % [shader_path, NOISE_INCLUDE_PATH])
			return
		for function_name: String in SHARED_FUNCTIONS:
			if "\nfloat %s(" % function_name in shader.code:
				_fail("%s carries a local %s copy" % [shader_path, function_name])
				return

	print("TEST PASS — terrain and cave rock share one procedural-noise include with no local copies")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("TEST FAIL — %s" % message)
	get_tree().quit(1)
