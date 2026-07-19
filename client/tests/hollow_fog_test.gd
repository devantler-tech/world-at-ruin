extends Node
## Regression test for the ash pools placed in the terrain's hollows (#211).
##
## The thing #211 promises is not "some FogVolumes exist" — it is that the air
## is THICKER WHERE THE GROUND IS LOWER. A FogVolume renders nothing under
## `--headless` (volumetrics need a GPU capability the runner lacks, #158), so
## no pixel check can hold that here. This test holds the property directly
## instead, by re-measuring the real terrain underneath every pool.
##
## What it holds:
##  1. PRESENT — the shipped world really does get pools, in quantity. Without
##     this floor every law below passes vacuously on an empty list, which is
##     precisely how a placement bug would hide.
##  2. GENUINELY LOW — every pool sits below its own surroundings, verified by
##     an INDEPENDENT re-measurement of the terrain at a different radius and a
##     different sample count than the placer used. Re-running the placer's own
##     arithmetic would only prove it is self-consistent.
##  3. LOWER THAN THE WORLD — the ground under the pools is well below the
##     terrain's median height. This is the #211 success signal itself: ash
##     gathers in the hollows rather than being sprinkled at random elevations.
##  4. NEVER ON A HIGH POINT — no pool sits on ground above its ring mean. The
##     one thing that would read as an outright bug to a player standing on a
##     ridge in thick fog.
##  5. SPREAD — min separation honoured, so pooling reads as several basins
##     rather than one blob, and the count stays inside its cap.
##  6. IN BOUNDS — every pool is over real terrain, never over the void past
##     the world edge.
##  7. DETERMINISTIC and RNG-FREE — two placements over the real terrain whose
##     process-global RNG was seeded differently are identical, so the pools are
##     the same every boot (the #58 law) and the placer cannot have perturbed a
##     shared draw order (the #109 lesson).
##  8. THE RELIEF TEST IS LOAD-BEARING — synthetic controls prove the placer
##     discriminates: flat ground and a dome yield NOTHING, a single bowl yields
##     exactly one pool AT the bowl, and a terrain whose ring leaves the world
##     is refused rather than half-sampled.
##
## Control 8 is the one that matters most. Laws 1–7 are all satisfied by a
## placer that simply drops pools on the lowest lattice points it can find;
## only the synthetic ablations prove it is measuring RELIEF — ground low
## RELATIVE TO ITS SURROUNDINGS — which is what makes a hollow a hollow.
##
## Pure and headless: builds WorldGen directly (never main.tscn), so it never
## touches the player's save.
##
## Run: godot --headless --path client res://tests/hollow_fog_test.tscn

const HALF := WorldGen.SIZE / 2.0
## Minimum pools the shipped terrain must produce. The non-vacuity floor for
## every law below.
const MIN_POOLS := 2
## Independent verification ring — deliberately NOT HollowFog.RING_RADIUS /
## RING_SAMPLES, so law 2 is a second opinion on the terrain rather than a
## replay of the placer's own sum.
const VERIFY_RADIUS := 18.0
const VERIFY_SAMPLES := 16
## How far below the world median the pools' mean ground must sit, in metres.
## A placer scattering pools at random elevations lands near 0.0.
const MIN_MEDIAN_DROP := 1.0
## The synthetic depression used by the BASIN and ISLAND controls. Off-origin
## so "found the hollow" cannot pass by defaulting to the world centre; deep
## and tight enough that its relief clears HollowFog.MIN_RELIEF with margin,
## so a control failure means the placer missed the hollow rather than the
## hollow being too shallow to qualify.
const BASIN_AT := Vector2(40.0, -25.0)
const BASIN_DEPTH := 10.0
const BASIN_SIGMA := 20.0
## Half-extent of the ISLAND control's terrain, sized so a candidate at the
## depression's centre has its ring cross the edge.
const ISLAND_HALF := HollowFog.RING_RADIUS * 0.5

var _world: WorldGen


