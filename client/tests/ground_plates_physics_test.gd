extends Node
## #548: the raised exposed-stone slabs are solid where they are drawn, and a
## walking player can cross them.
##
## Runs against the real generated world with `WAR_GROUND_PLATES=1`, headless:
## physics needs no GPU, so every property here is checked on the shipped seed
## rather than on a hand-built stand-in.
##
##  1. COLLISION IS THE DRAWN SURFACE — a ray down onto every built top lands on
##     its collision at [method WorldGen.walkable_height_at]; one just past every
##     top edge lands on whatever is there, and on the TERRAIN where no other top
##     is, so the collision bridges nothing the render leaves open.
##  2. THE QUERY PINS BOTH OUTCOMES — raised tops answer ground + thickness,
##     everywhere else answers exactly [method WorldGen.surface_height_at].
##  3. A PLAYER CROSSES — up the thickest lip in the snag regime, back down it,
##     from a thinner slab onto a thicker neighbour, and through a point where
##     three slabs meet: arriving on time, settled on the surface, never below
##     the base ground and without dropping into the air on the way down.
##  4. SAME SEED, SAME STONE — a second fresh build produces the same render
##     mesh, collision faces and query answers, bit for bit.
##  5. OFF IS OFF — hiding the overlay removes its collision and the query falls
##     back to the base ground, and a player that was never given a step moves
##     with the engine's own floor snap.

const HALF_WORLD := 100.0
const RAY_TOLERANCE := 0.002
## A capsule rests on its rounded base, so at an edge its origin can sit a few
## centimetres off the surface directly beneath it. Settled on open stone or
## ash it sits within this.
const SETTLE_TOLERANCE := 0.03
## The crossing must not take longer than this multiple of the straight-line
## time at walking speed: a snag shows up as a stall, not a slower stride.
const TIME_FACTOR := 1.6
## How many of the thickest head-on lips to try unaided before concluding none
## is in the snag regime.
const LIP_CANDIDATES := 20

var _failed := false
## Everything solid in the world except the terrain and the raised stone: the
## rays below judge only those two, and a ruin block standing on a slab would
## otherwise read as the collision bridging open ground.
var _not_ground: Array[RID] = []


func _ready() -> void:
	OS.set_environment("WAR_GROUND_PLATES", "1")
	var world := WorldGen.new()
	world.name = "World"
	add_child(world)
	OS.unset_environment("WAR_GROUND_PLATES")
	for _i in 3:
		await get_tree().physics_frame
	var tops := world.ground_plate_tops()
	if tops.size() < 100:
		_fail("only %d raised tops were built — the checks below would be near-vacuous" % tops.size())
		return
	if world.ground_plates_step_height() <= ExposedSlabGeometry.MAX_THICKNESS:
		_fail("the world asks for a %.3f m step, not above its thickest %.3f m lip" %
			[world.ground_plates_step_height(), ExposedSlabGeometry.MAX_THICKNESS])
		return

	if not _check_collision_is_the_surface(world, tops):
		return
	if not _check_query_both_ways(world, tops):
		return
	if not await _check_crossings(world, tops):
		return
	if not await _check_same_seed(world):
		return
	if not await _check_off_is_off(world, tops):
		return
	print("TEST PASS — %d raised tops are solid exactly where drawn, a player climbs, descends and "
		% tops.size() + "crosses them, two builds agree bit for bit, and off restores the base ground")
	get_tree().quit(0)


