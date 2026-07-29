extends Node
## Drives a real capsule UP the real terrain collision, on the steepest ground
## each region owns.
##
## Every other walkability guard we have measures GEOMETRY.
## `region_landform_test` arm 5 takes each collision face's true normal and
## ratchets it per region, which proves Godot will *classify* those faces as
## floor. Classification is not traversal: a 44 degree face can be classified as
## floor and still be impossible to walk up — the capsule can stall against a
## face sequence, snap between triangles, or slide back while `is_on_floor()`
## stays true the whole time. Nothing in the suite drove a body over the terrain
## before this, so that whole failure mode was invisible (#541).
##
## It matters here because near-limit ground is not exotic in the Reach. The
## world's steepest collision face is 44.18 degrees against a 45 degree floor
## limit — 0.82 degrees of margin — and `cinderreach` sits at 43.38,
## `ashflats` at 41.55.
##
## Run: godot --headless --path client res://tests/terrain_traversal_test.tscn

## The wanderer itself does the walking. Nothing here re-implements movement:
## the capsule, `floor_max_angle`, `WALK_SPEED`, the acceleration curve, the
## slide response and the anti-embed net all come from the shipped [Player],
## driven through its own public `face_toward` plus the real `move_forward`
## action. A bespoke capsule would answer a question about a capsule this game
## does not ship.

## How many separate slopes to climb in each region.
const CLIMBS_PER_REGION := 3

## Minimum distance between two chosen slopes inside one region, in metres.
## Without it the top three faces are three triangles of the same hillside, and
## "the steepest ground in each region" collapses to one sample taken thrice.
const CANDIDATE_SEPARATION := 18.0

## How far downhill of a summit face to look for the foot of its slope, and at
## what spacing, in metres. The foot is the LOWEST point found along the fall
## line, so the climb spans the whole slope rather than one triangle.
const RUN_UP_MAX := 10.0
const RUN_UP_STEP := 0.5

## A candidate whose fall line drops less than this is not a climb worth
## measuring, in metres.
const MIN_AVAILABLE_GAIN := 2.0

## The massif's buried skirt is deliberately a cliff and is not walkable ground
## (see `region_landform_test.CAVE_KEEPOUT`, which excludes it for the same
## reason and by the same radius from the same site).
const CAVE_KEEPOUT := 40.0

## How far above the surface each climber is placed before the settle phase, in
## metres. Small enough that the drop costs no real time, large enough that a
## climber never starts inside the trimesh.
const SPAWN_CLEARANCE := 0.5

## Physics ticks spent letting the climbers land before any input is applied.
const SETTLE_TICKS := 30

## Physics ticks each climb gets, and therefore the ratchet on how long a climb
## may take: arriving at tick 151 fails exactly as not arriving does.
##
## Measured worst arrival across the twelve climbs is tick 125, so this carries
## 25 ticks of margin. A separate, looser "arrived but slowly" ratchet was tried
## and removed: exaggerating the terrain never produced a slow arrival, only a
## failed one. Swept from 1.1x to 2.0x against a 200-tick budget, the worst
## arrival among the climbs that still made it never passed tick 113 — so a
## second bar sitting between 125 and 200 was one no ablation could reach, and
## folding it into the budget itself leaves one law where there were two.
const CLIMB_TICKS := 150

## What counts as arrived: within this far of the summit horizontally, and this
## far below its height, in metres. The terrain grid is 1.72 m, so the radius is
## "reached that face" rather than a sub-triangle precision claim.
##
## The height half is load-bearing and is NOT a second way of saying the same
## thing. With a radius alone the climber is stopped the moment it enters the
## circle, which on 41 degree ground is still 1.8 m below the summit — so every
## climb reads as ~70% complete and the shortfall measures this constant instead
## of the terrain. Requiring the height too makes arrival mean "got up there".
## The tolerance absorbs capsule resting geometry: a 0.4 m capsule on a steep
## face sits a little under the vertical surface height at its own (x, z).
const ARRIVAL_RADIUS := 2.0
const ARRIVAL_HEIGHT_TOLERANCE := 0.5

