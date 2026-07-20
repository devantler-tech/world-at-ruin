extends Node

## Guards for the region LANDFORM axis — regions differ in SHAPE, not only in
## colour.
##
## `ground_regions_test` pins which ground is where and what colour it is. This
## suite pins what that ground is SHAPED like, which neither existing golden can
## see: `world_gen_determinism_test` hashes geometry, so it notices that the
## world changed but never whether it changed in the right direction, and the
## region-field golden never looks at height at all. A landform axis could be
## wired up backwards, flattened to nothing, or quietly reduced to one character
## everywhere, and both would stay green.
##
## The laws, one arm each:
##   1. DATA — every region declares a landform, and one it can afford.
##   2. ASHFLATS IS THE IDENTITY — its parameters reproduce the base field
##      exactly, and the origin resolves to it fully decided. That pair is what
##      guarantees the shrine's ground did not move when this landed.
##   3. THE RIDGE OPERATOR IS MEAN-ZERO on the field it is applied to — a
##      landform change must not smuggle a bulk height change in with it.
##   4. CONTINUITY — the shipped height field has no step, including where
##      three regions meet.
##   5. WALKABLE — the worst open-ground grade stays under the floor limit.
##   6. THE REGIONS DIFFER IN HEIGHT — measured relief separates them.
##   7. RIDGING ACTUALLY CREASES — the crease knob does something no amount of
##      amplitude could do.
##
## Arms 6 and 7 are what make the rest non-vacuous. Every other assertion here
## passes on a world where all four regions were handed identical parameters:
## that world is continuous, walkable, mean-zero and identity-preserving, and it
## is also the single uniform landform this change exists to remove.

const EXTENT := 220.0

## Lattice spacing for the grade and relief sweeps, in metres. Fine enough to
## resolve a grade at the scale a walking character meets one; the guard states
## its own sampling scale rather than implying a true continuous maximum.
##
## The recorded numbers below are sampling-dependent and are NOT comparable
## across steps — the same baseline world measures 41.9 degrees at 1 m and 44.4
## at 0.5 m. Change this and every threshold here has to be re-measured.
const SAMPLE_STEP := 0.5

## Godot's `CharacterBody3D.floor_max_angle` default, which the wanderer uses
## unchanged: above this a surface stops being floor and becomes wall.
const FLOOR_MAX_ANGLE_DEG := 45.0

## The worst grade the open ground may reach, in degrees. A RATCHET, not a
## safety margin.
##
## Measured at `SAMPLE_STEP` on the shipped seed, away from the massif: the
## PRE-landform world already reached **44.42** degrees against a 45 degree
## floor limit, and this build reaches **43.00** — the landform axis leaves the
## open ground gentler than it found it, because every region other than
## `ashflats` is flatter than the baseline.
##
## The bar is therefore set just above THIS build rather than just under the
## floor limit, and that is deliberate: the pre-landform world would NOT pass it.
## Walkability was already a near miss here, so a threshold at 44.9 would licence
## spending 1.9 degrees of headroom the world never had. Ratchet it down as the
## ground gets gentler; never up to accommodate a re-tune.
const MAX_GRADE_DEG := 44.0

## The massif's buried skirt is DELIBERATELY a cliff — the heightfield cannot
## have holes, so the terrain dips under the cave floors and meets the rock hull
## below ground (see `world_gen._prepare_starter_cave`). It is not walkable
## ground and never was: including it measures 70 degrees on this build and 75
## on the baseline, which says nothing about either landform. Excluded by
## radius from `CAVE_SITE`, generously — over-excluding costs sample count,
## under-excluding measures the wrong thing.
const CAVE_KEEPOUT := 40.0

## Relief — the standard deviation of ground height inside a region's decided
## interior, in metres. Recorded headless on the shipped seed at `SAMPLE_STEP`,
## excluding the shrine clearing and the massif (both deliberate flattenings
## that describe no region, and both inside `ashflats`, so leaving them in would
## understate the baseline everything else is compared against).
##
## Measured: ashflats 2.218, rustmoor 1.549, cinderreach 1.120, bonepale 1.017.
## The floors sit under those with margin. They exist to catch the axis being
## flattened, not to pin one particular landscape — a re-tune that keeps the
## regions distinct is free to move them.
const RELIEF_FLOOR := {
	&"ashflats": 1.90,
	&"rustmoor": 1.20,
	&"cinderreach": 0.94,
	&"bonepale": 0.85,
}

