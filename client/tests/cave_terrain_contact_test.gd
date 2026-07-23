extends Node
## Regression for #345: the cave mesh must know where its exterior meets the
## rendered terrain. A general weathered palette is not a transition; the
## shader needs the local ground substance and a non-constant contact weight.
##
## Run: godot --headless --path client res://tests/cave_terrain_contact_test.tscn

const SEED := 42
const TEST_GROUND := Color(0.17, 0.29, 0.41)
const TEST_ROUGHNESS := 0.73
const EPS := 0.0001


func _ready() -> void:
	var cave := CaveSystemGen.new()
	add_child(cave)

	# Fail as a test assertion before invoking a signature that older builds do
	# not have. Calling it blindly would be a script/runtime error, which is not
	# useful RED evidence.
	if _method_arg_count(cave, &"rebuild") < 2:
		_fail("CaveSystemGen.rebuild has no local-ground material sampler — the massif cannot receive the substance it meets")
		return

	var flat_ground := func(_x: float, _z: float) -> float:
		return 0.0
	var material_calls := [0]
	var local_material := func(_x: float, _z: float) -> Dictionary:
		material_calls[0] += 1
		return {
			&"color": TEST_GROUND,
			&"roughness": TEST_ROUGHNESS,
		}
	Callable(cave, &"rebuild").call(flat_ground, local_material)
	if material_calls[0] == 0:
		_fail("rebuild never sampled local ground material")
		return

	var rock_mesh := _rock_mesh(cave)
	var mesh := _named_mesh(cave, &"TerrainContact")
	if rock_mesh == null or mesh == null:
		_fail("rebuild did not produce both the rock and terrain-contact meshes")
		return
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	if not arrays[Mesh.ARRAY_TEX_UV] is PackedVector2Array:
		_fail("terrain-contact mesh has no local-ground red/green channel")
		return
	if not arrays[Mesh.ARRAY_TEX_UV2] is PackedVector2Array:
		_fail("terrain-contact mesh has no local-ground blue/roughness channel")
		return
	var ground_rg: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var ground_b_roughness: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	if colors.size() != verts.size():
		_fail("ground-contact channel has %d values for %d vertices" %
			[colors.size(), verts.size()])
		return
	if ground_rg.size() != verts.size() or ground_b_roughness.size() != verts.size():
		_fail("ground-material channels do not match the %d mesh vertices" % verts.size())
		return

	var rock_arrays := rock_mesh.surface_get_arrays(0)
	var sky_exposure: PackedColorArray = rock_arrays[Mesh.ARRAY_COLOR]
	var contact_count := 0
	var untouched_count := 0
	var strongest := 0.0
	for i in verts.size():
		var ground := Color(ground_rg[i].x, ground_rg[i].y, ground_b_roughness[i].x)
		var contact := colors[i].a
		if not ground.is_equal_approx(TEST_GROUND):
			_fail("vertex %d carries ground %s, expected the sampler's %s (%d sampler calls, mesh format %d)" %
				[i, ground, TEST_GROUND, material_calls[0], mesh.surface_get_format(0)])
			return
		if absf(ground_b_roughness[i].y - TEST_ROUGHNESS) > EPS:
			_fail("vertex %d carries roughness %.4f, expected %.4f" %
				[i, ground_b_roughness[i].y, TEST_ROUGHNESS])
			return
		if contact < -EPS or contact > 1.0 + EPS:
			_fail("vertex %d contact %.4f falls outside 0..1" % [i, contact])
			return
		# The pre-existing alpha is an independent sky-exposure mask. Contact
		# may fade with it but may never paint a carved interior wall.
		if contact > sky_exposure[i].a + EPS:
			_fail("vertex %d has contact %.4f above sky exposure %.4f — an interior wall entered the terrain path" %
				[i, contact, sky_exposure[i].a])
			return
		if contact > EPS:
			contact_count += 1
			strongest = maxf(strongest, contact)
		else:
			untouched_count += 1

	if contact_count == 0:
		_fail("flat ground produced zero contact vertices — the channel is vacuous")
		return
	if untouched_count == 0:
		_fail("every cave vertex entered the ground path — interiors and the far hull would change")
		return
	if strongest < 0.9:
		_fail("contact never becomes decisive (max %.3f)" % strongest)
		return

	# The fix is material data only. The generated rock and collision surface
	# must remain the exact same geometry.
	var baseline: Dictionary = CaveSystemGen.build_geometry(SEED)
	if CaveSystemGen.fingerprint(rock_mesh) != CaveSystemGen.fingerprint(baseline[&"mesh"]):
		_fail("terrain contact moved cave vertices — geometry/collision must stay unchanged")
		return
	if CaveSystemGen.fingerprint(mesh) != CaveSystemGen.fingerprint(rock_mesh):
		_fail("terrain-contact overlay does not follow the exact cave surface")
		return

	# Falsifiability: move the same terrain far below the massif. A hard-coded
	# or constant contact mask would still light up; a real terrain distance
	# signal must go fully dark.
	var far_cave := CaveSystemGen.new()
	add_child(far_cave)
	var far_ground := func(_x: float, _z: float) -> float:
		return -100.0
	Callable(far_cave, &"rebuild").call(far_ground, local_material)
	var far_mesh := _named_mesh(far_cave, &"TerrainContact")
	var far_arrays := far_mesh.surface_get_arrays(0)
	var far_data: PackedColorArray = far_arrays[Mesh.ARRAY_COLOR]
	for sample: Color in far_data:
		if sample.a > EPS:
			_fail("far-below control still has contact %.4f — channel is not derived from terrain distance" %
				sample.a)
			return

	print("TEST PASS: cave terrain contact — %d contact / %d untouched vertices, max %.3f; material payload exact; geometry unchanged; far-ground control dark" %
		[contact_count, untouched_count, strongest])
	get_tree().quit(0)


func _method_arg_count(object: Object, method_name: StringName) -> int:
	for method: Dictionary in object.get_method_list():
		if method[&"name"] == method_name:
			return (method[&"args"] as Array).size()
	return 0


func _named_mesh(cave: CaveSystemGen, child_name: StringName) -> ArrayMesh:
	var child := cave.get_node_or_null(NodePath(child_name))
	if child is MeshInstance3D and (child as MeshInstance3D).mesh is ArrayMesh:
		return (child as MeshInstance3D).mesh as ArrayMesh
	return null


func _rock_mesh(cave: CaveSystemGen) -> ArrayMesh:
	for child in cave.get_children():
		if child is MeshInstance3D and child.name != &"TerrainContact" \
				and (child as MeshInstance3D).mesh is ArrayMesh:
			return (child as MeshInstance3D).mesh as ArrayMesh
	return null


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL: cave terrain contact — %s" % message)
	get_tree().quit(1)
