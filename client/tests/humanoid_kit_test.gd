extends Node
## Regression test for the humanoid kit (character system stage 1, issue #24):
## the committed kit GLB must match its committed structural contract
## (kit_report.txt), and morph composition must be deterministic.
##  1. The kit loads; it carries a Skeleton3D with the contracted bone count
##     and a skinned body mesh.
##  2. Blend shapes: exactly the contracted names, in order (recipes key on
##     these names forever — the no-resets law).
##  3. CPU morph mix (base + Σ w·delta) with fixed weights ⇒ identical
##     fingerprint twice; different weights ⇒ different fingerprint; all-zero
##     weights ⇒ the base geometry.
##
## Run: godot --headless --path client res://tests/humanoid_kit_test.tscn

const KIT_SCENE := "res://assets/characters/humanoid_kit/humanoid_base.glb"
const KIT_REPORT := "res://assets/characters/humanoid_kit/kit_report.txt"

const WEIGHTS_A := { "torso_vshape": 0.8, "arms_muscle": 0.6, "belly": -0.3, "head_square": 0.5 }
const WEIGHTS_B := { "torso_vshape": 0.2, "legs_heavy": 0.9, "nose_hump": 1.0 }


func _ready() -> void:
	var report := _read_report()
	if report.is_empty():
		_fail("cannot read %s" % KIT_REPORT)
		return
	var packed: PackedScene = load(KIT_SCENE)
	if packed == null:
		_fail("kit GLB missing or unimported: %s" % KIT_SCENE)
		return
	var kit := packed.instantiate()

	var skel := _find_skeleton(kit)
	if skel == null:
		_fail("no Skeleton3D in the kit")
		return
	if skel.get_bone_count() != int(report["bones"]):
		_fail("bone count %d != contracted %s" % [skel.get_bone_count(), report["bones"]])
		return

	var mesh_instance := _find_skinned_mesh(skel)
	if mesh_instance == null:
		_fail("no skinned MeshInstance3D under the kit skeleton")
		return
	var mesh := mesh_instance.mesh

	var contracted: PackedStringArray = report["shapes"].split(",")
	if mesh.get_blend_shape_count() != contracted.size():
		_fail("blend shape count %d != contracted %d" % [mesh.get_blend_shape_count(), contracted.size()])
		return
	for i in contracted.size():
		var actual := String(mesh.get_blend_shape_name(i))
		if actual != contracted[i]:
			_fail("blend shape %d is '%s', contract says '%s' — shipped shape names may never change" % [i, actual, contracted[i]])
			return

	var fp_a1 := _mix_fingerprint(mesh, WEIGHTS_A)
	var fp_a2 := _mix_fingerprint(mesh, WEIGHTS_A)
	var fp_b := _mix_fingerprint(mesh, WEIGHTS_B)
	var fp_zero := _mix_fingerprint(mesh, {})
	var fp_base := _hash_bytes(_base_vertices(mesh).to_byte_array())
	if fp_a1 != fp_a2:
		_fail("same weights produced different mixes:\n  %s\n  %s" % [fp_a1, fp_a2])
		return
	if fp_a1 == fp_b:
		_fail("different weights produced identical mixes: %s" % fp_a1)
		return
	if fp_zero != fp_base:
		_fail("zero-weight mix differs from base geometry")
		return

	kit.free()
	print("TEST PASS — kit v%s, %s bones, %d shapes, mix=%s" % [report["kit_version"], report["bones"], contracted.size(), fp_a1])
	get_tree().quit(0)


func _read_report() -> Dictionary:
	var f := FileAccess.open(KIT_REPORT, FileAccess.READ)
	if f == null:
		return {}
	var out := {}
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.contains("="):
			out[line.get_slice("=", 0)] = line.get_slice("=", 1)
	return out


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null


func _find_skinned_mesh(skel: Skeleton3D) -> MeshInstance3D:
	for child in skel.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).skin != null:
			return child
	return null


func _base_vertices(mesh: Mesh) -> PackedVector3Array:
	return mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]


## CPU morph mix: base + Σ w·delta over the named shapes, hashed. The GPU
## does this exact linear combination at runtime; headless CI has no GPU, so
## the arithmetic is reproduced from the imported blend-shape arrays. In
## NORMALIZED mode (how glTF imports) the blend arrays hold absolute target
## positions and the delta is target − base; in RELATIVE mode they hold the
## raw offsets.
func _mix_fingerprint(mesh: Mesh, weights: Dictionary) -> String:
	var base := _base_vertices(mesh)
	var mixed := PackedVector3Array(base)
	var blends := mesh.surface_get_blend_shape_arrays(0)
	var normalized: bool = mesh is ArrayMesh \
		and (mesh as ArrayMesh).blend_shape_mode == Mesh.BLEND_SHAPE_MODE_NORMALIZED
	for shape_name: String in weights:
		var idx := -1
		for i in mesh.get_blend_shape_count():
			if String(mesh.get_blend_shape_name(i)) == shape_name:
				idx = i
				break
		if idx < 0:
			return "missing-shape:%s" % shape_name
		var targets: PackedVector3Array = blends[idx][Mesh.ARRAY_VERTEX]
		var w: float = weights[shape_name]
		for v in mixed.size():
			var delta := targets[v] - base[v] if normalized else targets[v]
			mixed[v] += delta * w
	return _hash_bytes(mixed.to_byte_array())


func _hash_bytes(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
