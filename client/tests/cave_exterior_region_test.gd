extends Node
## Guards for #291 — the starter massif's weathered exterior follows the ground
## region it stands in.
##
## The exterior palette was authored to sit between the ground's ash and rock so
## the massif reads as stone of the same landscape. Regions (#260) then made that
## ground vary per place while the rock stayed on one hard-coded triple, so the
## cave mouth opened onto pale scoured ground beneath a warm rock face.
##
## Run: godot --headless --path client res://tests/cave_exterior_region_test.tscn
##
## The laws, one arm each:
##   1. THE BASELINE IS EXACT. Where `ashflats` stands — the shrine's own ground,
##      pinned by `ground_regions_test` — the payload is a zero delta and a unit
##      value, so the authored palette ships bit-for-bit unchanged. This is what
##      keeps every frame already captured on the baseline reading as itself.
##   2. IT ACTUALLY TRACKS. At the massif the payload is the bonepale difference,
##      not zero. Without this arm law 1 is satisfied by a stream of zeroes.
##   3. THE HULL CARRIES IT PER VERTEX. The massif's footprint spans two regions,
##      so one material-wide palette would paint part of it with the wrong stone.
##      More than one distinct payload must reach the mesh.
##   4. NO WORLD MEANS BASELINE. The standalone taste scene builds with no terrain
##      callable and must still render the authored palette.
##   5. GEOMETRY DOES NOT MOVE. The payload rides UV/UV2; vertices, indices and
##      the fingerprint hashed from them are untouched.

const EPS := 0.0001

var _failures: Array[String] = []


func _ready() -> void:
	var world := WorldGen.new()
	add_child(world)

	_test_baseline_is_exact(world)
	_test_massif_tracks_its_region(world)
	_test_hull_carries_payload_per_vertex(world)
	_test_no_world_means_baseline()
	_test_geometry_is_untouched(world)

	if _failures.is_empty():
		print("TEST PASS: cave exterior region palette")
		get_tree().quit(0)
	else:
		for f in _failures:
			push_error(f)
			print("TEST FAIL: cave exterior region palette — %s" % f)
		get_tree().quit(1)


func _fail(message: String) -> void:
	_failures.append(message)


## LAW 1 — the baseline region reproduces the authored palette exactly.
##
## The origin is `ashflats` by construction (the shrine's ground is pinned), so
## the delta must be exactly zero and the value exactly one. Exact, not approx:
## these are the numbers that decide whether an already-captured frame moves.
func _test_baseline_is_exact(world: WorldGen) -> void:
	var at: Dictionary = world.ground_material_at(0.0, 0.0)
	var name := world.region_name_at(0.0, 0.0)
	if name != &"ashflats":
		_fail("origin is %s, not the pinned baseline ashflats — law 1 is testing " % name
			+ "the wrong ground")
		return
	var delta: Vector3 = at[&"region_rock_delta"]
	if delta != Vector3.ZERO:
		_fail("baseline rock delta is %s, not zero: the authored exterior palette " % delta
			+ "would ship shifted on the shrine's own ground")
	var value: float = at[&"region_ash_value"]
	if value != 1.0:
		_fail("baseline ash value is %.9f, not exactly 1.0: the authored ash would " % value
			+ "ship scaled on the shrine's own ground")


## LAW 2 — off the baseline the payload is the region's real difference.
##
## Without this arm a stream of zeroes satisfies law 1 perfectly, which is
## exactly the pre-#291 behaviour this suite exists to refuse.
func _test_massif_tracks_its_region(world: WorldGen) -> void:
	var site := WorldGen.CAVE_SITE
	var name := world.region_name_at(site.x, site.y)
	if name != &"bonepale":
		_fail("the massif now stands in %s, not bonepale — the expected palette " % name
			+ "below no longer describes its ground")
		return
	var at: Dictionary = world.ground_material_at(site.x, site.y)
	var delta: Vector3 = at[&"region_rock_delta"]
	var expected := _expected_rock_delta(&"bonepale")
	if delta.distance_to(expected) > EPS:
		_fail("massif rock delta is %s, not bonepale's %s" % [delta, expected])
	var value: float = at[&"region_ash_value"]
	var expected_value := _expected_ash_value(&"bonepale")
	if absf(value - expected_value) > EPS:
		_fail("massif ash value is %.4f, not bonepale's %.4f" % [value, expected_value])
	# The whole point: it must differ from the baseline by a readable amount.
	if delta.length() <= EPS:
		_fail("massif rock delta is zero on bonepale ground — the exterior is still "
			+ "the baseline triple")