func _ready() -> void:
	_world = _build_world(11)
	var pools := HollowFog.place(_world.surface_height_at, WorldGen.SIZE, WorldGen.NO_GROUND)

	# 1. PRESENT
	if pools.size() < MIN_POOLS:
		_fail("shipped terrain produced %d ash pools, need at least %d — every law below would pass vacuously" % [pools.size(), MIN_POOLS])
		return
	if pools.size() > HollowFog.MAX_VOLUMES:
		_fail("placed %d pools, cap is %d" % [pools.size(), HollowFog.MAX_VOLUMES])
		return

	# 6. IN BOUNDS (checked first — the later laws sample the ground here)
	for p: Dictionary in pools:
		var pos: Vector3 = p["pos"]
		var ground: float = _world.surface_height_at(pos.x, pos.z)
		if ground <= WorldGen.NO_GROUND:
			_fail("pool at (%.1f, %.1f) sits over the void, outside the terrain" % [pos.x, pos.z])
			return

	# 2 + 4. GENUINELY LOW, by independent re-measurement
	var worst_relief := INF
	for p: Dictionary in pools:
		var pos: Vector3 = p["pos"]
		var ground: float = _world.surface_height_at(pos.x, pos.z)
		var ring := _verify_ring_mean(pos.x, pos.z)
		if is_nan(ring):
			_fail("pool at (%.1f, %.1f) could not be independently verified — its ring leaves the terrain" % [pos.x, pos.z])
			return
		var relief := ring - ground
		worst_relief = minf(worst_relief, relief)
		if relief <= 0.0:
			_fail("pool at (%.1f, %.1f) sits %.2f m ABOVE its surroundings — that is a ridge, not a hollow" % [pos.x, pos.z, -relief])
			return
	if worst_relief < HollowFog.MIN_RELIEF * 0.5:
		_fail("shallowest pool clears its surroundings by only %.2f m; the placer claims a %.2f m floor, so the two measures disagree" % [worst_relief, HollowFog.MIN_RELIEF])
		return

	# 3. LOWER THAN THE WORLD
	var median := _terrain_median()
	var pool_mean := 0.0
	for p: Dictionary in pools:
		var pos: Vector3 = p["pos"]
		pool_mean += _world.surface_height_at(pos.x, pos.z)
	pool_mean /= float(pools.size())
	var drop := median - pool_mean
	if drop < MIN_MEDIAN_DROP:
		_fail("pools average %.2f m against a world median of %.2f m (drop %.2f m, need %.2f m) — ash is not gathering low" % [pool_mean, median, drop, MIN_MEDIAN_DROP])
		return

	# 5. SPREAD — and DISJOINT, which is the load-bearing half.
	#
	# Fog volumes composite by ADDING optical depth, so two overlapping pools
	# do not read as two pools: they read as one sheet at double density. The
	# first tuning of this change placed 44 m-wide pools 30 m apart, and the
	# rendered frame lost the near-field ruin pillars and ground debris to a
	# flat haze — while every other law here still passed. Separation alone is
	# not the property; separation EXCEEDING the pools' own width is.
	if HollowFog.MIN_SEPARATION <= HollowFog.POOL_RADIUS * 2.0:
		_fail("MIN_SEPARATION %.1f m does not exceed a pool's own width %.1f m — pools may overlap and merge into one sheet" % [HollowFog.MIN_SEPARATION, HollowFog.POOL_RADIUS * 2.0])
		return
	for i in pools.size():
		for j in range(i + 1, pools.size()):
			var a: Vector3 = pools[i]["pos"]
			var b: Vector3 = pools[j]["pos"]
			var d := Vector2(a.x - b.x, a.z - b.z).length()
			if d < HollowFog.MIN_SEPARATION:
				_fail("pools %d and %d are %.1f m apart, min separation is %.1f m" % [i, j, d, HollowFog.MIN_SEPARATION])
				return
			if d <= HollowFog.POOL_RADIUS * 2.0:
				_fail("pools %d and %d overlap (%.1f m apart, each %.1f m across) — they will render as one sheet, not two pools" % [i, j, d, HollowFog.POOL_RADIUS * 2.0])
				return

	# 7. DETERMINISTIC and RNG-FREE
	var again := HollowFog.place(_world.surface_height_at, WorldGen.SIZE, WorldGen.NO_GROUND)
	if not _same(pools, again):
		_fail("two placements over the same terrain differ — placement is not deterministic")
		return
	var other_world := _build_world(9173)
	var other := HollowFog.place(other_world.surface_height_at, WorldGen.SIZE, WorldGen.NO_GROUND)
	if not _same(pools, other):
		_fail("placement changed when the process-global RNG was seeded differently — the placer is drawing from a shared stream")
		return

	# 8. THE RELIEF TEST IS LOAD-BEARING
	var control := _run_controls()
	if control != "":
		_fail(control)
		return

	print("TEST PASS — %d ash pools, shallowest clears its surroundings by %.2f m, %.2f m below world median, %s" % [
		pools.size(), worst_relief, drop, "4 controls held"
	])
	get_tree().quit(0)


