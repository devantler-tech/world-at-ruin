extends Node
## Catches a shader-only preview, changed base terrain and lazy/fresh disagreement.

var _failed := false


func _ready() -> void:
	OS.unset_environment("WAR_REGION_STONE")
	OS.unset_environment("WAR_GROUND_PLATES")
	var world := WorldGen.new()
	add_child(world)
	var original := world.foliage_placements()
	var terrain := _terrain(world)
	world.set_ground_plates_enabled(true)
	var neutral := world.ground_plate_tops()
	world.set_ground_plates_enabled(true, true)
	var regional := world.ground_plate_tops()
	if regional == neutral or regional.is_empty():
		_fail("opt-in did not change the actual built stone coverage")
	_check_materials(world, true)
	_check_decided_coverage(world)
	_rebuild_cave(world)
	_check_materials(world, true)
	var identities := {}
	for top: Dictionary in regional:
		if identities.has(top[&"identity"]):
			_fail("a region boundary built one slab twice")
		identities[top[&"identity"]] = true
	OS.set_environment("WAR_REGION_STONE", "1")
	OS.set_environment("WAR_GROUND_PLATES", "1")
	var fresh := WorldGen.new()
	add_child(fresh)
	OS.unset_environment("WAR_REGION_STONE")
	OS.unset_environment("WAR_GROUND_PLATES")
	if fresh.ground_plate_tops() != regional \
			or fresh.ground_plate_rubble != world.ground_plate_rubble:
		_fail("fresh and live regional opt-in disagree about tops or edge rubble")
	world.set_ground_plates_enabled(true, false)
	_check_materials(world, false)
	if world.ground_plate_tops() != neutral:
		_fail("regional opt-out did not restore the complete original slab field")
	world.set_ground_plates_enabled(false)
	_rebuild_cave(world)
	_check_materials(world, false, false)
	if _terrain(world) != terrain or world.foliage_placements() != original \
			or world.visible_foliage_placements != original:
		_fail("regional preview changed the base terrain or original cover")
	OS.set_environment("WAR_REGION_STONE", "1")
	var regional_only := WorldGen.new()
	add_child(regional_only)
	_check_materials(regional_only, true, false)
	if not regional_only.ground_plate_tops().is_empty() or _terrain(regional_only) != terrain:
		_fail("the regional flag alone built plates or changed base terrain")
	OS.set_environment("WAR_REGION_STONE", "true")
	OS.set_environment("WAR_GROUND_PLATES", "1")
	var malformed := WorldGen.new()
	add_child(malformed)
	OS.unset_environment("WAR_REGION_STONE")
	OS.unset_environment("WAR_GROUND_PLATES")
	_check_materials(malformed, false)
	if malformed.ground_plate_tops() != neutral:
		_fail("a malformed regional flag activated the preview")
	if not _failed:
		print("TEST PASS: regional stone world — fresh/live equality, unique slabs, both shaders, restored opt-out and unchanged base terrain/foliage")
	get_tree().quit(1 if _failed else 0)


func _check_materials(world: WorldGen, enabled: bool, plates: bool = true) -> void:
	var terrain := world.get_node("Terrain") as MeshInstance3D
	var cave := world.get_node("StarterCave") as CaveSystemGen
	var materials: Array[ShaderMaterial] = [
		terrain.mesh.surface_get_material(0) as ShaderMaterial,
		cave.get("_contact_material") as ShaderMaterial,
	]
	for material in materials:
		if material == null or material.get_shader_parameter("region_stone_enabled") != enabled:
			_fail("the terrain and cave contact do not share the regional opt-in")
			continue
		if material.get_shader_parameter("plates_enabled") != plates:
			_fail("a cave rebuild forgot the live ground plate opt-in")
		var sites: PackedVector3Array = material.get_shader_parameter("stone_region_sites")
		var profiles: PackedVector2Array = material.get_shader_parameter("stone_region_profiles")
		if sites.size() != 9 or profiles.size() != 4 \
				or not profiles[2].is_equal_approx(Vector2(0.28, 0.20)):
			_fail("the actual material has no complete authored regional profile data")


func _terrain(world: WorldGen) -> String:
	var terrain := world.get_node("Terrain") as MeshInstance3D
	return var_to_bytes(terrain.mesh.surface_get_arrays(0)).hex_encode().sha256_text()


func _check_decided_coverage(world: WorldGen) -> void:
	var sites := GroundRegions.sites(WorldGen.WORLD_SEED, WorldGen.SIZE)
	var field := ExposedSlabField.new()
	var built := {}
	for top: Dictionary in world.ground_plate_tops():
		built[top[&"identity"]] = true
	var eligible := [0, 0, 0, 0]
	var exposed := [0, 0, 0, 0]
	for identity in field.candidate_identities(WorldGen.WORLD_SEED, WorldGen.SIZE):
		var point := field.site_for(identity)
		if absf(point.x) >= WorldGen.SIZE * 0.5 or absf(point.y) >= WorldGen.SIZE * 0.5 \
				or not field.is_slab_identity(identity):
			continue
		var region := GroundRegions.region_for(sites, point.x, point.y)
		if float(region[&"blend"]) != 1.0:
			continue
		var index := int(region[&"region"])
		eligible[index] += 1
		if built.has(identity):
			exposed[index] += 1
	if eligible[0] < 50 or eligible[2] < 50:
		_fail("the actual world contains too few decided ash/bone slab candidates")
		return
	var buried := float(exposed[0]) / float(eligible[0])
	var scoured := float(exposed[2]) / float(eligible[2])
	if scoured <= buried * 2.0:
		_fail("normalized built stone coverage does not distinguish scoured and buried regions")
	print("REGIONAL COVERAGE: buried %.6f, scoured %.6f" % [buried, scoured])


func _rebuild_cave(world: WorldGen) -> void:
	var cave := world.get_node("StarterCave") as CaveSystemGen
	var transform := cave.transform
	cave.rebuild(func(x: float, z: float) -> float:
		var point := transform * Vector3(x, 0.0, z)
		var height := world.surface_height_at(point.x, point.z)
		if height <= WorldGen.NO_GROUND + 1.0:
			height = world.height_at(point.x, point.z)
		return height - transform.origin.y,
	func(x: float, z: float) -> Dictionary:
		var point := transform * Vector3(x, 0.0, z)
		return world.ground_material_at(point.x, point.z))


func _fail(message: String) -> void:
	_failed = true
	print("TEST FAIL: " + message)