## Physics layer the terrain is moved to for the duration of this test, so the
## climbers collide with the GROUND and nothing else. Ruins and the shrine carry
## their own collision; a climb blocked by a ruin would be a real problem but a
## different one, and it must not decide this guard's verdict.
const TERRAIN_LAYER := 2

## Vertical exaggeration applied to the terrain collision for the ablation arm.
## At this factor a 44 degree face becomes atan(2*tan(44)) = 62.7 degrees, well
## past the 45 degree floor limit.
##
## Measured across the sweep that chose it: at 1.1x one climb already fails, at
## 1.3x eight do, and at 2.0x all twelve do — and only at 1.5x and beyond does
## any climber slide or leave the floor far enough to trip the other two laws.
## 2.0x is the first factor that exercises ALL THREE, which is what the ablation
## arm is for.
const ABLATION_SCALE := 2.0

## Ratchets, measured on the shipped seed by the run this test prints. Set just
## outside this world's behaviour rather than at a comfortable round number, for
## the same reason `region_landform_test.MAX_GRADE_DEG` is: a loose bar licences
## the ground getting harder to walk without anything noticing. Ratchet them
## down as traversal improves; never up to accommodate a re-tune.
##
## Measured on the real terrain: backslide 0.00-0.02 m, grounded 100% on every
## climb. Measured under the ablation, which is what proves these can fail at
## all: backslide 10.45 m and grounded 0%, on two climbs each.
##
## There is deliberately NO "fraction of the available height climbed" ratchet.
## It reads like a fourth law and is in fact a tautology: arrival already
## requires the climber to be within `ARRIVAL_HEIGHT_TOLERANCE` of the summit, so
## an arrived climb's height deficit can never exceed that constant — measured,
## it was 0.47 m on every one of the twelve. Normalising that fixed deficit by
## each slope's own height then produced 77%-91% purely because the slopes differ
## in size, which says nothing whatever about whether they were walkable.
const MAX_BACKSLIDE := 0.25
const MIN_GROUNDED_FRACTION := 0.95

## The three laws, named so the ablation arm can assert that each one actually
## fired. A law no ablation can trip is decoration, and this is where that gets
## caught rather than assumed.
const LAW_ARRIVED := "reached the summit"
const LAW_BACKSLIDE := "held its ground"
const LAW_GROUNDED := "stayed on the floor"

var _failures: Array[String] = []
var _world: WorldGen
var _climbs: Array[Climb] = []
var _phase := 0
var _phase_tick := 0
var _height_scale := 1.0
var _terrain_shape: ConcavePolygonShape3D
var _report: Array[String] = []


## One slope under test: where it is, how steep, and what the climber did on it.
class Climb:
	var region: StringName
	var grade := 0.0
	var foot := Vector2.ZERO
	var summit := Vector2.ZERO
	var available := 0.0
	var body: Player
	var start_y := 0.0
	var peak_y := 0.0
	var backslide := 0.0
	var grounded_ticks := 0
	var driven_ticks := 0
	var arrived_tick := -1

	func label() -> String:
		return "%s %.2f deg at (%.1f, %.1f)" % [region, grade, summit.x, summit.y]


func _ready() -> void:
	_world = WorldGen.new()
	_world.name = "World"
	add_child(_world)
	_isolate_terrain_collision()
	_select_climbs()
	if _climbs.is_empty():
		_fail("no climbable slope was found in any region — the selection is broken")
		_finish()
		return
	Player.ensure_input_actions()
	_spawn_climbers()


func _physics_process(_delta: float) -> void:
	if _world == null:
		return
	_phase_tick += 1
	match _phase:
		0:
			if _phase_tick > SETTLE_TICKS:
				_begin_climb()
		1:
			_drive()
			if _phase_tick > CLIMB_TICKS:
				_end_real_arm()
		2:
			if _phase_tick > SETTLE_TICKS:
				_begin_climb()
		3:
			_drive()
			if _phase_tick > CLIMB_TICKS:
				_end_ablated_arm()