## LAW 3 — the hull carries the region per vertex, not once for the material.
##
## Measured on the shipped seed: the footprint spans bonepale and ashflats, with
## about a third of it inside a blend band. A single material-wide palette would
## therefore paint the ashflats side of the massif with bonepale stone, so this
## arm pins that more than one distinct payload actually reaches the mesh.
func _test_hull_carries_payload_per_vertex(world: WorldGen) -> void:
	var cave := world.get_node_or_null("StarterCave") as CaveSystemGen
	if cave == null:
		_fail("WorldGen built no StarterCave")
		return
	var rock := _rock_mesh(cave)
	if rock == null:
		_fail("StarterCave lost its rock mesh")
		return
	var arrays := (rock.mesh as ArrayMesh).surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uv: Variant = arrays[Mesh.ARRAY_TEX_UV]
	var uv2: Variant = arrays[Mesh.ARRAY_TEX_UV2]
	if uv == null or uv2 == null:
		_fail("the massif hull carries no region arrays — the exterior cannot follow "
			+ "its ground")
		return
	var region_uv: PackedVector2Array = uv
	var region_uv2: PackedVector2Array = uv2
	if region_uv.size() != verts.size() or region_uv2.size() != verts.size():
		_fail("region payload covers %d/%d hull vertices" %
			[mini(region_uv.size(), region_uv2.size()), verts.size()])
		return

	var to_world := world.cave_to_world()
	var distinct := {}
	for i in verts.size():
		# Every vertex must agree with the world's own answer at its position.
		var w: Vector3 = to_world * verts[i]
		var expected: Dictionary = world.ground_material_at(w.x, w.z)
		var expected_delta: Vector3 = expected[&"region_rock_delta"]
		var got := Vector3(region_uv[i].x, region_uv[i].y, region_uv2[i].x)
		if got.distance_to(expected_delta) > EPS:
			_fail("hull vertex %d carries rock delta %s, not the ground's %s at %s" %
				[i, got, expected_delta, w])
			return
		if absf(region_uv2[i].y - float(expected[&"region_ash_value"])) > EPS:
			_fail("hull vertex %d carries ash value %.4f, not the ground's %.4f" %
				[i, region_uv2[i].y, expected[&"region_ash_value"]])
			return
		distinct["%.3f,%.3f,%.3f" % [got.x, got.y, got.z]] = true

	if distinct.size() < 2:
		_fail("the whole hull carries one palette (%d distinct) — a footprint spanning "
			% distinct.size() + "two regions cannot be described by one value")


## LAW 4 — no world, no region: the standalone taste scene keeps its palette.
##
## `rebuild()` with no callables is how the cave's own scene builds. A zero
## delta and a unit value are what make the shader ship its authored uniforms,
## and a non-positive value is the shader's "no region data" signal — so a unit
## value here is load-bearing, not cosmetic.
func _test_no_world_means_baseline() -> void:
	var built := CaveSystemGen.build_geometry(WorldGen.CAVE_SEED)
	var mesh: ArrayMesh = built["mesh"]
	var arrays := mesh.surface_get_arrays(0)
	var uv: Variant = arrays[Mesh.ARRAY_TEX_UV]
	var uv2: Variant = arrays[Mesh.ARRAY_TEX_UV2]
	if uv == null or uv2 == null:
		_fail("standalone cave carries no region arrays at all")
		return
	var region_uv: PackedVector2Array = uv
	var region_uv2: PackedVector2Array = uv2
	for i in region_uv.size():
		if region_uv[i] != Vector2.ZERO or region_uv2[i].x != 0.0:
			_fail("standalone cave vertex %d carries rock delta (%s, %.4f), not zero" %
				[i, region_uv[i], region_uv2[i].x])
			return
		if region_uv2[i].y != 1.0:
			_fail("standalone cave vertex %d carries ash value %.4f, not 1.0 — the "
				% [i, region_uv2[i].y] + "taste scene would not render its own palette")
			return


## LAW 5 — the payload rides spare channels; the massif itself does not move.
##
## `CaveSystemGen.fingerprint` and the determinism suite's `_world_fingerprint`
## both hash ARRAY_VERTEX alone, and the collision trimesh is built from
## vertices and indices, so a region payload in UV/UV2 cannot move the rock a
## player walks into. What this arm can pin locally is that adding it left the
## geometry reproducible: two builds of one seed agree vertex-for-vertex, and
## the fingerprint is stable across them.
func _test_geometry_is_untouched(_world: WorldGen) -> void:
	var first: ArrayMesh = CaveSystemGen.build_geometry(WorldGen.CAVE_SEED)["mesh"]
	var second: ArrayMesh = CaveSystemGen.build_geometry(WorldGen.CAVE_SEED)["mesh"]
	var a: PackedVector3Array = first.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var b: PackedVector3Array = second.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	if a.is_empty():
		_fail("cave build produced no geometry")
		return
	if a != b:
		_fail("cave geometry is not reproducible across two builds of one seed")
		return
	if CaveSystemGen.fingerprint(first) != CaveSystemGen.fingerprint(second):
		_fail("cave fingerprint is not stable across two builds of one seed")


func _expected_rock_delta(region: StringName) -> Vector3:
	var base: Dictionary = GroundRegions.REGIONS[0]
	var base_rock: Color = base[&"rock"]
	for reg: Dictionary in GroundRegions.REGIONS:
		if reg[&"name"] == region:
			var rock: Color = reg[&"rock"]
			return Vector3(rock.r - base_rock.r, rock.g - base_rock.g, rock.b - base_rock.b)
	return Vector3.ZERO


func _expected_ash_value(region: StringName) -> float:
	var base: Dictionary = GroundRegions.REGIONS[0]
	for reg: Dictionary in GroundRegions.REGIONS:
		if reg[&"name"] == region:
			return (reg[&"ash"] as Color).get_luminance() / (base[&"ash"] as Color).get_luminance()
	return 1.0


## The LIVE hull, which is not the first one.
##
## `CaveSystemGen._ready` builds once with no callables, and the world then
## rebuilds with them. `rebuild` frees the first pass with `queue_free`, which
## is DEFERRED — so within the same frame the cave still holds a stale hull, and
## it sits at child 0 ahead of the real one. That stale mesh was built without a
## terrain callable, so it carries the baseline payload: a helper that takes the
## first match reads zeroes and reports the feature missing on a build where it
## is present. Skip anything already queued for deletion.
func _rock_mesh(cave: CaveSystemGen) -> MeshInstance3D:
	for child in cave.get_children():
		if child is MeshInstance3D and child.name != &"TerrainContact" \
				and not child.is_queued_for_deletion() \
				and (child as MeshInstance3D).mesh is ArrayMesh:
			return child as MeshInstance3D
	return null
