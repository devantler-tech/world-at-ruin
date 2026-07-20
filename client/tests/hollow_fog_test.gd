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
##  9. RENDERABLE — every placement builds into a FogVolume that actually
##     carries its density. Laws 1–8 stop at the placement dictionary, so a
##     materialless volume satisfies all of them while rendering nothing.
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
	var pools := HollowFog.place(
		_world.surface_height_at, WorldGen.SIZE, WorldGen.NO_GROUND, _world.cave_protects
	)

	# 1. PRESENT
	if pools.size() < MIN_POOLS:
		_fail("shipped terrain produced %d ash pools, need at least %d — every law below would pass vacuously" % [pools.size(), MIN_POOLS])
		return
	if pools.size() > HollowFog.MAX_VOLUMES:
		_fail("placed %d pools, cap is %d" % [pools.size(), HollowFog.MAX_VOLUMES])
		return

	# 6a. THE CAVE KEEPS ITS DARKNESS.
	#
	# The terrain height field is deliberately DEPRESSED beneath the starter-cave
	# massif, so the buried skirt is not a landscape hollow at all — it is by far
	# the deepest thing the sampler can see (7.63 m, against 2.90 m for the
	# deepest real basin). Unfiltered it took the densest pool in the world and
	# put it 6 m from the cave spawn: a slot stolen from the Reach, and outdoor
	# fog inside an interior whose darkness is designed.
	for p: Dictionary in pools:
		var pos: Vector3 = p["pos"]
		if _world.cave_protects(pos.x, pos.z):
			_fail("pool at (%.1f, %.1f) sits on the cave's buried skirt (relief %.2f m) — that is the massif's technical depression, not a hollow, and it fogs the cave interior" % [pos.x, pos.z, p["relief"]])
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
	var again := HollowFog.place(
		_world.surface_height_at, WorldGen.SIZE, WorldGen.NO_GROUND, _world.cave_protects
	)
	if not _same(pools, again):
		_fail("two placements over the same terrain differ — placement is not deterministic")
		return
	var other_world := _build_world(9173)
	var other := HollowFog.place(
		other_world.surface_height_at, WorldGen.SIZE, WorldGen.NO_GROUND, other_world.cave_protects
	)
	if not _same(pools, other):
		_fail("placement changed when the process-global RNG was seeded differently — the placer is drawing from a shared stream")
		return

	# 8. THE RELIEF TEST IS LOAD-BEARING
	var control := _run_controls()
	if control != "":
		_fail(control)
		return

	# 8b. BUILDS ON CAPABLE HARDWARE, BOTH STATES.
	#
	# #211's player opt-in is retired with #233 — it existed because the ash had
	# no drift, and the ash now drifts. What remains is the hardware fact, and
	# both of ITS states still matter: default-on is only correct if a device
	# that cannot render volumetrics still declines to build invisible nodes it
	# would pay a per-frame cost for.
	if not HollowFog.should_build(true):
		_fail("pools do NOT build on a GPU that can render them — after #233 the ash is default-on, so this makes the feature unreachable for everyone")
		return
	if HollowFog.should_build(false):
		_fail("pools build where volumetrics cannot render — invisible nodes with a per-frame cost")
		return

	# 9. RENDERABLE — the placement actually becomes visible air.
	#
	# Laws 1–8 all reason about the placement DICTIONARY. That is one step
	# short of the promise: a perfectly-placed pool that builds into a
	# materialless FogVolume contributes no density and renders nothing, so
	# every law above passes while the player sees no ash at all. This law
	# reaches through build_volume() to the node main.gd actually adds.
	for i in pools.size():
		var vol := HollowFog.build_volume(pools[i])
		var mat := vol.material as FogMaterial
		var want: float = pools[i]["density"]
		# The volume is ours and never enters the tree, so free it before any
		# early return — otherwise a failing law leaks every RID it built.
		vol.free()
		if mat == null:
			_fail("pool %d built a FogVolume with no FogMaterial — it contributes no density and renders nothing, so the ash is invisible" % i)
			return
		if not is_equal_approx(mat.density, want):
			_fail("pool %d built at density %.4f but its placement asked for %.4f — the depth-scaled density never reaches the renderer" % [i, mat.density, want])
			return
		if mat.density <= 0.0:
			_fail("pool %d built at density %.4f — non-positive density is invisible air" % [i, mat.density])
			return

	# 10. DEPTH READS AS DENSITY — the dev log tells the player that deeper
	# hollows hold more ash, so that has to be true of the shipped world and
	# not merely of the formula.
	#
	# It is easy to satisfy law 9 and still fail this: if FULL_DENSITY_RELIEF
	# sits below the terrain's deepest hollow, every hollow past it clamps to
	# the maximum and the gradient collapses. At 3.0 the six shipped pools
	# spanned 0.0433-0.0500 — a 15% spread across hollows whose depth varies
	# nearly threefold — which is a flat set of pools wearing a gradient's
	# clothing. Only assert it where the terrain actually offers the range.
	var deep: Dictionary = pools[0]
	var shallow: Dictionary = pools[pools.size() - 1]
	if float(deep["relief"]) >= float(shallow["relief"]) * 2.0:
		var ratio := float(deep["density"]) / maxf(float(shallow["density"]), 1e-9)
		if ratio < 1.5:
			_fail("deepest hollow (%.2f m) is only %.2fx denser than the shallowest (%.2f m) — depth is not reading as density; FULL_DENSITY_RELIEF (%.1f m) is probably clamping below the terrain's real depth range" % [
				deep["relief"], ratio, shallow["relief"], HollowFog.FULL_DENSITY_RELIEF
			])
			return

	# The capture marker is a MACHINE CONTRACT (#232). CI parses this line to
	# record whether the published frames contain pools at all. It stays a
	# SECOND gate on top of the volumetrics verdict even now that the opt-in is
	# gone, because the two can still disagree: a terrain offering no hollow
	# deep enough to clear MIN_RELIEF renders volumetrics with zero pools.
	var built_line: String = HollowFog.marker(true, true, 6)
	var unbuilt_line: String = HollowFog.marker(false, false, 6)
	for line: String in [built_line, unbuilt_line]:
		if not line.begins_with(HollowFog.CAPTURE_MARKER + " "):
			_fail("marker() must start with CAPTURE_MARKER and a space — CI greps for it")
			return
	# CI reads the field after the marker token as the verdict. CAPTURE_MARKER
	# contains a space, so split off the marker prefix first rather than
	# indexing a fixed field number.
	if built_line.trim_prefix(HollowFog.CAPTURE_MARKER + " ").split(" ")[0] != "on":
		_fail("marker(built) must report 'on' immediately after the marker — CI parses it")
		return
	if unbuilt_line.trim_prefix(HollowFog.CAPTURE_MARKER + " ").split(" ")[0] != "off":
		_fail("marker(not built) must report 'off' immediately after the marker — CI parses it")
		return
	# The two unbuilt reasons stay distinguishable: "no GPU" and "no hollow deep
	# enough" are different facts and a reviewer acts on them differently.
	if HollowFog.marker(false, true, 6) == HollowFog.marker(false, false, 6):
		_fail("marker() must distinguish 'no qualifying hollow' from 'volumetrics unavailable'")
		return

	var drift := _run_drift_laws(pools)
	if drift != "":
		_fail(drift)
		return

	print("TEST PASS — %d ash pools, shallowest clears its surroundings by %.2f m, %.2f m below world median, %s, every built volume carries its density, deepest %.2fx denser than shallowest, drift swells +/-%.0f%% around each placed density on a %.0f s gust that stays staggered across the Reach" % [
		pools.size(), worst_relief, drop, "4 controls held",
		float(deep["density"]) / maxf(float(shallow["density"]), 1e-9),
		HollowFog.DRIFT_SWING * 100.0, TAU / HollowFog.DRIFT_SPEED
	])
	get_tree().quit(0)