## The terrain collision moves to its own physics layer and the climbers mask
## only that layer, so this arm measures the GROUND. Ruins, the shrine and the
## other climbers stay on their own layer and are simply not there.
func _isolate_terrain_collision() -> void:
	var body := _world.get_node_or_null("TerrainBody") as StaticBody3D
	if body == null:
		_fail("WorldGen built no TerrainBody — nothing to walk on")
		return
	body.collision_layer = TERRAIN_LAYER
	for child in body.get_children():
		var shape := child as CollisionShape3D
		if shape != null:
			_terrain_shape = shape.shape as ConcavePolygonShape3D
	if _terrain_shape == null:
		_fail("TerrainBody carries no ConcavePolygonShape3D")


## The steepest slopes each region owns, spread apart so they are separate
## landforms rather than neighbouring triangles of one hillside.
##
## Face ownership follows `region_landform_test`: all three vertices must be
## fully decided and agree. A face straddling a blend band belongs to no region,
## which is right here too — this arm is asking what each region's own ground is
## like to walk on.
func _select_climbs() -> void:
	var sites := GroundRegions.sites(WorldGen.WORLD_SEED, WorldGen.SIZE)
	var step := WorldGen.SIZE / WorldGen.QUADS
	var half := WorldGen.SIZE / 2.0
	var by_region := {}
	for reg: Dictionary in GroundRegions.REGIONS:
		by_region[reg[&"name"]] = []
	for iz in WorldGen.QUADS:
		for ix in WorldGen.QUADS:
			var x0 := ix * step - half
			var z0 := iz * step - half
			for tri: Array in [
				[Vector2(x0, z0), Vector2(x0 + step, z0 + step), Vector2(x0 + step, z0)],
				[Vector2(x0, z0), Vector2(x0, z0 + step), Vector2(x0 + step, z0 + step)],
			]:
				var centre: Vector2 = (tri[0] + tri[1] + tri[2]) / 3.0
				if (centre - WorldGen.CAVE_SITE).length() <= CAVE_KEEPOUT:
					continue
				var owner := _face_region(sites, tri[0], tri[1], tri[2])
				if owner == &"":
					continue
				var n := _world.surface_normal_at(centre.x, centre.y)
				var deg := rad_to_deg(acos(clampf(absf(n.y), -1.0, 1.0)))
				by_region[owner].append([deg, centre])
	for region: StringName in by_region:
		_take_steepest(region, by_region[region])


## Greedily take the steepest faces in one region, skipping any that sits within
## `CANDIDATE_SEPARATION` of one already taken or whose fall line does not drop
## far enough to be a climb.
func _take_steepest(region: StringName, faces: Array) -> void:
	faces.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var taken: Array[Vector2] = []
	for face: Array in faces:
		if taken.size() >= CLIMBS_PER_REGION:
			return
		var summit: Vector2 = face[1]
		var clear := true
		for other in taken:
			if (summit - other).length() < CANDIDATE_SEPARATION:
				clear = false
				break
		if not clear:
			continue
		var foot := _foot_of(summit)
		var gain := _world.surface_height_at(summit.x, summit.y) - \
			_world.surface_height_at(foot.x, foot.y)
		if gain < MIN_AVAILABLE_GAIN:
			continue
		taken.append(summit)
		var climb := Climb.new()
		climb.region = region
		climb.grade = face[0]
		climb.summit = summit
		climb.foot = foot
		climb.available = gain
		_climbs.append(climb)


## The lowest point on the fall line below a summit face, within `RUN_UP_MAX`.
## The fall line is the horizontal part of the surface normal: for a plane with
## upward normal n the steepest descent runs along (n.x, n.z).
func _foot_of(summit: Vector2) -> Vector2:
	var n := _world.surface_normal_at(summit.x, summit.y)
	var down := Vector2(n.x, n.z)
	if down.length() < 0.001:
		return summit
	down = down.normalized()
	var best := summit
	var best_h := _world.surface_height_at(summit.x, summit.y)
	var t := RUN_UP_STEP
	while t <= RUN_UP_MAX:
		var at := summit + down * t
		var h := _world.surface_height_at(at.x, at.y)
		if h > WorldGen.NO_GROUND and h < best_h:
			best_h = h
			best = at
		t += RUN_UP_STEP
	return best


