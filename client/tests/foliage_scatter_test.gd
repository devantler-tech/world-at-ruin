extends Node
## Regression test for FoliageGen (issue #81) — the deterministic, keep-out-aware
## cosmetic ground-cover scatter for the Ashfall Reach.
##
## Pins the three product laws foliage_gen.gd states only in comments:
##  1. DETERMINISM — "the same scatter every boot". A fingerprint of the whole
##     scatter (count + every prop's kind/pos/yaw/scale) is asserted two ways:
##       (a) equal between two scatters whose process-global RNG was seeded to
##           DIFFERENT values — proving the scatter ignores the global RNG and
##           uses only its own seeded generator (the realistic process-scoped
##           source of accidental non-determinism);
##       (b) equal to a COMMITTED golden — like WorldGen's #58 golden and the
##           server sim's demoGoldenHash, a change here is a reviewed act. The
##           fingerprint is millimetre / 1e-4-rad quantised so it is stable
##           across boots AND runners (the golden scenario uses keep-out-only
##           rejection over randf_range candidates and a LINEAR height sampler —
##           no cross-prop float-compare branch, no transcendental — exactly the
##           path #58 proved reproduces bit-for-bit on the Linux CI runner).
##  2. KEEP-OUTS — every prop lands strictly outside every supplied circle and
##     within the inset bounds; a circle covering the whole region yields zero
##     props (the keep-out has teeth); and min_sep, when set, is respected
##     pairwise (a structural test, tolerant of float noise, not a golden).
##  3. HORIZONTAL-ONLY — a real scatter passes find_forbidden with nothing
##     flagged, while a placement carrying a `power` field, an out-of-set kind,
##     or a non-Dictionary is flagged (the guard has teeth). Foliage is scenery
##     and grants nothing — "breadth, never bigger numbers" is mechanical.
## Plus degenerate inputs (empty region, malformed keep-outs, missing sampler)
## are handled without a crash.
##
## Pure and headless: FoliageGen touches no scene and no `user://`, so this test
## never risks the player's save.
##
## Run: godot --headless --path client res://tests/foliage_scatter_test.tscn

## The same scatter every boot — a golden over the whole golden-scenario result.
## Captured from a headless build; regenerate deliberately (the test prints it in
## record mode, GOLDEN == "__RECORD__") only when the scatter is intentionally
## changed — like WorldGen's determinism golden, a change here is a reviewed act.
const GOLDEN := "861bdfef"

## Half the world edge (matches WorldGen.SIZE / 2) and the shrine/cave keep-outs
## the real world would supply, so the golden scenario resembles a real scatter.
const HALF_EXTENT := 110.0
const MARGIN := 12.0
const GOLDEN_SEED := 20260717
const GOLDEN_COUNT := 120