## How far apart the tallest and flattest regions' relief must sit, in metres.
## Measured spread on the shipped seed is 1.20 m. Without a margin, "these
## regions differ" would pass on a difference no player could see.
const RELIEF_SPREAD := 0.85

## The second-difference ratio a strongly-ridged region must reach against the
## same region unridged. Measured 2.11 at `bonepale`'s 0.85; the floor is well
## under it, because this arm is asking whether the crease exists at all.
const CREASE_RATIO_FLOOR := 1.6

## Which region carries the crease. Named rather than discovered so the arm
## fails loudly if the creased region is ever quietly un-ridged.
const CREASED_REGION := &"bonepale"

var _failures: Array[String] = []
var _world: WorldGen
## The lattice sweep is the expensive part of this suite, and two arms read it.
var _worst_grade := 0.0


func _ready() -> void:
	_world = WorldGen.new()
	add_child(_world)
	_worst_grade = _worst_open_grade_deg()
	var relief := _measure_relief()

	_test_every_region_declares_an_affordable_landform()
	_test_ashflats_is_the_identity_landform()
	_test_ridge_is_mean_zero()
	_test_landform_is_continuous()
	_test_terrain_stays_walkable()
	_test_regions_differ_in_relief(relief)
	_test_ridging_creases_the_field()

	print("region relief (m): ashflats %.3f, rustmoor %.3f, cinderreach %.3f, bonepale %.3f; worst open grade %.2f deg" %
		[
			float(relief.get(&"ashflats", 0.0)),
			float(relief.get(&"rustmoor", 0.0)),
			float(relief.get(&"cinderreach", 0.0)),
			float(relief.get(&"bonepale", 0.0)),
			_worst_grade,
		])

	if _failures.is_empty():
		print("TEST PASS: region_landform")
	else:
		for f in _failures:
			printerr("FAIL: %s" % f)
		printerr("TEST FAIL: region_landform (%d)" % _failures.size())
	get_tree().quit(0 if _failures.is_empty() else 1)


func _fail(msg: String) -> void:
	_failures.append(msg)


## 1. Every region carries a landform, in ranges that mean something, and one it
## can pay for.
##
## The budget arm is the one that matters. A region's landform costs
## `amp * lerp(1, 2, ridged)` in gradient, and the Reach's ground is already at
## its walkability ceiling, so overspending produces a region the wanderer can
## see and cannot enter. This is the cheap, exact form of arm 5 — it names the
## offending region and the number, where the lattice sweep can only report that
## somewhere in the world is too steep.
func _test_every_region_declares_an_affordable_landform() -> void:
	for reg: Dictionary in GroundRegions.REGIONS:
		var name_: StringName = reg[&"name"]
		if not reg.has(&"amp") or not reg.has(&"ridged"):
			_fail("region %s declares no landform (amp/ridged)" % name_)
			continue
		var amp := float(reg[&"amp"])
		var ridged := float(reg[&"ridged"])
		if amp <= 0.1 or amp > 2.0:
			_fail("region %s amp %.3f is outside the sane range (0.1, 2.0]" % [name_, amp])
		if ridged < 0.0 or ridged > 1.0:
			_fail("region %s ridged %.3f is outside 0..1" % [name_, ridged])
		var cost := GroundRegions.landform_cost(amp, ridged)
		if cost > GroundRegions.LANDFORM_GRADIENT_BUDGET:
			_fail("region %s costs %.3f against the %.3f gradient budget (amp %.2f, ridged %.2f) — this is ground the wanderer cannot walk up" %
				[name_, cost, GroundRegions.LANDFORM_GRADIENT_BUDGET, amp, ridged])