func _check_collision_is_the_surface(world: WorldGen, tops: Array[Dictionary]) -> bool:
	var space := get_viewport().world_3d.direct_space_state
	var on_tops := 0
	var on_ground := 0
	for top in tops:
		var polygon := top[&"polygon"] as PackedVector2Array
		var centre := ExposedSlabGeometry.centroid(polygon)
		var hit := _ray_down(space, world, centre)
		if hit.is_empty() or String((hit[&"collider"] as Node).name) != WorldGen.GROUND_PLATES_BODY:
			return _fail("no raised-top collision under the centre of the slab at %s" % centre)
		if absf(float(hit[&"y"]) - world.walkable_height_at(centre.x, centre.y)) > RAY_TOLERANCE:
			return _fail("the slab at %s is solid at %.4f but drawn at %.4f" %
				[centre, hit[&"y"], world.walkable_height_at(centre.x, centre.y)])
		on_tops += 1
		for index in polygon.size():
			var a := polygon[index]
			var b := polygon[(index + 1) % polygon.size()]
			if a.distance_to(b) < 0.2:
				continue
			var mid := (a + b) * 0.5
			var outward := Vector2(b.y - a.y, a.x - b.x).normalized()
			if outward.dot(mid - centre) < 0.0:
				outward = -outward
			var past := mid + outward * 0.05
			if absf(past.x) > HALF_WORLD or absf(past.y) > HALF_WORLD or world.cave_protects(past.x, past.y):
				continue
			var beyond := _ray_down(space, world, past)
			if beyond.is_empty():
				return _fail("nothing is solid just past the edge of the slab at %s" % centre)
			var expected := world.walkable_height_at(past.x, past.y)
			if absf(float(beyond[&"y"]) - expected) > RAY_TOLERANCE:
				return _fail(("just past the edge of the slab at %s the surface is solid at %.4f but "
					+ "should be %.4f — the collision bridges ground the render leaves open")
					% [centre, beyond[&"y"], expected])
			if world.ground_plate_thickness_at(past.x, past.y) == 0.0:
				if String((beyond[&"collider"] as Node).name) != "TerrainBody":
					return _fail("past the slab at %s the ray met %s, not the terrain" %
						[centre, (beyond[&"collider"] as Node).name])
				on_ground += 1
	if on_ground < 100:
		return _fail("only %d edge samples landed on open ground — the no-bridging check is near-vacuous" % on_ground)
	print("collision: %d tops and %d open-ground edge samples match the drawn surface" % [on_tops, on_ground])
	return true


func _check_query_both_ways(world: WorldGen, tops: Array[Dictionary]) -> bool:
	var top := tops[0]
	var centre := ExposedSlabGeometry.centroid(top[&"polygon"] as PackedVector2Array)
	var raised := world.walkable_height_at(centre.x, centre.y)
	var base := world.surface_height_at(centre.x, centre.y)
	if absf(raised - (base + float(top[&"thickness"]))) > 0.000001:
		return _fail("a raised top reads %.6f, not its ground %.6f plus its %.3f m lift" %
			[raised, base, top[&"thickness"]])
	var bare := 0
	for x in range(-100, 101, 5):
		for z in range(-100, 101, 5):
			if world.ground_plate_thickness_at(x, z) != 0.0:
				continue
			if world.walkable_height_at(x, z) != world.surface_height_at(x, z):
				return _fail("open ground at (%d, %d) reads %.6f, not the base %.6f" %
					[x, z, world.walkable_height_at(x, z), world.surface_height_at(x, z)])
			bare += 1
	if bare < 500:
		return _fail("only %d grid samples were open ground" % bare)
	return true


func _check_crossings(world: WorldGen, tops: Array[Dictionary]) -> bool:
	# The step must be load-bearing, so the lip is one a player CANNOT cross
	# without it: the thickest lips over open, gentle ground are walked with no
	# step first, and the first that stalls is the case. A candidate list with no
	# such lip means the step's need is unproven, which fails rather than passes.
	var lip := {}
	var tried := 0
	for candidate in _lip_candidates(world, tops):
		tried += 1
		var unaided := await _walk(world, candidate[&"outside"], candidate[&"inside"], 0.0)
		if not unaided[&"arrived"]:
			lip = candidate
			break
	if lip.is_empty():
		return _fail(("none of %d thick lips stops a player without a step — the step is not shown to "
			+ "be needed, so this test cannot prove it works") % tried)
	print("lip: a %.3f m lip stops a player with no step (candidate %d of the thickest)" %
		[lip[&"thickness"], tried])
	if not await _cross(world, "up a %.3f m lip" % lip[&"thickness"], lip[&"outside"], lip[&"inside"], false):
		return false
	if not await _cross(world, "down a %.3f m lip" % lip[&"thickness"], lip[&"inside"], lip[&"outside"], true):
		return false
	var seam := _find_seam(world, tops)
	if seam.is_empty():
		return _fail("no two neighbouring slabs of different thickness were found")
	if not await _cross(world, "from a %.3f m slab onto a %.3f m neighbour" % [seam[&"low"], seam[&"high"]],
			seam[&"from"], seam[&"to"], false):
		return false
	var junction := _find_junction(world, tops)
	if junction.is_empty():
		return _fail("no point where three slabs meet was found")
	return await _cross(world, "through a three-slab junction", junction[&"from"], junction[&"to"], false)


