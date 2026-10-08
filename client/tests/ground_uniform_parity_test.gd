extends Node
## Holds the two ground shaders to one set of surface parameters (#697).
##
## `terrain.gdshader` and `cave_terrain_contact.gdshader` sit next to each other
## on screen and are meant to read as one continuous floor. The contact band
## declares the ground's surface parameters again rather than sharing them, and
## only `plates_enabled` is ever set from script, so every other one ships as its
## shader default. A default, hint or type changed in one file and not the other
## would change what the same quantity means on one surface only, and nothing
## would fail. This test is the join: every uniform both files declare must be
## declared the same way.
##
## Deliberately a SOURCE-TEXT check, like wind_parity_test: uniform defaults are
## only observable through a render, which `--headless` cannot read.

const GROUND_SHADER_PATH := "res://shaders/terrain.gdshader"
const CONTACT_SHADER_PATH := "res://shaders/cave_terrain_contact.gdshader"
const REGION_INCLUDE_PATH := "res://shaders/ground_stone_regions.gdshaderinc"
const REGION_INCLUDE := '#include "res://shaders/ground_stone_regions.gdshaderinc"'

## The parameters the contact band shares with the ground. Every uniform the two
## files both declare is compared, whether it is listed here or not. The list is
## the floor: without it, a parameter dropped from one file and replaced by a
## constant would leave the comparison silently, and a parser that matched
## nothing would compare nothing and pass.
const SHARED: Array[String] = [
	"ash_color", "rock_color", "scorch_color",
	"drift_scale", "grain_scale", "bump_strength",
	"rock_slope", "ash_roughness", "rock_roughness",
	"detail_fade_start", "detail_fade_end",
	"plate_basalt", "plate_ferric", "plate_pale",
	"plates_enabled", "plate_scale",
	"crack_width", "crack_darkness", "crack_relief",
	"seam_cavity", "ash_contact", "lip_lift",
	"region_stone_enabled", "stone_region_sites", "stone_region_profiles",
	"stone_region_blend_band",
]


func _ready() -> void:
	var broken := _normaliser_self_check()
	if broken != "":
		_fail(broken)
		return
	broken = _include_self_check()
	if broken != "":
		_fail(broken)
		return
	var ground := _declarations(GROUND_SHADER_PATH)
	if ground.has("error"):
		_fail(ground["error"])
		return
	var contact := _declarations(CONTACT_SHADER_PATH)
	if contact.has("error"):
		_fail(contact["error"])
		return
	var ground_decls: Dictionary = ground["decls"]
	var contact_decls: Dictionary = contact["decls"]

	var problems: Array[String] = []
	for param in SHARED:
		if not ground_decls.has(param):
			problems.append("`%s` is no longer declared in %s" % [param, GROUND_SHADER_PATH])
		if not contact_decls.has(param):
			problems.append("`%s` is no longer declared in %s" % [param, CONTACT_SHADER_PATH])

	var compared := 0
	var names: Array = ground_decls.keys()
	names.sort()
	for param: String in names:
		if not contact_decls.has(param):
			continue
		compared += 1
		if ground_decls[param] != contact_decls[param]:
			problems.append("`%s` is `%s` in %s but `%s` in %s" % [
				param, ground_decls[param], GROUND_SHADER_PATH,
				contact_decls[param], CONTACT_SHADER_PATH,
			])

	if not problems.is_empty():
		_fail("the ground and its cave contact band disagree about their shared surface parameters, so the same quantity would read differently on each side of the join: "
			+ "; ".join(PackedStringArray(problems)))
		return

	print("TEST PASS — %s and %s declare their %d shared surface parameters identically" % [
		GROUND_SHADER_PATH, CONTACT_SHADER_PATH, compared,
	])
	get_tree().quit(0)


## Every top-level `uniform` declaration in [param path], keyed by name, with the
## declaration normalised so a reformat is not a divergence: whitespace collapsed,
## spacing around punctuation dropped, and every numeric literal rewritten as its
## 32-bit value, so `0.50`, `.5` and `0.5f` agree while `1e-7` and `2e-7` do not.
## Returns `{"decls": {...}}`, or `{"error": message}` when the file cannot be
## read or a declaration cannot be parsed. A declaration the parser skipped would
## otherwise be one this test never compared.
func _declarations(path: String) -> Dictionary:
	var shader := load(path) as Shader
	if shader == null or shader.code == "":
		return {"error": "could not read %s, so there is nothing to compare and every check below would pass while checking nothing" % path}
	return _source_declarations(shader.code, path)


func _source_declarations(source: String, path: String, shared_source: String = "") -> Dictionary:
	# Join only an executable, exact shared include. Commented directives must not
	# manufacture declarations for a shader that no longer imports them.
	var block_comments := RegEx.new()
	block_comments.compile("(?s)/\\*.*?\\*/")
	source = block_comments.sub(source, "", true)
	for raw_line: String in source.split("\n"):
		if raw_line.strip_edges() == REGION_INCLUDE:
			var shared := shared_source
			if shared == "":
				shared = FileAccess.get_file_as_string(REGION_INCLUDE_PATH)
			if shared == "":
				return {"error": "could not read shared declarations in %s" % REGION_INCLUDE_PATH}
			source += "\n" + shared
	# Includes may contain comments too; a commented-out uniform must not satisfy
	# the shared floor merely because its source lives in the joined file.
	source = block_comments.sub(source, "", true)

	var declaration := RegEx.new()
	declaration.compile("^uniform\\s+(?:\\w+\\s+)+?(\\w+)\\s*(?::|=|;|\\[|$)")
	var decls := {}
	for raw_line: String in source.split("\n"):
		var line: String = raw_line.strip_edges()
		if not (line.begins_with("uniform ") or line.begins_with("uniform\t")):
			continue
		var end := line.find(";")
		if end < 0:
			return {"error": "`%s` in %s does not end on its own line, so this test cannot compare it" % [line, path]}
		var text := _normalise(line.substr(0, end))
		var m := declaration.search(text)
		if m == null:
			return {"error": "could not read the uniform name in `%s` (%s)" % [text, path]}
		var name := m.get_string(1)
		if decls.has(name):
			return {"error": "duplicate uniform `%s` in %s" % [name, path]}
		decls[name] = text
	if decls.is_empty():
		return {"error": "found no uniform declarations in %s, so there is nothing to compare" % path}
	return {"decls": decls}