## 2. The ashflats landform is the IDENTITY on the base field, and the shrine
## stands in a fully-decided patch of it.
##
## Together those mean the opening shot's ground is exactly what it was before
## regions had shapes — which is why the frames already captured at the shrine,
## and the Phase 0 gate that judged them, still describe this build. Checking
## the parameters alone would not do it: ashflats could be the identity
## everywhere while the origin sat in a blend band and moved anyway.
func _test_ashflats_is_the_identity_landform() -> void:
	var ashflats: Dictionary = GroundRegions.REGIONS[0]
	if ashflats[&"name"] != &"ashflats":
		_fail("REGIONS[0] is %s, not ashflats — this test's premise moved" % ashflats[&"name"])
		return

	# The identity claim, exactly: shaping a sample by the ashflats parameters
	# returns the sample, across the field's real range.
	for i in 41:
		var n := lerpf(-1.0, 1.0, float(i) / 40.0)
		var shaped := GroundRegions.shape(n, float(ashflats[&"amp"]), float(ashflats[&"ridged"]))
		if not is_equal_approx(shaped, n):
			_fail("ashflats is not the identity landform: shape(%.4f) = %.6f" % [n, shaped])
			return

	var at := GroundRegions.region_at(WorldGen.WORLD_SEED, EXTENT, 0.0, 0.0)
	if GroundRegions.REGIONS[at[&"region"]][&"name"] != &"ashflats":
		_fail("the origin is not ashflats — the shrine's ground is no longer pinned")
	if float(at[&"blend"]) < 1.0:
		_fail("the origin sits in a blend band (blend %.4f), so the shrine's ground moved" %
			float(at[&"blend"]))


## 3. The ridge operator neither raises nor sinks the ground it creases.
##
## `-2|n|` is strictly negative, so an unlifted ridge would drop every ridged
## region metres below its neighbours — a bulk height change wearing a landform
## change's clothes, and one that would read as a basin rather than as the
## spines it describes. `RIDGE_LIFT` cancels it, and it is measured against THIS
## field: change the base noise's type, frequency or octaves and the constant
## must be re-measured. That is what this arm catches, since nothing else would.
func _test_ridge_is_mean_zero() -> void:
	var total := 0.0
	var count := 0
	for sample in _base_field_samples():
		total += GroundRegions.ridge(sample)
		count += 1
	var mean := total / count
	# One centimetre of world height at HEIGHT_AMP, expressed in noise units.
	var tolerance := 0.01 / WorldGen.HEIGHT_AMP
	if absf(mean) > tolerance:
		_fail("the ridge operator has a mean of %.6f over the shipped field (tolerance %.6f) — RIDGE_LIFT (%.4f) needs re-measuring against the current base noise" %
			[mean, tolerance, GroundRegions.RIDGE_LIFT])


## 4. The height field has no step anywhere.
##
## This is the height twin of `ground_regions_test._test_palette_is_continuous`,
## and it exists for the same reason: a landform blended against the runner-up
## region only would jump wherever the SECOND-nearest site changes identity
## while the owner stays put, and that discontinuity hides where the THIRD site
## takes over. Sweeping a lattice rather than walking site to site is what puts
## those places inside the test.
##
## A step shows up as a grade far beyond anything noise of this amplitude can
## produce, so the bound is deliberately loose — arm 5 is the tight one. Stated
## as a grade rather than a raw delta so it means the same at any sampling step.
func _test_landform_is_continuous() -> void:
	if _worst_grade >= 80.0:
		_fail("the height field steps: %.2f deg at %.1f m sampling is a discontinuity, not a slope" %
			[_worst_grade, SAMPLE_STEP])


## 5. The open ground stays floor rather than becoming wall.
func _test_terrain_stays_walkable() -> void:
	if _worst_grade > MAX_GRADE_DEG:
		_fail("worst open grade %.2f deg exceeds %.1f deg (character floor limit %.1f) — a region's landform is too steep for the ground under it" %
			[_worst_grade, MAX_GRADE_DEG, FLOOR_MAX_ANGLE_DEG])


## 6. The regions are actually different heights.
func _test_regions_differ_in_relief(relief: Dictionary) -> void:
	for name_: StringName in RELIEF_FLOOR:
		var measured := float(relief.get(name_, 0.0))
		var floor_ := float(RELIEF_FLOOR[name_])
		if measured < floor_:
			_fail("region %s relief %.3f m is under its floor %.3f m — its landform has been flattened" %
				[name_, measured, floor_])

	var tallest := -INF
	var flattest := INF
	for name_: StringName in RELIEF_FLOOR:
		var measured := float(relief.get(name_, 0.0))
		tallest = maxf(tallest, measured)
		flattest = minf(flattest, measured)
	if tallest - flattest < RELIEF_SPREAD:
		_fail("region relief spans only %.3f m (%.3f to %.3f), under the %.2f m spread — the regions are one landform in four paints" %
			[tallest - flattest, flattest, tallest, RELIEF_SPREAD])


