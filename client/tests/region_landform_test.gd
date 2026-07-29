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
##   5. WALKABLE — every region's own worst grade stays under its ratchet, and
##      the world's worst stays under the floor limit.
##   6. THE REGIONS DIFFER IN HEIGHT — measured relief separates them, and the
##      tallest is not the one the player starts in.
##   7. RIDGING ACTUALLY CREASES — the crease knob does something no amount of
##      amplitude could do.
##
## Arms 6 and 7 are what make the rest non-vacuous. Every other assertion here
## passes on a world where all four regions were handed identical parameters:
## that world is continuous, walkable, mean-zero and identity-preserving, and it
## is also the single uniform landform this change exists to remove.

const EXTENT := 220.0

## Lattice spacing for the RELIEF sweep, in metres.
##
## The relief figures below are sampling-dependent and are NOT comparable across
## steps, so changing this means re-measuring every one of them. The grade arms
## do not use it: a collision face is a fixed piece of the world, so its angle
## is a property of the mesh rather than of how densely anything sampled it.
const SAMPLE_STEP := 0.5

## Godot's `CharacterBody3D.floor_max_angle` default, which the wanderer uses
## unchanged: above this a surface stops being floor and becomes wall.
const FLOOR_MAX_ANGLE_DEG := 45.0

## The steepest collision FACE the open terrain may reach anywhere, in degrees.
## A RATCHET, not a safety margin.
##
## Measured on the shipped seed away from the massif: this world reaches
## **44.18** degrees against a 45 degree floor limit. That is 0.82 degrees of
## real margin, and it is genuinely that tight — the Reach has always run this
## close to the limit; only a gentler proxy made it look otherwise.
##
## The bar is set just above THIS world rather than just under the floor limit,
## and that is deliberate: a threshold at 44.9 would licence letting the ground
## get steeper still without anything here noticing. Ratchet it down as the
## ground gets gentler; never up to accommodate a re-tune.
const MAX_GRADE_DEG := 44.5

## The steepest face each region's OWN decided interior may reach, in degrees.
## Ratchets, measured on the shipped seed.
##
## 🔴 This is the walkability law; `MAX_GRADE_DEG` above is only its weakest
## form. A global maximum is held by whichever region is steepest, so it is
## blind to every other one — and not by a little. Measured: raising
## `bonepale`'s amplitude to 0.62 takes its own ground from 36.92 degrees to
## **39.76**, a change large enough to alter what that region is to walk across,
## while the global reading does not move at all — 44.18 either way, to the
## hundredth. A global-only arm stays green on exactly that. Per region, the
## drift has nowhere to hide.
##
## Measured: cinderreach 43.38, ashflats 41.55, rustmoor 41.04, bonepale 36.92.
## Each bar sits just above its own region, which is what makes them ratchets
## rather than a shared allowance the regions can trade between themselves.
##
## These sit BELOW the global bar because a region only owns faces whose three
## vertices agree on it (see `_sweep_face_grades`): the world's steepest ground
## is in the blend bands between regions, which belong to none of them.
const MAX_REGION_GRADE_DEG := {
	&"ashflats": 42.0,
	&"cinderreach": 43.8,
	&"rustmoor": 41.5,
	&"bonepale": 37.5,
}

## The massif's buried skirt is DELIBERATELY a cliff — the heightfield cannot
## have holes, so the terrain dips under the cave floors and meets the rock hull
## below ground (see `world_gen._prepare_starter_cave`). It is not walkable
## ground and never was: including it puts the world's steepest face at 66.33
## degrees, which says nothing about any landform. Excluded by radius from
## `CAVE_SITE`, generously — over-excluding costs sample count, under-excluding
## measures the wrong thing.
const CAVE_KEEPOUT := 40.0

## Relief — the standard deviation of ground height inside a region's decided
## interior, in metres. Recorded headless on the shipped seed at `SAMPLE_STEP`,
## excluding the shrine clearing and the massif (both deliberate flattenings
## that describe no region, and both inside `ashflats`, so leaving them in would
## understate the baseline everything else is compared against).
##
## Measured: cinderreach 2.324, ashflats 2.218, rustmoor 1.549, bonepale 1.017.
## The floors sit under those with margin. They exist to catch the axis being
## flattened, not to pin one particular landscape — a re-tune that keeps the
## regions distinct is free to move them.
const RELIEF_FLOOR := {
	&"ashflats": 1.90,
	&"rustmoor": 1.20,
	&"cinderreach": 2.05,
	&"bonepale": 0.85,
}

