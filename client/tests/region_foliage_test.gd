extends Node

## Product-law and composition guard for #612's regional foliage preview.
##
## The break this catches is a region flag that is inert, leaks into the
## default world, or gives every named ground region the same cover profile.
## It exercises the real WorldGen scatter in both states; no synthetic field or
## mock can prove that the profiles reach the rendered placement path.

const FLAG_ENV := "WAR_REGION_FOLIAGE"
const DEFAULT_FINGERPRINT := "ba6074d1"
const EXPECTED_DENSITY_MULTIPLIERS := [1.0, 0.55, 0.70, 1.25]
const EXPECTED_KIND_MULTIPLIERS := [
	[1.0, 1.0, 1.0, 1.0],
	[0.35, 0.45, 0.85, 1.45],
	[0.45, 0.30, 1.65, 1.25],
	[1.25, 0.75, 0.55, 1.15],
]

var _failures: Array[String] = []


func _ready() -> void:
	var original := OS.get_environment(FLAG_ENV)
	OS.unset_environment(FLAG_ENV)
	var baseline := _build_world(0x6120)

	OS.set_environment(FLAG_ENV, "1")
	var enabled_a := _build_world(0x6121)
	var enabled_b := _build_world(0x6122)

	if original.is_empty():
		OS.unset_environment(FLAG_ENV)
	else:
		OS.set_environment(FLAG_ENV, original)

	_test_default_stays_identical(baseline)
	_test_enabled_scatter_is_real_and_deterministic(baseline, enabled_a, enabled_b)
	_test_each_region_owns_a_profile(baseline, enabled_a)
	_test_boundary_profiles_follow_all_region_shares()
	_test_enabled_scatter_keeps_world_safety(enabled_a)

	if _failures.is_empty():
		print(
			"TEST PASS — regional foliage is default-off, deterministic, and distinct across every ground region"
		)
	else:
		for failure in _failures:
			printerr("FAIL: %s" % failure)
		printerr("TEST FAIL — regional foliage (%d)" % _failures.size())
	get_tree().quit(0 if _failures.is_empty() else 1)


func _test_default_stays_identical(world: WorldGen) -> void:
	var placements := world.foliage_placements()
	if placements.size() != WorldGen.FOLIAGE_COUNT:
		_fail(
			(
				"default world scattered %d props instead of %d"
				% [placements.size(), WorldGen.FOLIAGE_COUNT]
			)
		)
		return
	var got := _fingerprint(placements)
	if got != DEFAULT_FINGERPRINT:
		_fail(
			(
				"unset %s changed the shipped foliage fingerprint: %s != %s"
				% [FLAG_ENV, got, DEFAULT_FINGERPRINT]
			)
		)


func _test_enabled_scatter_is_real_and_deterministic(
	baseline: WorldGen, enabled_a: WorldGen, enabled_b: WorldGen
) -> void:
	var base_fp := _fingerprint(baseline.foliage_placements())
	var enabled_fp := _fingerprint(enabled_a.foliage_placements())
	var second_fp := _fingerprint(enabled_b.foliage_placements())
	if enabled_a.foliage_placements().size() != WorldGen.FOLIAGE_COUNT:
		_fail(
			(
				"enabled world scattered %d props instead of the fixed budget %d"
				% [enabled_a.foliage_placements().size(), WorldGen.FOLIAGE_COUNT]
			)
		)
	if enabled_fp == base_fp:
		_fail(
			(
				"%s=1 produced the default placement fingerprint %s — the preview is inert"
				% [FLAG_ENV, enabled_fp]
			)
		)
	if enabled_fp != second_fp:
		_fail("enabled builds leaked global RNG or wall clock: %s != %s" % [enabled_fp, second_fp])


func _test_each_region_owns_a_profile(baseline: WorldGen, enabled: WorldGen) -> void:
	var sites := GroundRegions.sites(WorldGen.WORLD_SEED, WorldGen.SIZE)
	for region_index in GroundRegions.REGIONS.size():
		var probe := _decided_density_probe(baseline, sites, region_index)
		if probe == Vector2(INF, INF):
			_fail(
				(
					"region %s has no decided, density-bearing probe"
					% str(GroundRegions.REGIONS[region_index][&"name"])
				)
			)
			continue

		var base_density := baseline._foliage_density_at(probe.x, probe.y)
		var enabled_density := enabled._foliage_density_at(probe.x, probe.y)
		var got_density := enabled_density / base_density
		var want_density: float = EXPECTED_DENSITY_MULTIPLIERS[region_index]
		if not is_equal_approx(got_density, want_density):
			_fail(
				(
					"region %s density multiplier %.3f != authored %.3f"
					% [
						str(GroundRegions.REGIONS[region_index][&"name"]),
						got_density,
						want_density,
					]
				)
			)

		var base_kinds := baseline._foliage_kind_weights_at(probe.x, probe.y)
		var enabled_kinds := enabled._foliage_kind_weights_at(probe.x, probe.y)
		var want_kinds: Array = EXPECTED_KIND_MULTIPLIERS[region_index]
		for kind in FoliageGen.KIND_COUNT:
			var got_kind: float = enabled_kinds[kind] / base_kinds[kind]
			var want_kind: float = want_kinds[kind]
			if not is_equal_approx(got_kind, want_kind):
				_fail(
					(
						"region %s kind %d multiplier %.3f != authored %.3f"
						% [
							str(GroundRegions.REGIONS[region_index][&"name"]),
							kind,
							got_kind,
							want_kind,
						]
					)
				)