## 7. Ridging creases the field, and creasing is not something amplitude can do.
##
## Measured as the mean absolute SECOND difference of the shaped field against
## the same field at the same `amp` with `ridged` zeroed. That ratio is the one
## quantity only the crease knob can move: `amp` divides out of it exactly, and
## the world's global detail layer — which carries curvature of its own — is not
## in it at all. Measuring curvature on the finished terrain instead would mix
## all three, and did: on the shipped build the creased region's terrain
## curvature sat within 7% of the flattest region's, hiding a crease that is
## really 2.11x.
##
## The un-ridged regions are the control, and it is an exact one: their ratio is
## 1.0000 by construction, so a ratio that drifts off 1 there means `shape` has
## started doing something to a region that asked for nothing.
func _test_ridging_creases_the_field() -> void:
	var found := false
	for reg: Dictionary in GroundRegions.REGIONS:
		var name_: StringName = reg[&"name"]
		var amp := float(reg[&"amp"])
		var ridged := float(reg[&"ridged"])
		var ratio := _crease_ratio(amp, ridged)
		if ridged == 0.0:
			if not is_equal_approx(ratio, 1.0):
				_fail("region %s asks for no ridging but its crease ratio is %.4f, not 1 — shape() is creasing a region that did not ask" %
					[name_, ratio])
			continue
		if name_ != CREASED_REGION:
			continue
		found = true
		if ratio < CREASE_RATIO_FLOOR:
			_fail("region %s ridges at %.2f but creases the field only %.3fx (floor %.2fx) — the crease knob is not producing an edge" %
				[name_, ridged, ratio, CREASE_RATIO_FLOOR])
	if not found:
		_fail("no region named %s carries ridging — nothing in the world creases" % CREASED_REGION)


## The mean absolute second difference of a landform against the same landform
## unridged. 1.0 means ridging changed nothing; above 1 means it added edges.
## 🔴 Second differences are taken WITHIN a transect and never across the join
## between two of them. Consecutive transects are 5.5 m apart, so the field
## either side of a join is uncorrelated and its second difference is enormous —
## on the order of the field's whole range rather than of a 0.5 m step. Those
## junctions land in the numerator and the denominator alike, so they do not
## look like an error: they quietly drag the ratio toward 1. Measured, 82 joins
## against 18,000 real samples reported `bonepale` creasing 1.45x when it
## creases 2.11x, which is the difference between this arm passing and failing.
func _crease_ratio(amp: float, ridged: float) -> float:
	var creased := 0.0
	var rolled := 0.0
	for row: PackedFloat32Array in _base_field_transects():
		for i in range(1, row.size() - 1):
			var a := row[i - 1]
			var b := row[i]
			var c := row[i + 1]
			creased += absf(
				GroundRegions.shape(a, amp, ridged)
				- 2.0 * GroundRegions.shape(b, amp, ridged)
				+ GroundRegions.shape(c, amp, ridged)
			)
			rolled += absf(
				GroundRegions.shape(a, amp, 0.0)
				- 2.0 * GroundRegions.shape(b, amp, 0.0)
				+ GroundRegions.shape(c, amp, 0.0)
			)
	return creased / maxf(rolled, 1e-9)


## A FastNoiseLite configured exactly as the world's base field. Built here
## rather than read off WorldGen because the arms above have to be able to
## notice the world's configuration changing out from under a measured
## constant — which is the whole point of arm 3.
func _base_noise() -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = WorldGen.WORLD_SEED
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n.frequency = 0.011
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = 4
	return n