## Walk with the world's own step and judge the crossing.
func _cross(world: WorldGen, what: String, from: Vector2, to: Vector2, descending: bool) -> bool:
	var result := await _walk(world, from, to, world.ground_plates_step_height())
	var end: Vector3 = result[&"end"]
	var band := _footprint_band(world, Vector2(end.x, end.z))
	var settled := 0.0
	if end.y > band.y:
		settled = end.y - band.y
	elif end.y < band.x:
		settled = end.y - band.x
	var lowest: float = result[&"lowest"]
	var airborne: int = result[&"airborne"]
	if not result[&"arrived"]:
		return _fail("walking %s stalled %.2f m short within %d ticks — the player snags" %
			[what, Vector2(end.x, end.z).distance_to(to), result[&"budget"]])
	if lowest < -0.02:
		return _fail("walking %s the body sank %.3f m below the base ground — it tunnelled" % [what, -lowest])
	if absf(settled) > SETTLE_TOLERANCE:
		return _fail(("after walking %s the body rests %.3f m %s every surface under its footprint "
			+ "(%.3f to %.3f)") % [what, absf(settled), "above" if settled > 0.0 else "below",
			band.x, band.y])
	if descending and airborne > 2:
		return _fail("walking %s the body left the ground for %d ticks — it drops into the airborne pose" %
			[what, airborne])
	print(("crossing %s: arrived, rests %+.3f m outside its footprint's surfaces, lowest %+.3f m "
		+ "above base, %d airborne ticks") % [what, settled, lowest, airborne])
	return true


## Walk a real Player with real input from `from` toward `to`, with `step` as
## its step height, and report what happened.
func _walk(world: WorldGen, from: Vector2, to: Vector2, step: float) -> Dictionary:
	var player := Player.new()
	add_child(player)
	player.ground_height_provider = world.walkable_height_at
	player.enable_step(step)
	player.global_position = Vector3(from.x, world.walkable_height_at(from.x, from.y) + 0.02, from.y)
	player.face_toward(Vector3(to.x, player.global_position.y, to.y))
	player.velocity = Vector3.ZERO
	for _i in 10:
		await get_tree().physics_frame
	var distance := from.distance_to(to)
	var budget := int(ceil(distance / Player.WALK_SPEED * TIME_FACTOR * Engine.physics_ticks_per_second)) + 10
	var lowest := INF
	var airborne := 0
	var arrived := false
	Input.action_press("move_forward")
	for _tick in budget:
		await get_tree().physics_frame
		var p := player.global_position
		lowest = minf(lowest, p.y - world.surface_height_at(p.x, p.z))
		# What the gait sees: a body rolling off a lip edge is still standing.
		if not player.is_grounded():
			airborne += 1
		if Vector2(p.x, p.z).distance_to(to) < 0.25:
			arrived = true
			break
	Input.action_release("move_forward")
	for _i in 10:
		await get_tree().physics_frame
	var end := player.global_position
	player.queue_free()
	await get_tree().physics_frame
	return {&"arrived": arrived, &"end": end, &"lowest": lowest, &"airborne": airborne, &"budget": budget}