func _test_boundary_profiles_follow_all_region_shares() -> void:
	var sites := GroundRegions.sites(WorldGen.WORLD_SEED, WorldGen.SIZE)
	var probe := _blended_probe(sites)
	if probe == Vector2(INF, INF):
		_fail("shipped region layout has no blended foliage probe")
		return

	var at := GroundRegions.region_for(sites, probe.x, probe.y)
	var shares: PackedFloat32Array = at[&"shares"]
	var want_density := 0.0
	var want_kinds := [0.0, 0.0, 0.0, 0.0]
	for region_index in GroundRegions.REGIONS.size():
		var share := shares[region_index]
		if share <= 0.0:
			continue
		var region: Dictionary = GroundRegions.REGIONS[region_index]
		want_density += float(region[&"foliage_density"]) * share
		var kinds: Array = region[&"foliage_kinds"]
		for kind in FoliageGen.KIND_COUNT:
			want_kinds[kind] += float(kinds[kind]) * share

	var got := GroundRegions.foliage_for(sites, probe.x, probe.y)
	if not is_equal_approx(float(got[&"density"]), want_density):
		_fail("boundary density follows the owner instead of continuous region shares")
	var got_kinds: Array = got[&"kinds"]
	for kind in FoliageGen.KIND_COUNT:
		if not is_equal_approx(float(got_kinds[kind]), float(want_kinds[kind])):
			_fail("boundary kind %d follows the owner instead of continuous region shares" % kind)


func _test_enabled_scatter_keeps_world_safety(world: WorldGen) -> void:
	var placements := world.foliage_placements()
	var keep_outs := world._foliage_keep_outs()
	for placement: Dictionary in placements:
		var pos: Vector3 = placement["pos"]
		var ground := world.surface_height_at(pos.x, pos.z)
		if ground <= WorldGen.NO_GROUND or absf(pos.y - ground) > 1.0:
			_fail("enabled prop at (%.1f, %.1f) does not rest on generated ground" % [pos.x, pos.z])
			return
		for keep_out: Array in keep_outs:
			var centre: Vector2 = keep_out[0]
			var radius: float = keep_out[1]
			if Vector2(pos.x, pos.z).distance_to(centre) < radius:
				_fail(
					(
						"enabled prop at (%.1f, %.1f) entered a %.1f m landmark keep-out"
						% [pos.x, pos.z, radius]
					)
				)
				return

	var rendered := 0
	for batch in world.find_children("Foliage_*", "MultiMeshInstance3D", false, false):
		var multimesh_batch := batch as MultiMeshInstance3D
		rendered += multimesh_batch.multimesh.instance_count
		if _has_physics(multimesh_batch):
			_fail("enabled foliage batch %s adds traversal collision" % str(batch.name))
	if rendered != placements.size():
		_fail(
			(
				"enabled preview renders %d props but records %d placements"
				% [rendered, placements.size()]
			)
		)


func _blended_probe(sites: Array[GroundRegions.Site]) -> Vector2:
	for z_step in range(-50, 51):
		for x_step in range(-50, 51):
			var probe := Vector2(x_step * 2.0, z_step * 2.0)
			var at := GroundRegions.region_for(sites, probe.x, probe.y)
			var blend: float = at[&"blend"]
			if blend >= 0.55 and blend <= 0.85:
				return probe
	return Vector2(INF, INF)


func _decided_density_probe(
	world: WorldGen, sites: Array[GroundRegions.Site], region_index: int
) -> Vector2:
	for site in sites:
		if site.region != region_index:
			continue
		for dz in range(-12, 13, 2):
			for dx in range(-12, 13, 2):
				var probe := Vector2(site.x + dx, site.z + dz)
				var at := GroundRegions.region_for(sites, probe.x, probe.y)
				if at[&"region"] != region_index or float(at[&"blend"]) < 0.999:
					continue
				var density := world._foliage_density_at(probe.x, probe.y)
				if density >= 0.20 and density <= 0.60:
					return probe
	return Vector2(INF, INF)


func _build_world(global_rng_seed: int) -> WorldGen:
	seed(global_rng_seed)
	var world := WorldGen.new()
	add_child(world)
	return world


func _fingerprint(placements: Array[Dictionary]) -> String:
	var acc := PackedInt32Array()
	for placement in placements:
		var pos: Vector3 = placement["pos"]
		acc.append(roundi(pos.x * 1000.0))
		acc.append(roundi(pos.y * 1000.0))
		acc.append(roundi(pos.z * 1000.0))
	return "%x" % hash(acc)


func _has_physics(node: Node) -> bool:
	if node is CollisionObject3D or node is CollisionShape3D:
		return true
	for child in node.get_children():
		if _has_physics(child):
			return true
	return false


func _fail(message: String) -> void:
	_failures.append(message)