## The region that must stand tallest, and by how much over the runner-up.
##
## Named rather than discovered, for the reason `CREASED_REGION` is: the point
## of the landform axis is that the Reach has high ground that is NOT the ground
## the player starts on, and a test that simply asked "is some region tallest"
## would stay green if that quietly went back to being `ashflats`. Measured
## margin on the shipped seed is 0.106 m (2.324 against 2.218).
const TALLEST_REGION := &"cinderreach"
const TALLEST_MARGIN := 0.05

## How far apart the tallest and flattest regions' relief must sit, in metres.
## Measured spread on the shipped seed is 1.31 m (cinderreach 2.324 against
## bonepale 1.017). Without a margin, "these regions differ" would pass on a
## difference no player could see.
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
## The lattice sweep is the expensive part of this suite, and three arms read it.
var _worst_grade := 0.0
## Worst grade inside each region's decided interior, in degrees. Filled by the
## same sweep that produces `_worst_grade`.
var _region_worst := {}


func _ready() -> void:
	_world = WorldGen.new()
	add_child(_world)
	_worst_grade = _sweep_face_grades()
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
	# Printed per region because these are the numbers the ratchets are set
	# from: a re-tune has to be able to read its own measurement off the run
	# rather than re-deriving it in a throwaway harness.
	print("worst grade per region (deg): ashflats %.2f, rustmoor %.2f, cinderreach %.2f, bonepale %.2f" %
		[
			float(_region_worst.get(&"ashflats", 0.0)),
			float(_region_worst.get(&"rustmoor", 0.0)),
			float(_region_worst.get(&"cinderreach", 0.0)),
			float(_region_worst.get(&"bonepale", 0.0)),
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
## The budget arm is a COARSE backstop, not the walkability law — arm 5 is, and
## it is the measured one. `amp * lerp(1, 2, ridged)` cannot price a region's
## real steepness, because a region's steepest face is carried substantially by
## the global detail layer and by its boundaries, neither of which scales with
## `amp` (see `GroundRegions.LANDFORM_GRADIENT_BUDGET` — the model puts
## `cinderreach` at 46.5 degrees where it measures 43.38, over-predicting by
## 3.12 and forbidding a landform that is in fact walkable). What this arm still
## buys is a cheap, named failure for a landform that is absurd on its face,
## before the sweep has to find it.
func _test_every_region_declares_an_affordable_landform() -> void:
	for reg: Dictionary in GroundRegions.REGIONS:
		var region_name: StringName = reg[&"name"]
		if not reg.has(&"amp") or not reg.has(&"ridged"):
			_fail("region %s declares no landform (amp/ridged)" % region_name)
			continue
		var amp := float(reg[&"amp"])
		var ridged := float(reg[&"ridged"])
		if amp <= 0.1 or amp > 2.0:
			_fail("region %s amp %.3f is outside the sane range (0.1, 2.0]" % [region_name, amp])
		if ridged < 0.0 or ridged > 1.0:
			_fail("region %s ridged %.3f is outside 0..1" % [region_name, ridged])
		var cost := GroundRegions.landform_cost(amp, ridged)
		if cost > GroundRegions.LANDFORM_GRADIENT_BUDGET:
			_fail("region %s costs %.3f against the %.3f gradient budget (amp %.2f, ridged %.2f) — this is ground the wanderer cannot walk up" %
				[region_name, cost, GroundRegions.LANDFORM_GRADIENT_BUDGET, amp, ridged])


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

	# The origin ALONE is not the claim. What the dev log promises a player is
	# that the ground they start on has not moved — and that is the clearing, not
	# a point. So it is MEASURED, in millimetres, against the pre-landform field.
	#
	# 🔴 An exact-identity assertion here FAILED, and it was right to. The
	# clearing's outer rim reaches into a blend band: at (11.2, 7.0) the landform
	# resolves to amp 0.9961 / ridged 0.0039 rather than a clean (1, 0). The
	# honest reading is not that the promise is false but that it needs a unit and
	# a place — a player cares about metres of ground underfoot, not about a blend
	# weight four decimals off one. Measured on the shipped seed, the clearing has
	# three distinct zones:
	#
	#   * the eased core (r <= 0.35, where `height_at` flattens it): 0.000 mm
	#   * out to r = 0.86 of the radius: under 1 mm
	#   * the outermost rim, worst 111 mm at (3.5, 13.3), r ~ 0.98
	#
	# The rim moving is CORRECT, not tolerated: that is where the clearing hands
	# over to open ground, and open ground is exactly what this change reshapes.
	# What must not move is the ground the player stands on and sees, and that is
	# the core — which is bit-identical.
	#
	# Measured on the RAW landform term, before `height_at` eases the clearing
	# flat. That easing only shrinks the deviation, so these bounds are the
	# conservative ones.
	var sites := GroundRegions.sites(WorldGen.WORLD_SEED, EXTENT)
	var noise := _base_noise()
	var radius := WorldGen.SHRINE_CLEAR_RADIUS
	var worst := 0.0
	var worst_at := Vector2.ZERO
	var core_worst := 0.0
	var inner_worst := 0.0
	var checked := 0
	for iz in 41:
		for ix in 41:
			var x := lerpf(-radius, radius, float(ix) / 40.0)
			var z := lerpf(-radius, radius, float(iz) / 40.0)
			var r := Vector2(x, z).length() / radius
			if r > 1.0:
				continue
			checked += 1
			var land := GroundRegions.landform_for(sites, x, z)
			var n := noise.get_noise_2d(x, z)
			var moved := absf(
				GroundRegions.shape(n, float(land[&"amp"]), float(land[&"ridged"])) - n
			) * WorldGen.HEIGHT_AMP
			if moved > worst:
				worst = moved
				worst_at = Vector2(x, z)
			if r <= 0.35:
				core_worst = maxf(core_worst, moved)
			if r <= 0.85:
				inner_worst = maxf(inner_worst, moved)
	if checked < 500:
		_fail("shrine-clearing sweep covered only %d points — too few to stand behind" % checked)
	# The core is EXACT, not merely small: it is fully-decided ashflats, and
	# ashflats is the identity landform, so this is arithmetic rather than a
	# tolerance. A non-zero here means the origin cell stopped being pinned.
	if core_worst > 0.0000001:
		_fail("the shrine's eased core moved %.6f mm — the origin cell is no longer fully-decided ashflats" %
			(core_worst * 1000.0))
	# Out to 0.85 of the radius the blend has not reached: a millimetre is the
	# floating-point floor, not a budget being spent.
	if inner_worst > 0.001:
		_fail("the shrine clearing moved %.1f mm inside 0.85 of its radius — the blend band has reached ground the player stands on" %
			(inner_worst * 1000.0))
	# The rim. 150 mm against a measured 111: margin for a re-tune of the
	# neighbouring region, and still under the height of a single stair.
	if worst > 0.150:
		_fail("the shrine clearing rim moved %.0f mm at (%.1f, %.1f) — the transition to open ground has become a step" %
			[worst * 1000.0, worst_at.x, worst_at.y])
	print("shrine clearing: core %.6f mm, inner-0.85 %.4f mm, rim worst %.1f mm at (%.1f, %.1f), %d points" %
		[core_worst * 1000.0, inner_worst * 1000.0, worst * 1000.0, worst_at.x, worst_at.y, checked])


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


## 5. The open ground stays floor rather than becoming wall — per region, and
## then everywhere.
##
## The per-region bars are the real law. A single world-wide maximum is held by
## whichever region is steepest and is therefore blind to every other one, so a
## region can take on a whole degree of extra steepness — enough to change what
## that ground IS to walk across — without moving the number at all.
func _test_terrain_stays_walkable() -> void:
	var declared := {}
	for reg: Dictionary in GroundRegions.REGIONS:
		var region_name: StringName = reg[&"name"]
		declared[region_name] = true
		if not MAX_REGION_GRADE_DEG.has(region_name):
			_fail("region %s has no grade ratchet — a new region must be measured, not left unguarded" %
				region_name)
			continue
		var measured := float(_region_worst.get(region_name, 0.0))
		if measured <= 0.0:
			_fail("region %s reported no grade at all — the sweep never attributed a sample to it" %
				region_name)
			continue
		var bar := float(MAX_REGION_GRADE_DEG[region_name])
		if measured > bar:
			_fail("region %s reaches %.2f deg inside its own ground, over its %.1f deg ratchet (character floor limit %.1f) — its landform is too steep for what it sits on" %
				[region_name, measured, bar, FLOOR_MAX_ANGLE_DEG])

	# The other face of the same coverage defect. This loop reads the region
	# list, so a ratchet left behind for a region that no longer exists is never
	# consulted — it cannot fail, and it cannot drag a measurement the way a
	# stale RELIEF_FLOOR key drags the spread in arm 6. What it does is read as
	# coverage: a bar sitting in the table implies some ground is being held to
	# it. Rejecting it is what makes arm 6's claim that these two checks mirror
	# each other true, rather than half true.
	for region_name: StringName in MAX_REGION_GRADE_DEG:
		if not declared.has(region_name):
			_fail("MAX_REGION_GRADE_DEG carries %s, which is not a declared region — a ratchet for ground that does not exist guards nothing while reading as coverage" %
				region_name)

	if _worst_grade > MAX_GRADE_DEG:
		_fail("worst open grade %.2f deg exceeds %.1f deg (character floor limit %.1f) — the world has ground the wanderer cannot walk up, and it is not inside any one region" %
			[_worst_grade, MAX_GRADE_DEG, FLOOR_MAX_ANGLE_DEG])


## 6. The regions are actually different heights.
##
## 🔴 Coverage is checked BOTH ways before anything is measured, because every
## arm here iterates `RELIEF_FLOOR` rather than the region list. A region added
## to `GroundRegions.REGIONS` and forgotten here would be silently absent from
## the floor check, from the spread, and from the tallest-region comparison —
## exempt from the very law this arm exists to enforce, with the suite green. A
## key left behind for a region that no longer exists is the same defect wearing
## the other face: it contributes a phantom 0.0 m to the spread. This mirrors
## the grade-ratchet coverage check in arm 5; the two must not drift apart.
func _test_regions_differ_in_relief(relief: Dictionary) -> void:
	var declared := {}
	for reg: Dictionary in GroundRegions.REGIONS:
		var region_name: StringName = reg[&"name"]
		declared[region_name] = true
		if not RELIEF_FLOOR.has(region_name):
			_fail("region %s has no relief floor — a new region must be measured, not left unguarded" %
				region_name)
	for region_name: StringName in RELIEF_FLOOR:
		if not declared.has(region_name):
			_fail("RELIEF_FLOOR carries %s, which is not a declared region — a stale key measures nothing and drags the spread" %
				region_name)

	for region_name: StringName in RELIEF_FLOOR:
		var measured := float(relief.get(region_name, 0.0))
		var relief_floor := float(RELIEF_FLOOR[region_name])
		if measured < relief_floor:
			_fail("region %s relief %.3f m is under its floor %.3f m — its landform has been flattened" %
				[region_name, measured, relief_floor])

	var tallest := -INF
	var flattest := INF
	for region_name: StringName in RELIEF_FLOOR:
		var measured := float(relief.get(region_name, 0.0))
		tallest = maxf(tallest, measured)
		flattest = minf(flattest, measured)
	if tallest - flattest < RELIEF_SPREAD:
		_fail("region relief spans only %.3f m (%.3f to %.3f), under the %.2f m spread — the regions are one landform in four paints" %
			[tallest - flattest, flattest, tallest, RELIEF_SPREAD])

	# The high ground is somewhere the player has to GO. Without this, every
	# other arm here passes on a world whose tallest region is the one the
	# shrine stands in — which is the world where exploring costs relief
	# instead of gaining it.
	var champion := float(relief.get(TALLEST_REGION, 0.0))
	var runner_up := -INF
	var runner_up_name := &"(none)"
	for region_name: StringName in RELIEF_FLOOR:
		if region_name == TALLEST_REGION:
			continue
		var measured := float(relief.get(region_name, 0.0))
		if measured > runner_up:
			runner_up = measured
			runner_up_name = region_name
	if champion - runner_up < TALLEST_MARGIN:
		_fail("%s stands %.3f m against %s's %.3f m — the Reach's high ground is no longer the region the player has to travel to" %
			[TALLEST_REGION, champion, runner_up_name, runner_up])


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
		var region_name: StringName = reg[&"name"]
		var amp := float(reg[&"amp"])
		var ridged := float(reg[&"ridged"])
		var ratio := _crease_ratio(amp, ridged)
		if ridged == 0.0:
			if not is_equal_approx(ratio, 1.0):
				_fail("region %s asks for no ridging but its crease ratio is %.4f, not 1 — shape() is creasing a region that did not ask" %
					[region_name, ratio])
			continue
		if region_name != CREASED_REGION:
			continue
		found = true
		if ratio < CREASE_RATIO_FLOOR:
			_fail("region %s ridges at %.2f but creases the field only %.3fx (floor %.2fx) — the crease knob is not producing an edge" %
				[region_name, ridged, ratio, CREASE_RATIO_FLOOR])
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


## in one decided region.
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


## The steepest COLLISION FACE over the open terrain, in degrees, with the
## massif's deliberate skirt excluded. Fills `_region_worst` from the same pass.
##
## 🔴 Both halves of this are load-bearing, and the cheaper version of each is
## wrong in a way that stays green.
##
## **The angle is a face normal, not a cardinal rise.** A wanderer is classified
## against the normal of the triangle under them, and that is not recoverable
## from one axis: ground rising along BOTH axes at 40 degrees is a ~50 degree
## face, so a per-axis test can report every component under the bar while the
## surface the player meets is a wall. Measured on this field, `max(|dx|, |dz|)`
## reads 42.54 degrees where the true gradient is 50.72 — 8.18 degrees of
## understatement, straddling the very limit being guarded.
##
## **The surface is the baked mesh, not `height_at`.** Physics stands on the
## piecewise-linear grid, so that is what must be under the limit; nothing walks
## on the smooth field. Read through the shipped `surface_normal_at` at each
## face's own centroid — one call per triangle, exactly the faces
## `_build_terrain` emits, rather than a re-derivation that could drift from the
## real split convention.
##
## **Attribution needs all THREE vertices decided and agreeing.** Testing only
## the centroid would charge a face straddling a boundary to whichever region
## owns its middle, so retuning a NEIGHBOUR could trip this region's supposedly
## independent ratchet. Faces spanning a blend band therefore belong to no
## region; `MAX_GRADE_DEG` covers them, and that is most of what it is still for.
func _sweep_face_grades() -> float:
	var sites := GroundRegions.sites(WorldGen.WORLD_SEED, EXTENT)
	var step := WorldGen.SIZE / WorldGen.QUADS
	var half := WorldGen.SIZE / 2.0
	var worst := 0.0
	for reg: Dictionary in GroundRegions.REGIONS:
		_region_worst[reg[&"name"]] = 0.0
	for iz in WorldGen.QUADS:
		for ix in WorldGen.QUADS:
			var x0 := ix * step - half
			var z0 := iz * step - half
			var x1 := x0 + step
			var z1 := z0 + step
			# The same two triangles `_build_terrain` splits each quad into.
			for tri: Array in [
				[Vector2(x0, z0), Vector2(x1, z1), Vector2(x1, z0)],
				[Vector2(x0, z0), Vector2(x0, z1), Vector2(x1, z1)],
			]:
				var a: Vector2 = tri[0]
				var b: Vector2 = tri[1]
				var c: Vector2 = tri[2]
				var centre := (a + b + c) / 3.0
				if (centre - WorldGen.CAVE_SITE).length() <= CAVE_KEEPOUT:
					continue
				var n := _world.surface_normal_at(centre.x, centre.y)
				var deg := rad_to_deg(acos(clampf(absf(n.y), -1.0, 1.0)))
				worst = maxf(worst, deg)
				var owner := _face_region(sites, a, b, c)
				if owner == &"":
					continue
				_region_worst[owner] = maxf(float(_region_worst[owner]), deg)
	return worst


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
			var region_name: StringName = GroundRegions.REGIONS[at[&"region"]][&"name"]
			var h := _world.height_at(x, z)
			sums[region_name] = float(sums[region_name]) + h
			squares[region_name] = float(squares[region_name]) + h * h
			totals[region_name] = int(totals[region_name]) + 1

	var relief := {}
	for reg: Dictionary in GroundRegions.REGIONS:
		var region_name: StringName = reg[&"name"]
		var n := int(totals[region_name])
		if n < 1000:
			_fail("region %s has only %d decided interior samples — too few to measure relief" %
				[region_name, n])
			relief[region_name] = 0.0
			continue
		var mean := float(sums[region_name]) / n
		var variance := maxf(float(squares[region_name]) / n - mean * mean, 0.0)
		relief[region_name] = sqrt(variance)
	return relief