## Lowest and highest walkable surface under the capsule's footprint, as
## (min, max). A body resting across a lip or a seam is held up by the higher
## side, so its origin sits anywhere in this band; outside it is a real hover or
## a real sink.
func _footprint_band(world: WorldGen, at: Vector2) -> Vector2:
	var low := world.walkable_height_at(at.x, at.y)
	var high := low
	for k in 12:
		var p := at + Vector2.from_angle(TAU * float(k) / 12.0) * 0.38
		var h := world.walkable_height_at(p.x, p.y)
		low = minf(low, h)
		high = maxf(high, h)
	return Vector2(low, high)


## Lips a player walks at head-on: a top at least 12 cm thick with an edge whose
## outward approach is 2 m of open, gentle ground, thickest first — at most
## [constant LIP_CANDIDATES] of them, in a fixed order so the case is stable.
func _lip_candidates(world: WorldGen, tops: Array[Dictionary]) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	for top in tops:
		var thickness := float(top[&"thickness"])
		if thickness < 0.12:
			continue
		var polygon := top[&"polygon"] as PackedVector2Array
		var centre := ExposedSlabGeometry.centroid(polygon)
		for index in polygon.size():
			var a := polygon[index]
			var b := polygon[(index + 1) % polygon.size()]
			if a.distance_to(b) < 0.6:
				continue
			var mid := (a + b) * 0.5
			var outward := (mid - centre).normalized()
			var outside := mid + outward * 2.0
			if not _open_and_gentle(world, mid + outward * 0.1, outside):
				continue
			found.append({&"thickness": thickness, &"outside": outside, &"inside": centre})
			break
	found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a[&"thickness"]) > float(b[&"thickness"]))
	return found.slice(0, LIP_CANDIDATES)


## Two neighbouring tops that differ by at least 4 cm, crossed centre to centre.
func _find_seam(world: WorldGen, tops: Array[Dictionary]) -> Dictionary:
	for top in tops:
		var polygon := top[&"polygon"] as PackedVector2Array
		var centre := ExposedSlabGeometry.centroid(polygon)
		var own := float(top[&"thickness"])
		for index in polygon.size():
			var a := polygon[index]
			var b := polygon[(index + 1) % polygon.size()]
			if a.distance_to(b) < 0.5:
				continue
			var mid := (a + b) * 0.5
			var outward := (mid - centre).normalized()
			var probe := mid + outward * 0.05
			var other := world.ground_plate_thickness_at(probe.x, probe.y)
			if other - own < 0.04:
				continue
			var far := mid + outward * 0.6
			if world.ground_plate_thickness_at(far.x, far.y) != other:
				continue
			return {&"low": own, &"high": other, &"from": centre, &"to": far}
	return {}


## A top corner that three raised tops meet at, crossed along a line through it.
func _find_junction(world: WorldGen, tops: Array[Dictionary]) -> Dictionary:
	for top in tops:
		var polygon := top[&"polygon"] as PackedVector2Array
		for corner in polygon:
			var owners := {}
			for k in 6:
				var probe := corner + Vector2.from_angle(TAU * float(k) / 6.0) * 0.08
				var thickness := world.ground_plate_thickness_at(probe.x, probe.y)
				if thickness == 0.0:
					owners.clear()
					break
				owners[world.ground_plate_at(probe.x, probe.y)] = true
			if owners.size() < 3:
				continue
			# From this slab's centre, straight through the corner, to the centre
			# of whichever slab lies beyond it.
			var centre := ExposedSlabGeometry.centroid(polygon)
			var through := (corner - centre).normalized()
			var beyond := corner + through * 0.1
			var far := world.ground_plate_at(beyond.x, beyond.y)
			if far < 0:
				continue
			var far_centre := ExposedSlabGeometry.centroid(tops[far][&"polygon"] as PackedVector2Array)
			return {&"from": centre, &"to": far_centre}
	return {}