func _include_self_check() -> String:
	var regional := ["region_stone_enabled", "stone_region_sites",
		"stone_region_profiles", "stone_region_blend_band"]
	for path: String in [GROUND_SHADER_PATH, CONTACT_SHADER_PATH]:
		var source := FileAccess.get_file_as_string(path)
		if not source.contains(REGION_INCLUDE):
			return "missing shared regional include in %s" % path
		var removed := _source_declarations(source.replace(REGION_INCLUDE, ""), path)
		if removed.has("error"):
			return removed["error"]
		for param: String in regional:
			if not SHARED.has(param) or removed["decls"].has(param):
				return "removing the regional include must fail the `%s` declaration floor in %s" % [param, path]
	for commented: String in ["// " + REGION_INCLUDE, "/*\n" + REGION_INCLUDE + "\n*/"]:
		var parsed := _source_declarations(commented + "\nuniform float original = 1.0;", "comment control")
		if parsed.has("error") or parsed["decls"].size() != 1:
			return "a commented include manufactured regional declarations"
	var commented_uniform := _source_declarations(REGION_INCLUDE + "\nuniform float original = 1.0;",
		"commented shared declaration control", "/*\nuniform vec3 stone_region_sites[9];\n*/")
	if commented_uniform.has("error") or commented_uniform["decls"].size() != 1:
		return "a commented declaration satisfied the shared uniform floor"
	var duplicate := _source_declarations("uniform float x = 1.0;\nuniform float x = 2.0;", "duplicate control")
	if not duplicate.has("error"):
		return "duplicate declarations hid a uniform disagreement"
	return ""


func _normalise(text: String) -> String:
	var spaces := RegEx.new()
	spaces.compile("\\s+")
	var collapsed := spaces.sub(text, " ", true)
	var punctuation := RegEx.new()
	punctuation.compile(" ?([,()=:\\[\\]]) ?")
	collapsed = punctuation.sub(collapsed, "$1", true)
	var number := RegEx.new()
	number.compile("(?<![\\w.])(?:\\d+(?:\\.\\d*)?|\\.\\d+)(?:[eE][-+]?\\d+)?[fu]?")
	var out := ""
	var at := 0
	for m: RegExMatch in number.search_all(collapsed):
		out += collapsed.substr(at, m.get_start() - at)
		# Shader floats are 32-bit: two literals the GPU stores identically agree,
		# and any two it stores differently stay distinct. The `f` and `u` type
		# suffixes do not change the value.
		var literal := m.get_string().trim_suffix("f").trim_suffix("u")
		out += String.num(PackedFloat32Array([float(literal)])[0])
		at = m.get_end()
	return out + collapsed.substr(at)


## The comparison is only as good as _normalise(): a reformat must compare equal,
## and two values the GPU stores differently must not. Returns "" when both hold.
func _normaliser_self_check() -> String:
	var same := [
		["uniform float x : hint_range(0.0, 1.0) = 0.5", "uniform float x:hint_range(0.0,1.0)=0.50"],
		["uniform vec3 c = vec3( 0.2 , 0.1, 1 )", "uniform vec3 c=vec3(0.2,0.1,1.0)"],
		["uniform float x = 0.1", "uniform float x = 0.10000000001"],
		["uniform float x = 0.5", "uniform float x = 0.5f"],
		["uniform float x = 0.5", "uniform float x = .5"],
		["uniform uint n = 3", "uniform uint n = 3u"],
		["uniform vec2 v = vec2(0.5, 0.1)", "uniform vec2 v = vec2(.5f, 1e-1f)"],
		["uniform vec3 sites [ 9 ]", "uniform vec3 sites[9]"],
	]
	for pair: Array in same:
		if _normalise(pair[0]) != _normalise(pair[1]):
			return "the normaliser reads a reformat as a divergence: `%s` became `%s` but `%s` became `%s`" % [
				pair[0], _normalise(pair[0]), pair[1], _normalise(pair[1])]
	var different := [
		["uniform float x = 0.0000001", "uniform float x = 0.0000002"],
		["uniform float x = 130.0", "uniform float x = 131.0"],
		["uniform float x = 0.5f", "uniform float x = 0.6f"],
		["uniform float x = .5", "uniform float x = .6"],
		["uniform vec3 sites[9]", "uniform vec3 sites[8]"],
	]
	for pair: Array in different:
		if _normalise(pair[0]) == _normalise(pair[1]):
			return "the normaliser hides a real difference: `%s` and `%s` both became `%s`" % [
				pair[0], pair[1], _normalise(pair[0])]
	return ""


func _fail(message: String) -> void:
	# The runner refuses any log containing this token (#313).
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
