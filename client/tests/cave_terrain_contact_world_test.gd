extends Node
## World integration regression for #345. The unit-level contact test proves
## CaveSystemGen can carry a supplied material; this proves the shipping world
## supplies the rendered terrain surface and the local GroundRegions substance.
##
## Run: godot --headless --path client res://tests/cave_terrain_contact_world_test.tscn

const EPS := 0.0001
const CONTACT_QUANTUM := 1.0 / 255.0 + EPS
const NORMAL_QUANTUM := 3.0 / 255.0 + EPS
const HEIGHT_QUANTUM := CaveSystemGen.TERRAIN_HEIGHT_RANGE * 2.0 / 255.0 + EPS


func _ready() -> void:
	var world := WorldGen.new()
	add_child(world)
	var cave := world.get_node_or_null("StarterCave") as CaveSystemGen
	if cave == null:
		_fail("WorldGen built no StarterCave")
		return
	var contact_mi := cave.get_node_or_null("TerrainContact") as MeshInstance3D
	if contact_mi == null or not contact_mi.mesh is ArrayMesh:
		_fail("shipping WorldGen supplied no local-ground material to StarterCave")
		return
	var rock_mi := _rock_mesh(cave)
	if rock_mi == null:
		_fail("StarterCave lost its rock mesh")
		return

	var contact_mesh := contact_mi.mesh as ArrayMesh
	var arrays := contact_mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var weights: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var ground_rg: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var ground_b_roughness: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var rock_colors: PackedColorArray = (rock_mi.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var terrain_mi := world.get_node_or_null("Terrain") as MeshInstance3D
	if terrain_mi == null or not terrain_mi.mesh is ArrayMesh:
		_fail("shipping world has no readable terrain color stream")
		return
	var terrain_arrays := (terrain_mi.mesh as ArrayMesh).surface_get_arrays(0)
	var terrain_colors: PackedColorArray = terrain_arrays[Mesh.ARRAY_COLOR]
	if verts.is_empty() or weights.size() != verts.size() \
			or ground_rg.size() != verts.size() or ground_b_roughness.size() != verts.size():
		_fail("terrain-contact material streams do not cover the cave surface")
		return

	var touched := 0
	var untouched := 0
	var surface_distinguishes_analytic := false
	var to_world := world.cave_to_world()
	for i in verts.size():
		var world_vertex: Vector3 = to_world * verts[i]
		var surface_y := world.surface_height_at(world_vertex.x, world_vertex.z)
		var local_surface_y := surface_y - to_world.origin.y
		var expected_contact := (
			1.0 - smoothstep(0.0, CaveSystemGen.TERRAIN_CONTACT_BAND,
				absf(verts[i].y - local_surface_y))
		) * rock_colors[i].a
		if absf(weights[i].a - expected_contact) > CONTACT_QUANTUM:
			_fail("vertex %d contact %.4f does not follow rendered surface %.4f (expected %.4f)" %
				[i, weights[i].a, surface_y, expected_contact])
			return

		var expected: Dictionary = world.ground_material_at(world_vertex.x, world_vertex.z)
		var ground := Color(ground_rg[i].x, ground_rg[i].y, ground_b_roughness[i].x)
		var rendered_baked := _rendered_terrain_color_at(
			terrain_colors, world_vertex.x, world_vertex.z)
		var rendered_ground := rendered_baked
		rendered_ground.a = 1.0
		if not ground.is_equal_approx(rendered_ground):
			_fail("vertex %d carries %s, not rendered terrain interpolation %s" %
				[i, ground, rendered_ground])
			return
		var rendered_roughness := clampf(0.97 + rendered_baked.a - 0.5, 0.0, 1.0)
		if absf(ground_b_roughness[i].y - rendered_roughness) > EPS:
			_fail("vertex %d roughness %.4f, not local ground %.4f" %
				[i, ground_b_roughness[i].y, rendered_roughness])
			return
		var encoded_normal := Vector2(weights[i].r, weights[i].g) * 2.0 - Vector2.ONE
		var expected_normal: Vector3 = expected[&"normal"]
		if encoded_normal.distance_to(Vector2(expected_normal.x, expected_normal.z)) > NORMAL_QUANTUM:
			_fail("vertex %d terrain normal XZ %s, not rendered face %s" %
				[i, encoded_normal, Vector2(expected_normal.x, expected_normal.z)])
			return
		var encoded_height := (
			weights[i].b - 0.5
		) * CaveSystemGen.TERRAIN_HEIGHT_RANGE * 2.0
		if absf(encoded_height - (expected[&"height"] as float)) > HEIGHT_QUANTUM:
			_fail("vertex %d terrain height %.4f, not rendered surface %.4f" %
				[i, encoded_height, expected[&"height"]])
			return

		if weights[i].a > EPS:
			touched += 1
			if absf(surface_y - world.height_at(world_vertex.x, world_vertex.z)) > 0.01:
				surface_distinguishes_analytic = true
		else:
			untouched += 1

	if touched == 0 or untouched == 0:
		_fail("shipping contact is vacuous (%d touched / %d untouched)" % [touched, untouched])
		return
	if not surface_distinguishes_analytic:
		_fail("contact never proves it sampled the rendered terrain rather than the smooth height field")
		return
	if CaveSystemGen.fingerprint(contact_mesh) != CaveSystemGen.fingerprint(rock_mi.mesh as ArrayMesh):
		_fail("terrain contact moved away from the rock surface")
		return

	print("TEST PASS: cave terrain world contact — %d touched / %d untouched; rendered surface and local material exact" %
		[touched, untouched])
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL: cave terrain world contact — %s" % message)
	get_tree().quit(1)


func _rock_mesh(cave: CaveSystemGen) -> MeshInstance3D:
	for child in cave.get_children():
		if child is MeshInstance3D and child.name != &"TerrainContact" \
				and (child as MeshInstance3D).mesh is ArrayMesh:
			return child as MeshInstance3D
	return null


## Independent oracle over the ArrayMesh stream _build_terrain actually sent
## to the renderer: two unindexed triangles (six colours) per grid cell.
func _rendered_terrain_color_at(
		colors: PackedColorArray, x: float, z: float) -> Color:
	var step := WorldGen.SIZE / WorldGen.QUADS
	var half := WorldGen.SIZE / 2.0
	var gx := (x + half) / step
	var gz := (z + half) / step
	var ix := mini(int(gx), WorldGen.QUADS - 1)
	var iz := mini(int(gz), WorldGen.QUADS - 1)
	var fx := gx - ix
	var fz := gz - iz
	var base := (iz * WorldGen.QUADS + ix) * 6
	if fx >= fz:
		return colors[base] * (1.0 - fx) \
			+ colors[base + 1] * (fx - fz) \
			+ colors[base + 2] * fz
	return colors[base + 3] * (1.0 - fz) \
		+ colors[base + 4] * fx \
		+ colors[base + 5] * (fz - fx)