func _ready() -> void:
	# 1a. DETERMINISM — two scatters agree despite DIFFERENT process-global RNG
	# state, proving independence from the global generator.
	seed(0x5f3759df)
	var a := FoliageGen.scatter(_golden_params())
	seed(0x1eb54a3d)
	var b := FoliageGen.scatter(_golden_params())
	var fa := _fingerprint(a)
	var fb := _fingerprint(b)
	if fa != fb:
		_fail("two scatters disagree — determinism broken (%s vs %s)" % [fa, fb])
		return

	# 1b. DETERMINISM — the whole scatter matches the committed golden (cross-boot).
	if GOLDEN == "__RECORD__":
		print("RECORD foliage golden: %s (n=%d)" % [fa, a.size()])
	elif fa != GOLDEN:
		_fail("foliage fingerprint %s != golden %s — the scatter changed (intended? update the golden) or a boot-varying source crept in" % [fa, GOLDEN])
		return

	# The golden scenario must actually place props, or the golden is vacuous.
	if a.size() < GOLDEN_COUNT / 2:
		_fail("golden scenario placed only %d/%d props — too sparse to be a meaningful golden" % [a.size(), GOLDEN_COUNT])
		return

	# 2. KEEP-OUTS and bounds — every prop is strictly outside every circle and
	# within the inset region.
	var lo := -HALF_EXTENT + MARGIN
	var hi := HALF_EXTENT - MARGIN
	var keep_outs := _golden_keep_outs()
	for p: Dictionary in a:
		var pos: Vector3 = p["pos"]
		if pos.x < lo or pos.x > hi or pos.z < lo or pos.z > hi:
			_fail("prop at (%.2f, %.2f) is outside the inset bounds [%.1f, %.1f]" % [pos.x, pos.z, lo, hi])
			return
		var here := Vector2(pos.x, pos.z)
		for c: Array in keep_outs:
			var centre: Vector2 = c[0]
			var r: float = c[1]
			if here.distance_to(centre) < r:
				_fail("prop at (%.2f, %.2f) intrudes on keep-out (centre %.1f,%.1f r=%.1f)" % [pos.x, pos.z, centre.x, centre.y, r])
				return

	# 2b. KEEP-OUT teeth — a circle covering the whole region yields zero props.
	var smothered := FoliageGen.scatter({
		"seed": GOLDEN_SEED, "count": GOLDEN_COUNT, "half_extent": HALF_EXTENT,
		"margin": MARGIN, "keep_outs": [[Vector2.ZERO, HALF_EXTENT * 4.0]],
	})
	if not smothered.is_empty():
		_fail("a region-covering keep-out still placed %d props — the keep-out is toothless" % smothered.size())
		return

	# 2c. MIN-SEP — with spacing on, every pair is at least min_sep apart
	# (structural, float-tolerant; not part of the golden).
	var sep := 6.0
	var spaced := FoliageGen.scatter({
		"seed": 99, "count": 200, "half_extent": HALF_EXTENT, "margin": MARGIN,
		"min_sep": sep,
	})
	for i in spaced.size():
		var pi: Vector3 = spaced[i]["pos"]
		for j in range(i + 1, spaced.size()):
			var pj: Vector3 = spaced[j]["pos"]
			var d := Vector2(pi.x, pi.z).distance_to(Vector2(pj.x, pj.z))
			if d < sep - 0.001:
				_fail("two spaced props are %.3f m apart, under min_sep %.1f" % [d, sep])
				return

	# 3a. HORIZONTAL-ONLY — a real scatter is provably cosmetic-only.
	var forbidden := FoliageGen.find_forbidden(a)
	if not forbidden.is_empty():
		_fail("a real scatter tripped the horizontal-only audit (%d flagged) — a prop is not schema-clean" % forbidden.size())
		return

	# 3b. HORIZONTAL-ONLY teeth — a power field, an out-of-set kind, and a
	# non-Dictionary are each flagged; a clean prop is not.
	var clean := {"kind": FoliageGen.Kind.RUBBLE, "pos": Vector3.ZERO, "yaw": 0.0, "scale": 1.0}
	var powered := {"kind": FoliageGen.Kind.ASH_SHRUB, "pos": Vector3.ZERO, "yaw": 0.0, "scale": 1.0, "power": 5}
	var bad_kind := {"kind": 99, "pos": Vector3.ZERO, "yaw": 0.0, "scale": 1.0}
	var flagged := FoliageGen.find_forbidden([clean, powered, bad_kind, "not-a-dict"])
	if flagged.size() != 3:
		_fail("find_forbidden should flag exactly the power/bad-kind/non-dict entries, flagged %d" % flagged.size())
		return
	if not FoliageGen.find_forbidden([clean]).is_empty():
		_fail("find_forbidden wrongly flagged a clean cosmetic prop")
		return

	# 4. COUNT / TERMINATION — an empty, keep-out-free region places exactly count;
	# a scatter never exceeds count.
	var full := FoliageGen.scatter({"seed": 7, "count": 64, "half_extent": 100.0})
	if full.size() != 64:
		_fail("an open region should place all 64 props, placed %d" % full.size())
		return

	# 5. DEGENERATE — no props, no crash.
	if not FoliageGen.scatter({"seed": 1, "count": 0, "half_extent": 100.0}).is_empty():
		_fail("count 0 should place nothing")
		return
	if not FoliageGen.scatter({"seed": 1, "count": 10, "half_extent": 0.0}).is_empty():
		_fail("half_extent 0 should place nothing")
		return
	# Malformed keep-outs are skipped (not a crash) while good ones still apply.
	var messy := FoliageGen.scatter({
		"seed": 3, "count": 30, "half_extent": 80.0,
		"keep_outs": ["garbage", [Vector2.ZERO], [Vector2(10, 10), 15.0]],
	})
	for p: Dictionary in messy:
		var pos: Vector3 = p["pos"]
		if Vector2(pos.x, pos.z).distance_to(Vector2(10, 10)) < 15.0:
			_fail("a valid keep-out was dropped when a malformed sibling was present")
			return
	# Missing sampler → ground height defaults to 0.
	for p: Dictionary in full:
		if (p["pos"] as Vector3).y != 0.0:
			_fail("without a height sampler, prop y should be 0")
			return

	print("TEST PASS — foliage deterministic (%s, global-RNG-invariant, golden-matched), %d props clear of %d keep-outs + bounds, min_sep + horizontal-only + degenerate guards hold" % [fa, a.size(), keep_outs.size()])
	get_tree().quit(0)


## The committed golden scenario: a realistic scatter with the shrine + cave
## keep-outs the world would supply and a LINEAR (transcendental-free) ground
## sampler, min_sep off — the cross-platform-stable path #58 proved.
func _golden_params() -> Dictionary:
	return {
		"seed": GOLDEN_SEED,
		"count": GOLDEN_COUNT,
		"half_extent": HALF_EXTENT,
		"margin": MARGIN,
		"keep_outs": _golden_keep_outs(),
		"height_sampler": Callable(self, "_linear_surface"),
	}


## Shrine clearing at the origin and the starter-cave footprint, mirroring the
## real world's landmarks (WorldGen.CAVE_SITE ≈ (-56, -20)).
func _golden_keep_outs() -> Array:
	return [[Vector2.ZERO, 20.0], [Vector2(-56.0, -20.0), 18.0]]


## A deterministic, non-transcendental stand-in for terrain height: pure
## multiply/add over the (cross-platform-identical) candidate coordinates, so
## the golden's y column is stable on every runner.
func _linear_surface(x: float, z: float) -> float:
	return 0.25 * x - 0.15 * z + 1.0


## A fingerprint of the whole scatter: count, then every prop's kind and
## millimetre / 1e-4-rad quantised pose. Robust to platform float noise, red on
## any real drift (a moved prop, a changed kind/rotation/scale, a lost prop).
func _fingerprint(placements: Array[Dictionary]) -> String:
	var acc := PackedInt32Array()
	acc.append(placements.size())
	for p: Dictionary in placements:
		acc.append(int(p["kind"]))
		var pos: Vector3 = p["pos"]
		acc.append(roundi(pos.x * 1000.0))
		acc.append(roundi(pos.y * 1000.0))
		acc.append(roundi(pos.z * 1000.0))
		acc.append(roundi(float(p["yaw"]) * 10000.0))
		acc.append(roundi(float(p["scale"]) * 1000.0))
	return "%x" % hash(acc)


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
