extends Node
## Regression test: ruin and shrine masonry is CUT STONE, not a flat colour.
##
## Every column, lintel, fallen block, monolith and pedestal in the world used
## to share one StandardMaterial3D — a single albedo_color and a single
## roughness scalar. No face responded to the low sun at any angle, and two
## ruins 200 m apart were the same shade as each other and as the shrine.
##
## What this test can and cannot do is worth stating plainly, because the trap
## here is a guard that passes while the thing it guards is invisible (#250:
## the ragged shirt rendered nothing while every test asserting the NODE
## existed stayed green). This pins the WIRING — that masonry is shaded by the
## masonry shader and that the ruins and shrine remain distinguishable. It
## cannot judge whether the result LOOKS like cut stone; the committed capture
## vantages carry that evidence, and a human looks at them.
##
##  1. EVERY masonry mesh under a ruin site and under the shrine is shaded by
##     masonry.gdshader — the exact regression, stated so it names itself.
##  2. NON-VACUITY — the sweep actually found masonry. A guard that silently
##     inspects nothing is the failure mode this whole suite keeps hitting, so
##     an empty or implausibly small sweep is a failure, not a pass.
##  3. RUINS AND SHRINE STAY DISTINCT — the shrine's stone is kept lighter than
##     the ruin field's. A single shared tint would erase the one place the
##     world deliberately reads as kept rather than fallen.
##  4. NEGATIVE CONTROL — the shrine's ember brazier is NOT masonry. It is
##     emissive and must stay so; without this, blanket-applying the shader to
##     every mesh in the world would pass assertions 1-3.
##
## Run: godot --headless --path client res://tests/masonry_material_test.tscn

const MASONRY_SHADER := "res://shaders/masonry.gdshader"

## The world builds RUIN_SITES sites, each with several pieces, plus seven
## shrine monoliths and a pedestal: 188 meshes as this is written. The floor
## sits well below that so ordinary world tuning never trips it, but well above
## a sweep that has stopped seeing the world — it is a vacuity guard, not an
## assertion about how many ruins the world should contain (the determinism
## test owns that count).
##
## This constant is load-bearing and has already earned its keep: the first
## version of this test matched ruin sites by NAME, found 11 meshes instead of
## 188, and would have passed every other assertion while inspecting one site
## out of forty-four.
const MIN_MASONRY_MESHES := 100


func _ready() -> void:
	var world := WorldGen.new()
	add_child(world)

	var shrine := world.get_node_or_null("WardensShrine")
	if shrine == null:
		_fail("the world built no WardensShrine — the sweep would inspect nothing")
		return

	# Ruin sites are scriptless native Node3Ds. Godot uniquifies their duplicate
	# "Ruin" names to "@Node3D@N" — the CLASS, not the assigned name — so
	# matching on the name finds exactly ONE site and silently skips the other
	# 43. Match on structure instead, the same way world_gen_determinism_test
	# does. (The non-vacuity floor below is what caught this: the name-matched
	# version inspected 11 meshes and would otherwise have passed.)
	var ruin_meshes: Array[MeshInstance3D] = []
	for child in world.get_children():
		if child.get_class() != "Node3D" or child.get_script() != null:
			continue
		if str(child.name) == "WardensShrine":
			continue
		_collect_meshes(child, ruin_meshes)

	var shrine_meshes: Array[MeshInstance3D] = []
	_collect_meshes(shrine, shrine_meshes)

	# The ember brazier is identified STRUCTURALLY: masonry is built through
	# _solid(), so every stone mesh hangs under a StaticBody3D, while the
	# brazier is added to the shrine directly. Reading the structure keeps this
	# test from needing a new accessor on production code purely for its own
	# convenience.
	var brazier: MeshInstance3D = null
	for child in shrine.get_children():
		if child is MeshInstance3D:
			brazier = child as MeshInstance3D
			break

	# 2. NON-VACUITY, asserted BEFORE the material checks: an empty sweep would
	#    satisfy "every mesh is masonry" trivially.
	if ruin_meshes.is_empty():
		_fail("no ruin meshes found at all — the sweep inspected nothing")
		return
	var total := ruin_meshes.size() + shrine_meshes.size()
	if total < MIN_MASONRY_MESHES:
		_fail("only %d masonry meshes found (floor %d) — the sweep is not seeing the world"
			% [total, MIN_MASONRY_MESHES])
		return

	# 1. Every ruin and shrine mesh is shaded by the masonry shader. The brazier
	#    is the one deliberate exception and is checked as the control below.
	var ruin_tint := Color(0, 0, 0)
	var shrine_tint := Color(0, 0, 0)

	for mi: MeshInstance3D in ruin_meshes:
		var tint: Variant = _masonry_tint(mi)
		if tint == null:
			_fail("a ruin mesh (%s) is not shaded by masonry.gdshader — flat stone is back"
				% mi.get_path())
			return
		ruin_tint = tint as Color

	for mi: MeshInstance3D in shrine_meshes:
		if mi == brazier:
			continue
		var tint: Variant = _masonry_tint(mi)
		if tint == null:
			_fail("a shrine mesh (%s) is not shaded by masonry.gdshader — flat stone is back"
				% mi.get_path())
			return
		shrine_tint = tint as Color

	# 3. The shrine's stone stays lighter than the ruin field's.
	var ruin_luma := ruin_tint.r + ruin_tint.g + ruin_tint.b
	var shrine_luma := shrine_tint.r + shrine_tint.g + shrine_tint.b
	if shrine_luma <= ruin_luma:
		_fail("the shrine's stone (%.3f) is no lighter than the ruins' (%.3f) — the kept place reads as fallen"
			% [shrine_luma, ruin_luma])
		return

	# 4. NEGATIVE CONTROL — the ember brazier must NOT be masonry.
	if brazier == null:
		_fail("no brazier mesh — the negative control cannot run, so assertion 1 proves less")
		return
	if _masonry_tint(brazier) != null:
		_fail("the ember brazier is shaded as masonry — the shader was blanket-applied")
		return

	print("TEST PASS — masonry material (%d ruin + %d shrine meshes, shrine %.3f lighter than ruins %.3f, brazier exempt)"
		% [ruin_meshes.size(), shrine_meshes.size() - 1, shrine_luma, ruin_luma])
	get_tree().quit(0)


## The masonry tint of a mesh, or null if it is not masonry-shaded. Returning
## the tint rather than a bool lets assertion 3 reuse the same lookup.
func _masonry_tint(mi: MeshInstance3D) -> Variant:
	var mat := mi.get_surface_override_material(0)
	if mat == null:
		return null
	var shader_mat := mat as ShaderMaterial
	if shader_mat == null or shader_mat.shader == null:
		return null
	if shader_mat.shader.resource_path != MASONRY_SHADER:
		return null
	var tint: Variant = shader_mat.get_shader_parameter("stone_color")
	if tint == null:
		return null
	return tint


func _collect_meshes(node: Node, into: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		into.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect_meshes(child, into)


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