func _open_and_gentle(world: WorldGen, from: Vector2, to: Vector2) -> bool:
	var steps := 20
	var previous := world.surface_height_at(from.x, from.y)
	for k in range(1, steps + 1):
		var p := from.lerp(to, float(k) / float(steps))
		if absf(p.x) > HALF_WORLD or absf(p.y) > HALF_WORLD or world.cave_protects(p.x, p.y):
			return false
		if world.ground_plate_thickness_at(p.x, p.y) != 0.0:
			return false
		var h := world.surface_height_at(p.x, p.y)
		if absf(h - previous) / (from.distance_to(to) / float(steps)) > tan(deg_to_rad(12.0)):
			return false
		previous = h
	return true


func _check_same_seed(world: WorldGen) -> bool:
	var first := _fingerprints(world)
	OS.set_environment("WAR_GROUND_PLATES", "1")
	var again := WorldGen.new()
	again.name = "Again"
	add_child(again)
	OS.unset_environment("WAR_GROUND_PLATES")
	await get_tree().physics_frame
	var second := _fingerprints(again)
	again.queue_free()
	await get_tree().physics_frame
	for key: String in first:
		if first[key] != second[key]:
			return _fail("two fresh builds of one seed disagree on the %s" % key)
	print("same seed: render %s…, collision %s…, query %s… on both builds" %
		[String(first["render mesh"]).left(12), String(first["collision faces"]).left(12),
			String(first["surface query"]).left(12)])
	return true


func _fingerprints(world: WorldGen) -> Dictionary:
	var overlay := world.get_node(WorldGen.GROUND_PLATES_NODE) as MeshInstance3D
	var arrays := overlay.mesh.surface_get_arrays(0)
	var render := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).to_byte_array()
	render.append_array((arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).to_byte_array())
	var body := world.get_node(WorldGen.GROUND_PLATES_BODY)
	var shape := (body.get_child(0) as CollisionShape3D).shape as ConcavePolygonShape3D
	var query := PackedFloat64Array()
	for x in range(-100, 101, 2):
		for z in range(-100, 101, 2):
			query.append(world.walkable_height_at(x + 0.37, z + 0.61))
	return {
		"render mesh": _sha(render),
		"collision faces": _sha(shape.get_faces().to_byte_array()),
		"surface query": _sha(query.to_byte_array()),
	}


func _check_off_is_off(world: WorldGen, tops: Array[Dictionary]) -> bool:
	var player := Player.new()
	add_child(player)
	var engine_snap := player.floor_snap_length
	player.enable_step(0.0)
	var unchanged := player.step_height == 0.0 and player.floor_snap_length == engine_snap
	player.queue_free()
	if not unchanged:
		return _fail("a player given no step does not move with the engine's own floor snap")

	world.set_ground_plates_enabled(false)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := get_viewport().world_3d.direct_space_state
	for top in tops.slice(0, 50):
		var centre := ExposedSlabGeometry.centroid(top[&"polygon"] as PackedVector2Array)
		if world.walkable_height_at(centre.x, centre.y) != world.surface_height_at(centre.x, centre.y):
			return _fail("with the overlay hidden the query still reads the raised top at %s" % centre)
		var hit := _ray_down(space, world, centre)
		if hit.is_empty() or String((hit[&"collider"] as Node).name) != "TerrainBody":
			return _fail("with the overlay hidden a ray at %s still meets the raised stone" % centre)
	if world.ground_plates_step_height() != 0.0:
		return _fail("with the overlay hidden the world still asks walkers to step")
	world.set_ground_plates_enabled(true)
	return true


func _ray_down(space: PhysicsDirectSpaceState3D, world: WorldGen, at: Vector2) -> Dictionary:
	if _not_ground.is_empty():
		for body in world.find_children("*", "CollisionObject3D", true, false):
			if String(body.name) not in ["TerrainBody", WorldGen.GROUND_PLATES_BODY]:
				_not_ground.append((body as CollisionObject3D).get_rid())
	var ground := world.surface_height_at(at.x, at.y)
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(at.x, ground + 2.0, at.y), Vector3(at.x, ground - 2.0, at.y))
	query.exclude = _not_ground
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return {}
	return {&"y": (hit["position"] as Vector3).y, &"collider": hit["collider"]}


func _sha(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


func _fail(message: String) -> bool:
	if _failed:
		return false
	_failed = true
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
	return false
