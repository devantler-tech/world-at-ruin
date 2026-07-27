extends Node
## Regression for #306: every per-cell plate decision is filtered over its
## boundary footprint, in BOTH shaders that draw Ashfall Reach ground.
##
## What this can and cannot do. It pins the WIRING — that the terrain and the
## cave-foot contact resolve their substance and their slab mask through the
## shared filtered helpers, and that neither has gone back to choosing from the
## owning cell outright. It cannot judge whether the result stops crawling:
## that is temporal and needs a moving camera on a real GPU, which
## `tools/plate_crawl_probe.gd` measures and a human confirms by eye.
##
## The duplication is the reason this is a test rather than a convention. The
## two shaders resolved the same plates from copied code, so a fix applied to
## one silently left the other aliasing — and nothing in the suite could see it.
##
## Run: godot --headless --path client res://tests/plate_filter_guard_test.tscn

const INCLUDE_PATH := "res://shaders/terrain_surface.gdshaderinc"
const GROUND_SHADERS := [
	"res://shaders/terrain.gdshader",
	"res://shaders/cave_terrain_contact.gdshader",
]

## The shared entry points every ground shader must resolve its plates through.
const REQUIRED_CALLS := [
	"terrain_plate_substance_filtered",
	"terrain_plate_slab",
]

## The hand-rolled slab pick, as it read when each shader carried its own copy.
## Matching the CONSTANTS rather than a phrase keeps this pinned to the code:
## a reworded comment must not trip it, and a re-introduced copy must.
const SLAB_CONSTANTS := ["2.3", "19.0", "step(0.60"]


func _ready() -> void:
	var include_src := _read(INCLUDE_PATH)
	if include_src.is_empty():
		_fail("%s is empty or unreadable — the guard would inspect nothing" % INCLUDE_PATH)
		return

	# The filter must be driven by the screen footprint of the boundary. A
	# constant blend would be a permanent smear at every distance, which is a
	# different defect wearing this fix's name.
	if "terrain_plate_boundary_blend" not in include_src:
		_fail("the shared include defines no terrain_plate_boundary_blend — there is no boundary footprint to filter over")
		return
	if "fwidth" not in _body_of(include_src, "terrain_plate_boundary_blend"):
		_fail("terrain_plate_boundary_blend does not use fwidth — a blend that ignores the screen footprint smears the near field instead of filtering the far one")
		return

	for call_name: String in REQUIRED_CALLS:
		if "%s(" % call_name not in include_src:
			_fail("the shared include does not define %s — the ground shaders have nothing to share" % call_name)
			return

	for path: String in GROUND_SHADERS:
		var src := _read(path)
		if src.is_empty():
			_fail("%s is empty or unreadable — the guard would inspect nothing" % path)
			return
		var flat := _flatten(src)
		for call_name: String in REQUIRED_CALLS:
			if "%s(" % call_name not in flat:
				_fail("%s does not resolve its plates through %s — it chooses from the owning cell outright, so its boundaries alias" % [path, call_name])
				return
		# NEGATIVE: the copied slab pick must not come back alongside the shared
		# one. A shader calling the helper AND keeping its own copy would pass a
		# presence-only check while still drawing the unfiltered mask.
		var reintroduced := true
		for token: String in SLAB_CONSTANTS:
			if token not in flat:
				reintroduced = false
		if reintroduced:
			_fail("%s hand-rolls the slab pick again (%s) — the two ground shaders drift apart exactly here" % [path, ", ".join(SLAB_CONSTANTS)])
			return

	print("TEST PASS — %d ground shaders filter every plate decision over its boundary footprint"
		% GROUND_SHADERS.size())
	get_tree().quit(0)


func _read(path: String) -> String:
	var res := load(path)
	if res is Shader:
		return (res as Shader).code
	# .gdshaderinc is not a Shader resource; read it as text.
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


## Collapse whitespace so a reformat cannot defeat a match, and an argument list
## broken across lines reads the same as one written inline.
func _flatten(src: String) -> String:
	var out := ""
	var was_space := false
	for i in src.length():
		var c := src[i]
		if c == " " or c == "\t" or c == "\n" or c == "\r":
			if not was_space:
				out += " "
			was_space = true
		else:
			out += c
			was_space = false
	return out.replace("( ", "(").replace(" (", "(").replace(", ", ",").replace(" ,", ",")


## The text between a function's opening brace and its matching close.
func _body_of(src: String, func_name: String) -> String:
	var at := src.find(func_name)
	if at < 0:
		return ""
	var open := src.find("{", at)
	if open < 0:
		return ""
	var depth := 0
	for i in range(open, src.length()):
		if src[i] == "{":
			depth += 1
		elif src[i] == "}":
			depth -= 1
			if depth == 0:
				return src.substr(open, i - open + 1)
	return ""


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