## How many samples one drift period is cut into. 64 lands within 0.12% of the
## true extremes of a sinusoid, which is far inside every margin asserted below.
const DRIFT_SAMPLES := 64


## The drift laws (#233), or "" if they all hold.
##
## Everything here is a pure function of position and time, so these run with no
## GPU and no rendering — which is the point: a FogVolume contributes no
## readable pixels headless, so the shape of the swell is only ever verifiable
## as arithmetic. What a frame can show (does it READ as weather) is a judgement
## made on captures and recorded on the PR; what a test can prove is that the
## swell exists, has the intended size and mean, varies with position, and never
## moves the pool.
func _run_drift_laws(pools: Array[Dictionary]) -> String:
	# D0. NON-VACUITY FLOOR — before asserting the drift has the right SHAPE,
	# assert there is a drift at all. Every law below is derived from the
	# constants, so all of them would pass trivially if the constants were zero:
	# a zero swing has a zero mean, stays in lockstep with itself, and matches
	# its own derived amplitude exactly. This floor is what stops "the ash
	# drifts" from being provable by a build in which it does not.
	if HollowFog.DRIFT_SWING < 0.05:
		return "DRIFT_SWING is %.3f — below 0.05 the density swell is not visible, and every derived law below would pass on a build with no drift" % HollowFog.DRIFT_SWING
	if HollowFog.DRIFT_SPEED <= 0.0:
		return "DRIFT_SPEED is %.3f — a non-positive speed freezes the phase, so nothing ever moves" % HollowFog.DRIFT_SPEED

	var period := TAU / HollowFog.DRIFT_SPEED
	var probe: Vector3 = pools[0]["pos"]
	var placed: float = pools[0]["density"]

	# D1. THE PLACEMENT IS THE RESTING STATE — drift has zero mean.
	#
	# Load-bearing well beyond tidiness: the world golden, the headless
	# placement record and #211's density tuning all describe the pool AT ITS
	# PLACEMENT. A drift with a biased mean would silently move the shipped
	# world off the values every one of those pinned, and nothing else here
	# would notice. Sampled over exactly one period, endpoint excluded, so a
	# sinusoid's mean is zero to float precision.
	var sum_density := 0.0
	for i in DRIFT_SAMPLES:
		var t := period * float(i) / float(DRIFT_SAMPLES)
		sum_density += HollowFog.drift_density(placed, probe, t)
	var mean_density := sum_density / float(DRIFT_SAMPLES)
	if absf(mean_density - placed) > placed * 0.01:
		return "mean drifted density is %.4f but the pool was placed at %.4f — drift must modulate around the placement, not shift it, or the tuned density is never what ships" % [mean_density, placed]

	# D2. THE SWELL AND THE TRAVEL HAVE THE INTENDED SIZE.
	#
	# Derived from the constants rather than hard-coded, so a deliberate retune
	# does not need this test rewritten — while D0 above keeps that derivation
	# from collapsing to a tautology.
	var min_density := INF
	var max_density := -INF
	for i in DRIFT_SAMPLES:
		var t := period * float(i) / float(DRIFT_SAMPLES)
		var d := HollowFog.drift_density(placed, probe, t)
		min_density = minf(min_density, d)
		max_density = maxf(max_density, d)
	var want_swing := placed * HollowFog.DRIFT_SWING
	if absf((max_density - placed) - want_swing) > want_swing * 0.05:
		return "density peaks %.4f above the placed %.4f, but DRIFT_SWING asks for %.4f — the swell is not the size the constant claims" % [max_density - placed, placed, want_swing]
	if absf((placed - min_density) - want_swing) > want_swing * 0.05:
		return "density troughs %.4f below the placed %.4f, but DRIFT_SWING asks for %.4f — the swell is asymmetric" % [placed - min_density, placed, want_swing]
	if min_density <= 0.0:
		return "density reaches %.4f — a pool that thins to nothing blinks out instead of breathing" % min_density
	# D3. ONE GUST CROSSING THE REACH, not every pool pulsing as one.
	#
	# This is the difference between weather and a global animation. Pools at
	# different places along the wind must be at different phases, or the whole
	# world thickens and thins in lockstep — which reads as a screen effect
	# rather than as air.
	#
	# Only pools genuinely separated ALONG the wind can be staggered — two
	# sitting side by side across it are at the same phase by definition, and
	# reading that as lockstep would be this test failing for the wrong reason.
	# So eligibility is tracked separately from the verdict: a terrain that
	# offers no along-wind pair leaves this law unproven rather than failed.
	var eligible := 0
	var staggered := false
	for i in pools.size():
		for j in range(i + 1, pools.size()):
			var a: Vector3 = pools[i]["pos"]
			var b: Vector3 = pools[j]["pos"]
			if absf((a - b).dot(Wind.axis())) < 1.0:
				continue
			eligible += 1
			# Compared as a FRACTION of each pool's own placed density: two
			# hollows of different depth carry different densities, so an
			# absolute difference would report a stagger that is really just
			# the depth gradient of law 10.
			for s in DRIFT_SAMPLES:
				var t := period * float(s) / float(DRIFT_SAMPLES)
				var fa := HollowFog.drift_density(1.0, a, t)
				var fb := HollowFog.drift_density(1.0, b, t)
				if absf(fa - fb) > HollowFog.DRIFT_SWING * 0.05:
					staggered = true
					break
			if staggered:
				break
		if staggered:
			break
	if eligible > 0 and not staggered:
		return "%d pool pairs are separated along the wind, yet every pool swells in lockstep — the phase does not vary with position, so this reads as one global pulse rather than a gust crossing the Reach" % eligible

	# D4. THE POOL DOES NOT MOVE.
	#
	# Asserted as a LAW rather than left implicit, because the first build of
	# #233 did translate the volume and the translation measured as invisible
	# (mean |dRGB| 0.0012 against a noise floor of 0.0115). Removing it is only
	# durable if something notices when it comes back: a reintroduced offset
	# would silently put the pool somewhere the world golden and the headless
	# placement record both say it is not.
	var still := HollowFog.build_volume(pools[0])
	var placed_pos: Vector3 = pools[0]["pos"]
	for i in DRIFT_SAMPLES:
		var t := period * float(i) / float(DRIFT_SAMPLES)
		HollowFog.apply_drift(still, pools[0], t)
		if still.position.distance_to(placed_pos) > 1e-6:
			var slipped := still.position.distance_to(placed_pos)
			still.free()
			return "apply_drift moved the volume %.4f m off its placement — drift is density only, and a moving pool no longer sits where the golden and the placement record say it does" % slipped

	# D5. THE SWELL REACHES THE NODE.
	#
	# The mirror of law 9, and for the same reason: every law above reasons
	# about pure functions, and all of them stay green if apply_drift() computes
	# the right number and assigns it nowhere. That is a silent no-op — the
	# exact failure mode #211 shipped when build_volume() configured a
	# FogMaterial it never attached, leaving the whole feature invisible while
	# its tests passed.
	var at_rest_density: float = pools[0]["density"]
	# A quarter period past the placement's own phase zero is where sin() is
	# furthest from zero, so this is the sample most likely to differ. Picking
	# it deliberately rather than trusting an arbitrary t is the #243 lesson:
	# a periodic signal sampled at its zero-crossings proves nothing.
	var peak_t := (probe.dot(Wind.axis()) / HollowFog.DRIFT_WAVELENGTH + PI / 2.0) / HollowFog.DRIFT_SPEED
	HollowFog.apply_drift(still, pools[0], peak_t)
	var redensified := absf((still.material as FogMaterial).density - at_rest_density)
	var want_density_delta: float = placed * HollowFog.DRIFT_SWING
	still.free()
	if redensified < want_density_delta * 0.95:
		return "apply_drift changed the built volume's density by %.4f at its phase peak, short of the %.4f DRIFT_SWING asks for — the computed density is not reaching the material" % [redensified, want_density_delta]
	return ""


## Synthetic terrains with a known right answer. Each isolates ONE claim, so a
## failure names which discrimination the placer lost.
func _run_controls() -> String:
	# FLAT — nothing is below its surroundings anywhere, so nothing is a
	# hollow. A placer that simply seeds pools on a lattice fails here.
	var flat := HollowFog.place(
		func(x: float, z: float) -> float:
			return 0.0 if absf(x) <= HALF and absf(z) <= HALF else WorldGen.NO_GROUND,
		WorldGen.SIZE, WorldGen.NO_GROUND, _never
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
		WorldGen.SIZE, WorldGen.NO_GROUND, _never
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
		_depression(BASIN_AT, HALF), WorldGen.SIZE, WorldGen.NO_GROUND, _never
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
		_depression(BASIN_AT, ISLAND_HALF), WorldGen.SIZE, WorldGen.NO_GROUND, _never
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


## Keep-out for the synthetic control terrains, which have no cave.
func _never(_x: float, _z: float) -> bool:
	return false


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