## Synthetic terrains with a known right answer. Each isolates ONE claim, so a
## failure names which discrimination the placer lost.
func _run_controls() -> String:
	# FLAT — nothing is below its surroundings anywhere, so nothing is a
	# hollow. A placer that simply seeds pools on a lattice fails here.
	var flat := HollowFog.place(
		func(x: float, z: float) -> float:
			return 0.0 if absf(x) <= HALF and absf(z) <= HALF else WorldGen.NO_GROUND,
		WorldGen.SIZE, WorldGen.NO_GROUND
	)
	if not flat.is_empty():
		return "control FLAT: placed %d pools on perfectly flat ground, where no hollow exists" % flat.size()

	# DOME — curvature everywhere, but every point sits ABOVE its ring mean.
	# A placer keying on "is curved" rather than "is low" fails here.
	var dome := HollowFog.place(
		func(x: float, z: float) -> float:
			if absf(x) > HALF or absf(z) > HALF:
				return WorldGen.NO_GROUND
			return 20.0 - 0.004 * (x * x + z * z),
		WorldGen.SIZE, WorldGen.NO_GROUND
	)
	if not dome.is_empty():
		return "control DOME: placed %d pools on a hill, where every point stands above its surroundings" % dome.size()

	# BASIN — one localised depression, deliberately OFF the origin. Proves the
	# placer finds the RIGHT low ground rather than merely some low ground, and
	# that "found it" cannot pass by defaulting to the world centre.
	#
	# A paraboloid is the wrong shape for this control and was the first
	# version's bug: over k(x²+z²) the ring mean sits k·R² above the centre at
	# EVERY point, so relief is uniform, nothing distinguishes the basin, and
	# the control fails for a reason unrelated to its law. A Gaussian
	# depression on flat ground has relief that genuinely peaks at its centre.
	var basin := HollowFog.place(
		_depression(BASIN_AT, HALF), WorldGen.SIZE, WorldGen.NO_GROUND
	)
	if basin.size() != 1:
		return "control BASIN: a terrain with exactly one depression produced %d pools, expected 1" % basin.size()
	var at: Vector3 = basin[0]["pos"]
	var miss := Vector2(at.x - BASIN_AT.x, at.z - BASIN_AT.y).length()
	if miss > HollowFog.CANDIDATE_STEP:
		return "control BASIN: the one pool landed %.1f m from the depression's centre" % miss

	# ISLAND — the SAME depression, on terrain that stops inside the ring
	# radius, so every candidate's ring leaves the world. The shape is proven
	# placeable by the BASIN control immediately above, so a refusal here can
	# only be the ring-clipping rule: a placer that skipped or clamped missing
	# samples would measure the void as ground and place anyway.
	var island := HollowFog.place(
		_depression(BASIN_AT, ISLAND_HALF), WorldGen.SIZE, WorldGen.NO_GROUND
	)
	if not island.is_empty():
		return "control ISLAND: placed %d pools where every candidate's ring leaves the terrain — the void was measured as ground" % island.size()

	return ""


## A single Gaussian depression of BASIN_DEPTH metres centred at `at`, on
## otherwise flat ground, clipped to a square of half-extent `bound`.
func _depression(at: Vector2, bound: float) -> Callable:
	return func(x: float, z: float) -> float:
		if absf(x - at.x) > bound or absf(z - at.y) > bound:
			return WorldGen.NO_GROUND
		var d2 := (x - at.x) * (x - at.x) + (z - at.y) * (z - at.y)
		return -BASIN_DEPTH * exp(-d2 / (2.0 * BASIN_SIGMA * BASIN_SIGMA))


## Mean surface height on a ring around (x, z) at the VERIFY radius/sample
## count, or NAN if any sample leaves the terrain.
func _verify_ring_mean(x: float, z: float) -> float:
	var total := 0.0
	for i in VERIFY_SAMPLES:
		var angle := TAU * float(i) / float(VERIFY_SAMPLES)
		var h: float = _world.surface_height_at(x + cos(angle) * VERIFY_RADIUS, z + sin(angle) * VERIFY_RADIUS)
		if h <= WorldGen.NO_GROUND:
			return NAN
		total += h
	return total / float(VERIFY_SAMPLES)


## Median height of the whole baked terrain grid — the reference elevation the
## pools must sit below. Median rather than mean so a single deep basin or a
## tall massif cannot drag the comparison toward the answer we want.
func _terrain_median() -> float:
	var heights := PackedFloat32Array()
	var step := WorldGen.SIZE / WorldGen.QUADS
	for iz in WorldGen.QUADS + 1:
		for ix in WorldGen.QUADS + 1:
			var h := _world.surface_height_at(ix * step - HALF, iz * step - HALF)
			if h > WorldGen.NO_GROUND:
				heights.append(h)
	heights.sort()
	return heights[heights.size() / 2]


func _same(a: Array[Dictionary], b: Array[Dictionary]) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		var pa: Vector3 = a[i]["pos"]
		var pb: Vector3 = b[i]["pos"]
		if not pa.is_equal_approx(pb):
			return false
		if not is_equal_approx(a[i]["density"], b[i]["density"]):
			return false
	return true


## Builds a fresh WorldGen into the tree (its _ready runs the full generation
## synchronously), after seeding the process-global RNG to `salt` — a correct
## generator ignores it, so two builds with different salts must be identical.
func _build_world(salt: int) -> WorldGen:
	seed(salt)
	var w := WorldGen.new()
	add_child(w)
	return w


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
