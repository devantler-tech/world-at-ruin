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
]


func _ready() -> void:
	var broken := _normaliser_self_check()
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
## 32-bit value, so `0.50` and `0.5` agree while `1e-7` and `2e-7` do not.
## Returns `{"decls": {...}}`, or `{"error": message}` when the file cannot be
## read or a declaration cannot be parsed. A declaration the parser skipped would
## otherwise be one this test never compared.
func _declarations(path: String) -> Dictionary:
	var shader := load(path) as Shader
	if shader == null or shader.code == "":
		return {"error": "could not read %s, so there is nothing to compare and every check below would pass while checking nothing" % path}

	var declaration := RegEx.new()
	declaration.compile("^uniform\\s+(?:\\w+\\s+)+?(\\w+)\\s*(?::|=|;|$)")
	var decls := {}
	for raw_line: String in shader.code.split("\n"):
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
		decls[m.get_string(1)] = text
	if decls.is_empty():
		return {"error": "found no uniform declarations in %s, so there is nothing to compare" % path}
	return {"decls": decls}


func _normalise(text: String) -> String:
	var spaces := RegEx.new()
	spaces.compile("\\s+")
	var collapsed := spaces.sub(text, " ", true)
	var punctuation := RegEx.new()
	punctuation.compile(" ?([,()=:\\[\\]]) ?")
	collapsed = punctuation.sub(collapsed, "$1", true)
	var number := RegEx.new()
	number.compile("(?<![\\w.])\\d+(?:\\.\\d*)?(?:[eE][-+]?\\d+)?")
	var out := ""
	var at := 0
	for m: RegExMatch in number.search_all(collapsed):
		out += collapsed.substr(at, m.get_start() - at)
		# Shader floats are 32-bit: two literals the GPU stores identically agree,
		# and any two it stores differently stay distinct.
		out += String.num(PackedFloat32Array([float(m.get_string())])[0])
		at = m.get_end()
	return out + collapsed.substr(at)


## The comparison is only as good as _normalise(): a reformat must compare equal,
## and two values the GPU stores differently must not. Returns "" when both hold.
func _normaliser_self_check() -> String:
	var same := [
		["uniform float x : hint_range(0.0, 1.0) = 0.5", "uniform float x:hint_range(0.0,1.0)=0.50"],
		["uniform vec3 c = vec3( 0.2 , 0.1, 1 )", "uniform vec3 c=vec3(0.2,0.1,1.0)"],
		["uniform float x = 0.1", "uniform float x = 0.10000000001"],
	]
	for pair: Array in same:
		if _normalise(pair[0]) != _normalise(pair[1]):
			return "the normaliser reads a reformat as a divergence: `%s` became `%s` but `%s` became `%s`" % [
				pair[0], _normalise(pair[0]), pair[1], _normalise(pair[1])]
	var different := [
		["uniform float x = 0.0000001", "uniform float x = 0.0000002"],
		["uniform float x = 130.0", "uniform float x = 131.0"],
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