func _spawn_climbers() -> void:
	for i in _climbs.size():
		var climb := _climbs[i]
		var body := Player.new()
		body.name = "Climber_%s_%d" % [climb.region, i]
		# Mask the terrain layer only, and sit on no layer at all: climbers are
		# measured against the ground, never against each other.
		body.collision_layer = 0
		body.collision_mask = TERRAIN_LAYER
		add_child(body)
		body.ground_height_provider = _scaled_height
		body.underground_provider = _world.cave_protects
		climb.body = body
		_place_at_foot(climb)


func _place_at_foot(climb: Climb) -> void:
	var y := _scaled_height(climb.foot.x, climb.foot.y) + SPAWN_CLEARANCE
	climb.body.global_position = Vector3(climb.foot.x, y, climb.foot.y)
	climb.body.velocity = Vector3.ZERO
	climb.body.control_enabled = false
	climb.start_y = y
	climb.peak_y = y
	climb.backslide = 0.0
	climb.grounded_ticks = 0
	climb.driven_ticks = 0
	climb.arrived_tick = -1


## The terrain height the climbers actually stand on. In the ablation arm the
## collision is exaggerated, so the anti-embed net must be told the same story —
## left unscaled it would read every climber as buried and teleport them.
func _scaled_height(x: float, z: float) -> float:
	return _world.surface_height_at(x, z) * _height_scale


func _begin_climb() -> void:
	_phase += 1
	_phase_tick = 0
	for climb in _climbs:
		# The settle phase is where the true foot height is established: the
		# climber was dropped from SPAWN_CLEARANCE above it and has since landed.
		climb.start_y = climb.body.global_position.y
		climb.peak_y = climb.start_y
		# Height available to climb, measured in the CLIMBER's own coordinate
		# rather than between two surface samples. A capsule at rest on a steep
		# face does not sit exactly at the vertical surface height under it, so
		# a surface-to-surface figure and an origin-to-origin one differ by a
		# resting offset that has nothing to do with whether the slope was
		# climbed. Both ends of this one are read the same way.
		climb.available = _scaled_height(climb.summit.x, climb.summit.y) - climb.start_y
		climb.body.control_enabled = true
	Input.action_press("move_forward")


func _drive() -> void:
	for climb in _climbs:
		if climb.arrived_tick >= 0:
			continue
		var body := climb.body
		var here := body.global_position
		var summit_y := _scaled_height(climb.summit.x, climb.summit.y)
		body.face_toward(Vector3(climb.summit.x, here.y, climb.summit.y))
		climb.driven_ticks += 1
		if body.is_on_floor():
			climb.grounded_ticks += 1
		climb.peak_y = maxf(climb.peak_y, here.y)
		climb.backslide = maxf(climb.backslide, climb.peak_y - here.y)
		var flat := Vector2(here.x, here.z) - climb.summit
		if flat.length() <= ARRIVAL_RADIUS and here.y >= summit_y - ARRIVAL_HEIGHT_TOLERANCE:
			climb.arrived_tick = _phase_tick
			# Stop this one where it stands: with the action held globally it
			# would otherwise walk on over the summit and down the far side,
			# and its backslide reading would describe the descent.
			body.control_enabled = false
			body.velocity = Vector3.ZERO


