extends Node
## Frozen public outputs from main 7f9fa91, before helper extraction. The
## baseline is generated once from the original implementations, never from
## the helpers under test.

func _ready() -> void:
	var actual := _observations()
	var capture := OS.get_environment("WAR_SHAPE_BASELINE_OUT")
	if capture != "":
		var file := FileAccess.open(capture, FileAccess.WRITE)
		file.store_string(JSON.stringify(actual, "\t") + "\n")
		file.close()
		print("BASELINE CAPTURED")
		get_tree().quit()
		return
	var file := FileAccess.open("res://tests/data/production_shapes_baseline.json", FileAccess.READ)
	if file == null:
		print("TEST FAIL -- original production baseline missing")
		get_tree().quit(1)
		return
	var expected = JSON.parse_string(file.get_as_text())
	if actual != expected:
		print("TEST FAIL -- production shape outputs changed: ", JSON.stringify(actual))
		get_tree().quit(1)
		return
	print("TEST PASS -- original names, RNG state, recipes and cutout pixels remain exact")
	get_tree().quit()


func _observations() -> Dictionary:
	var names := []
	var recipes := []
	var textures := []
	for seed_value in [0, 1, 129, 987654]:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value
		var row := []
		for _i in 8:
			row.append(NpcGen.forge_name(rng))
			row.append(CreatureGen.forge_name(rng))
		names.append({"names": row, "next": str(rng.randi())})
	for index in 32:
		var label := "Shape baseline %d" % index
		recipes.append(JSON.stringify(CreatureGen.recipe_for(label)))
		recipes.append(JSON.stringify(NpcGen.recipe_for(label, NpcGen.ARCHETYPE_VILLAGER)))
		recipes.append(JSON.stringify(NpcGen.recipe_for(label, NpcGen.ARCHETYPE_DRIFTER)))
	for seed_value in [0, 13, 104729]:
		for count in [0, 1, 7, 20]:
			for texture in [FoliageArt.leaf_texture(seed_value, count), FoliageArt.blade_texture(seed_value, count)]:
				var img: Image = texture.get_image()
				var ctx := HashingContext.new()
				ctx.start(HashingContext.HASH_SHA256)
				ctx.update(img.get_data())
				textures.append({"sha": ctx.finish().hex_encode(), "mips": str(img.get_mipmap_count())})
	return {"names": names, "recipes": recipes, "textures": textures, "geometry": _geometry_observations(), "thresholds": _threshold_observations()}


## Geometric and region outputs captured from original production code, including
## empty terrain, both triangle halves, exact positive edges and outside bounds.
func _geometry_observations() -> Dictionary:
	var world := WorldGen.new()
	world._region_sites = GroundRegions.sites(WorldGen.WORLD_SEED, WorldGen.SIZE)
	var points := [
		Vector2(-110.01, 0.0), Vector2(-110.0, -110.0),
		Vector2(110.0, 110.0), Vector2(110.01, 0.0),
		Vector2(-109.6, -109.2), Vector2(-109.2, -109.6),
		Vector2(0.0, 0.0), Vector2(15.3, -42.1), Vector2(-42.1, 15.3),
	]
	var terrain := []
	for filled in [false, true]:
		if filled:
			for index in (WorldGen.QUADS + 1) * (WorldGen.QUADS + 1):
				world._heights.append(float((index * 19) % 101) / 13.0 - 3.0)
		for p: Vector2 in points:
			terrain.append([
				"%.6f" % world.surface_height_at(p.x, p.y),
				str(world.surface_normal_at(p.x, p.y)),
				str(world.rendered_ground_color_at(p.x, p.y)),
			])
	var regions := []
	for z in range(-110, 111, 11):
		for x in range(-110, 111, 11):
			regions.append(JSON.stringify(GroundRegions.foliage_for(world._region_sites, x, z)))
			regions.append(JSON.stringify(GroundRegions.landform_for(world._region_sites, x, z)))
	var meshes := []
	for seed_value in [0, 1, 1409]:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value
		var rubble := world._rubble_chunk_mesh(rng, Vector3(1.7, 0.9, 2.3))
		var arrays := rubble.surface_get_arrays(0)
		meshes.append(_bytes_hash(var_to_bytes(arrays)))
		meshes.append(str(rng.randi()))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	world._add_box(st, Vector3(-1.7, -2.2, -0.3), Vector3(1.2, 3.3, 0.8))
	meshes.append(_bytes_hash(var_to_bytes(st.commit_to_arrays())))
	var polygons := []
	for polygon in [
		PackedVector2Array([Vector2(-2.01, 0.0), Vector2(2.0, 0.0), Vector2(0.0, 2.01)]),
		PackedVector2Array([Vector2(-110, -110), Vector2(-108.28125, -110), Vector2(-110, -108.28125)]),
	]:
		var pieces := ExposedSlabGeometry.split_by_terrain_grid(polygon, 110.0, 1.71875)
		polygons.append(_bytes_hash(var_to_bytes(pieces)))
		world._index_ground_plate_tops([{&"polygon": polygon, &"thickness": 0.12}])
		polygons.append(str(world._ground_plate_index))
	world.free()
	return {"terrain": terrain, "regions": regions, "meshes": meshes, "polygons": polygons}


func _bytes_hash(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


func _threshold_observations() -> Array:
	var rows := []
	for value in [-0.0349, -0.03, -0.0299, -0.005, 0.0, 0.005, 0.0299, 0.03, 0.0349]:
		var npc := {}
		var creature := {}
		NpcGen._put(npc, "probe", value)
		CreatureGen._put(creature, "probe", value)
		rows.append([JSON.stringify(npc), JSON.stringify(creature), str(NpcGen._q(value)), str(CreatureGen._q(value))])
	return rows