## The base field over the terrain grid — the same nodes the world bakes.
func _base_field_samples() -> PackedFloat32Array:
	var n := _base_noise()
	var step := WorldGen.SIZE / WorldGen.QUADS
	var half := WorldGen.SIZE / 2.0
	var out := PackedFloat32Array()
	for iz in WorldGen.QUADS + 1:
		for ix in WorldGen.QUADS + 1:
			out.append(n.get_noise_2d(ix * step - half, iz * step - half))
	return out


## Dense west-to-east transects of the base field, for curvature — kept as
## separate rows rather than one flat run, for the reason `_crease_ratio`
## spells out. Sampled at `SAMPLE_STEP` so a second difference sees the field
## at the scale the terrain is actually built at.
func _base_field_transects() -> Array[PackedFloat32Array]:
	var n := _base_noise()
	var half := EXTENT / 2.0
	var count := int(EXTENT / SAMPLE_STEP)
	var out: Array[PackedFloat32Array] = []
	for iz in 41:
		var z := iz * (EXTENT / 40.0) - half
		var row := PackedFloat32Array()
		for ix in count + 1:
			row.append(n.get_noise_2d(ix * SAMPLE_STEP - half, z))
		out.append(row)
	return out


## The steepest grade between lattice neighbours over the OPEN terrain, in
## degrees. Measured through `height_at` — the shipped function, not a
## re-derivation of it — with the massif's deliberate skirt excluded.
func _worst_open_grade_deg() -> float:
	var half := EXTENT / 2.0
	var count := int(EXTENT / SAMPLE_STEP)
	var worst := 0.0
	var row := PackedFloat32Array()
	var prev := PackedFloat32Array()
	row.resize(count + 1)
	prev.resize(count + 1)
	for iz in count + 1:
		var z := iz * SAMPLE_STEP - half
		for ix in count + 1:
			row[ix] = _world.height_at(ix * SAMPLE_STEP - half, z)
		for ix in count + 1:
			var x := ix * SAMPLE_STEP - half
			if (Vector2(x, z) - WorldGen.CAVE_SITE).length() <= CAVE_KEEPOUT:
				continue
			if ix > 0:
				worst = maxf(worst, absf(row[ix] - row[ix - 1]))
			if iz > 0:
				worst = maxf(worst, absf(row[ix] - prev[ix]))
		var swap := prev
		prev = row
		row = swap
	return rad_to_deg(atan(worst / SAMPLE_STEP))


## Relief per region: the standard deviation of ground height across each
## region's DECIDED interior, in metres. Decided interiors only — a blend band
## belongs to no region and would smear the separation being measured.
func _measure_relief() -> Dictionary:
	var sites := GroundRegions.sites(WorldGen.WORLD_SEED, EXTENT)
	var half := EXTENT / 2.0
	var count := int(EXTENT / SAMPLE_STEP)
	var sums := {}
	var squares := {}
	var totals := {}
	for reg: Dictionary in GroundRegions.REGIONS:
		sums[reg[&"name"]] = 0.0
		squares[reg[&"name"]] = 0.0
		totals[reg[&"name"]] = 0
	for iz in count + 1:
		var z := iz * SAMPLE_STEP - half
		for ix in count + 1:
			var x := ix * SAMPLE_STEP - half
			if Vector2(x, z).length() < WorldGen.SHRINE_CLEAR_RADIUS * 1.5:
				continue
			if (Vector2(x, z) - WorldGen.CAVE_SITE).length() <= CAVE_KEEPOUT:
				continue
			var at := GroundRegions.region_for(sites, x, z)
			if float(at[&"blend"]) < 1.0:
				continue
			var name_: StringName = GroundRegions.REGIONS[at[&"region"]][&"name"]
			var h := _world.height_at(x, z)
			sums[name_] = float(sums[name_]) + h
			squares[name_] = float(squares[name_]) + h * h
			totals[name_] = int(totals[name_]) + 1

	var relief := {}
	for reg: Dictionary in GroundRegions.REGIONS:
		var name_: StringName = reg[&"name"]
		var n := int(totals[name_])
		if n < 1000:
			_fail("region %s has only %d decided interior samples — too few to measure relief" %
				[name_, n])
			relief[name_] = 0.0
			continue
		var mean := float(sums[name_]) / n
		var variance := maxf(float(squares[name_]) / n - mean * mean, 0.0)
		relief[name_] = sqrt(variance)
	return relief
