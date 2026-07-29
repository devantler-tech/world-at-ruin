extends Node
## Shipping-path regression for #558. The placement library is insufficient on
## its own: the real CaveSystemGen rebuild must keep talus default-off and render
## the opted-in treatment as one cosmetic MultiMesh batch.
##
## Run: godot --headless --path client res://tests/cave_foot_talus_world_test.tscn

const FLAG_ENV := "WAR_CAVE_FOOT_TALUS"
const SEED := 42
const MAX_PLACEMENTS := 72


func _ready() -> void:
	var flat_ground := func(_x: float, _z: float) -> float:
		return 0.0
	var material := func(_x: float, _z: float) -> Dictionary:
		return {
			&"color": Color(0.30, 0.27, 0.23),
			&"roughness": 0.88,
			&"normal": Vector3.UP,
			&"height": 0.0,
		}

	OS.unset_environment(FLAG_ENV)
	var off := _build_cave(flat_ground, material)
	if off.get_node_or_null("CaveFootTalus") != null:
		_fail("the default-off rebuild rendered cave-foot talus")
		return
	var baseline := CaveSystemGen.build_geometry(SEED)
	if _rock_fingerprint(off) != CaveSystemGen.fingerprint(baseline[&"mesh"]):
		_fail("the off state moved the cave rock/collision geometry")
		return

	OS.set_environment(FLAG_ENV, "true")
	var malformed := _build_cave(flat_ground, material)
	if malformed.get_node_or_null("CaveFootTalus") != null:
		_fail("a malformed flag value enabled the treatment")
		return

	OS.set_environment(FLAG_ENV, "1")
	var on := _build_cave(flat_ground, material)
	var batches := _named_batches(on)
	if batches.size() != 1:
		_fail("the on state rendered %d CaveFootTalus batches, expected exactly one" %
			batches.size())
		return
	var batch := batches[0]
	if batch.multimesh == null or batch.multimesh.mesh == null:
		_fail("the on-state batch has no MultiMesh geometry")
		return
	if batch.multimesh.instance_count <= 0 \
			or batch.multimesh.instance_count > MAX_PLACEMENTS:
		_fail("the on-state batch has %d instances, outside 1..%d" %
			[batch.multimesh.instance_count, MAX_PLACEMENTS])
		return
	if _mesh_fingerprint(batch.multimesh.mesh) \
			!= _mesh_fingerprint(FoliageArt.mesh_for(FoliageGen.Kind.RUBBLE)):
		_fail("the batch does not reuse the generated rubble mesh")
		return
	var mat := batch.material_override as ShaderMaterial
	if mat == null or mat.shader != FoliageArt.DEBRIS_SHADER \
			or mat.get_shader_parameter("albedo_tex") == null:
		_fail("the batch does not reuse the textured opaque rubble material")
		return
	for child in batch.get_children():
		if child is CollisionObject3D or child is CollisionShape3D:
			_fail("the cosmetic talus batch gained collision")
			return
	if _rock_fingerprint(on) != _rock_fingerprint(off):
		_fail("enabling cosmetic talus changed the cave rock/collision geometry")
		return

	var instance_count: int = batch.multimesh.instance_count
	OS.unset_environment(FLAG_ENV)
	on.rebuild(flat_ground, material)
	if on.get_node_or_null("CaveFootTalus") != null:
		_fail("rebuilding with the flag off retained the old talus batch")
		return

	OS.unset_environment(FLAG_ENV)
	print("TEST PASS: cave-foot talus world — default off, malformed off, opted-in %d stones in one textured cosmetic MultiMesh; rebuild removes it; rock geometry unchanged" %
		instance_count)
	get_tree().quit(0)


func _build_cave(ground: Callable, material: Callable) -> CaveSystemGen:
	var cave := CaveSystemGen.new()
	cave.seed_value = SEED
	add_child(cave)
	cave.rebuild(ground, material)
	return cave


func _named_batches(cave: CaveSystemGen) -> Array[MultiMeshInstance3D]:
	var out: Array[MultiMeshInstance3D] = []
	for child in cave.get_children():
		if child is MultiMeshInstance3D and child.name == &"CaveFootTalus":
			out.append(child as MultiMeshInstance3D)
	return out


func _rock_fingerprint(cave: CaveSystemGen) -> String:
	var rock := cave.get_node_or_null("RockHull") as MeshInstance3D
	if rock == null or not rock.mesh is ArrayMesh:
		return "missing"
	return CaveSystemGen.fingerprint(rock.mesh as ArrayMesh)


func _mesh_fingerprint(mesh: Mesh) -> String:
	var acc := PackedInt32Array()
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for vertex: Vector3 in verts:
			acc.append(roundi(vertex.x * 1000.0))
			acc.append(roundi(vertex.y * 1000.0))
			acc.append(roundi(vertex.z * 1000.0))
	return "%x" % hash(acc)


func _fail(message: String) -> void:
	OS.unset_environment(FLAG_ENV)
	push_error(message)
	print("TEST FAIL: cave-foot talus world — %s" % message)
	get_tree().quit(1)