## Judge every climb against the three laws and return, per law, the climbs that
## broke it. BOTH arms go through this same function: the real arm requires it to
## come back empty, the ablation requires every law to appear. A separate pair of
## checks would let the two drift, and then the ablation would be proving
## something about code the real arm does not run.
func _evaluate() -> Dictionary:
	var broken := {LAW_ARRIVED: [], LAW_BACKSLIDE: [], LAW_GROUNDED: []}
	for climb in _climbs:
		var gained := climb.peak_y - climb.start_y
		var grounded := float(climb.grounded_ticks) / maxf(float(climb.driven_ticks), 1.0)
		_report.append(
			"  %s: available %.2f m, gained %.2f m, backslide %.2f m, grounded %.0f%%, %s" %
			[
				climb.label(),
				climb.available,
				gained,
				climb.backslide,
				grounded * 100.0,
				("arrived at tick %d" % climb.arrived_tick) if climb.arrived_tick >= 0 else "NEVER ARRIVED",
			])
		# Every law is judged on every climb, including one that never arrived.
		# Skipping the other two there would make them unreachable in exactly the
		# runs that break them, which is where they are worth having.
		if climb.arrived_tick < 0:
			broken[LAW_ARRIVED].append(
				"%s: never reached the summit in %d ticks — %.2f m of the %.2f m available, so this ground classifies as floor without being climbable" %
				[climb.label(), CLIMB_TICKS, gained, climb.available])
		if climb.backslide > MAX_BACKSLIDE:
			broken[LAW_BACKSLIDE].append("%s: slid back %.2f m, over the %.2f m limit" %
				[climb.label(), climb.backslide, MAX_BACKSLIDE])
		if grounded < MIN_GROUNDED_FRACTION:
			broken[LAW_GROUNDED].append(
				"%s: on the floor for only %.0f%% of the climb, under the %.0f%% floor" %
				[climb.label(), grounded * 100.0, MIN_GROUNDED_FRACTION * 100.0])
	return broken


func _end_real_arm() -> void:
	Input.action_release("move_forward")
	_report.append("terrain traversal — %d climbs over the real collision:" % _climbs.size())
	var broken := _evaluate()
	for law: String in broken:
		for message: String in broken[law]:
			_fail(message)
	_ablate()


## Exaggerate the real terrain collision vertically and run the same climbs
## again. They must all fail: a guard that stays green when the ground becomes
## unclimbable is measuring nothing, and this arm is what rules that out.
func _ablate() -> void:
	_height_scale = ABLATION_SCALE
	var faces := _terrain_shape.get_faces()
	for i in faces.size():
		var v := faces[i]
		v.y *= ABLATION_SCALE
		faces[i] = v
	_terrain_shape.set_faces(faces)
	for climb in _climbs:
		_place_at_foot(climb)
	# Phase 2 is the ablated settle; _begin_climb steps it on to 3, the climb.
	_phase = 2
	_phase_tick = 0


## The ablation's verdict is not "did something fail" but "did EACH law fail".
## A law that stays silent here is one no amount of unwalkable ground can trip,
## which means the real arm's green tells you nothing about it.
func _end_ablated_arm() -> void:
	Input.action_release("move_forward")
	_report.append("ablation — the same climbs with the ground at %.1fx vertical:" % ABLATION_SCALE)
	var broken := _evaluate()
	for law: String in broken:
		var count: int = broken[law].size()
		_report.append("  law '%s': broken by %d of %d climbs" % [law, count, _climbs.size()])
		if count == 0:
			_fail(
				"ablation at %.1fx never broke the law '%s' — that law cannot fail, so the real arm passing it proves nothing" %
				[ABLATION_SCALE, law])
	_finish()


func _finish() -> void:
	for line in _report:
		print(line)
	if _failures.is_empty():
		print("TEST PASS: terrain_traversal")
		get_tree().quit(0)
		return
	for f in _failures:
		printerr("FAIL: %s" % f)
	printerr("TEST FAIL: terrain_traversal (%d)" % _failures.size())
	get_tree().quit(1)


func _fail(msg: String) -> void:
	_failures.append(msg)


func _face_region(sites: Array, a: Vector2, b: Vector2, c: Vector2) -> StringName:
	var owner := -1
	for v: Vector2 in [a, b, c]:
		var at := GroundRegions.region_for(sites, v.x, v.y)
		if float(at[&"blend"]) < 1.0:
			return &""
		var region: int = at[&"region"]
		if owner == -1:
			owner = region
		elif owner != region:
			return &""
	return GroundRegions.REGIONS[owner][&"name"]
