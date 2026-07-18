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

	# 6. NO GROUND (issue #97) — a sampler reporting "there is no surface here"
	# must REJECT the candidate, never place it at the sentinel depth. This is
	# the contract WorldGen.surface_height_at actually has (it returns
	# NO_GROUND = -1e6 off the terrain grid), so without this the obvious
	# wiring would bury props a thousand kilometres down.
	var holed_params := {
		"seed": 4242, "count": 120, "half_extent": 100.0,
		"height_sampler": Callable(self, "_holed_surface"),
	}
	var holed := FoliageGen.scatter(holed_params)
	for p: Dictionary in holed:
		var pos: Vector3 = p["pos"]
		if pos.x < 0.0:
			_fail("a prop landed at (%.2f, %.2f) where the sampler reports NO_GROUND" % [pos.x, pos.z])
			return
		if pos.y != 2.0:
			_fail("a prop on solid ground has y %.3f, expected the sampler's 2.0" % pos.y)
			return
	# Teeth: the SAME scatter over solid ground DOES populate the hole's half,
	# so the emptiness above is the rejection at work and not a vacuous pass.
	var solid_params := holed_params.duplicate()
	solid_params["height_sampler"] = Callable(self, "_solid_surface")
	var solid := FoliageGen.scatter(solid_params)
	var solid_left := 0
	for p: Dictionary in solid:
		if (p["pos"] as Vector3).x < 0.0:
			solid_left += 1
	if solid_left == 0:
		_fail("no-ground check is vacuous: over solid ground nothing landed in the tested half either")
		return
	if holed.is_empty():
		_fail("no-ground check is vacuous: the holed scatter placed nothing at all")
		return

	# 6b. A non-finite height is never a coordinate — a NaN or INF sampler
	# places nothing rather than poisoning a prop's position (and the golden).
	for sampler_name: String in ["_nan_surface", "_inf_surface"]:
		var poisoned := FoliageGen.scatter({
			"seed": 11, "count": 40, "half_extent": 100.0,
			"height_sampler": Callable(self, sampler_name),
		})
		if not poisoned.is_empty():
			_fail("a %s sampler placed %d props — a non-finite height must reject, not propagate" % [sampler_name, poisoned.size()])
			return

	# 6c. The sentinel is caller-overridable, so a caller whose "no ground" value
	# differs from WorldGen's is served too.
	var raised := FoliageGen.scatter({
		"seed": 11, "count": 40, "half_extent": 100.0, "no_ground": 5.0,
		"height_sampler": Callable(self, "_solid_surface"),
	})
	if not raised.is_empty():
		_fail("with no_ground raised above the sampled height, every candidate should be rejected (placed %d)" % raised.size())
		return

	# 7. THE SPATIAL HASH IS AN EXACT ACCELERATION (issue #109). The committed
	# golden above only covers GOLDEN_COUNT props; the acceleration exists for
	# the dense scatters the world actually builds, so prove equivalence THERE —
	# against a reference full scan, at densities where the grid and the scan
	# could plausibly disagree.
	if not _grid_matches_full_scan():
		return
	if not _no_overlapping_pair():
		return
	_report_scatter_cost()

	print("TEST PASS — foliage deterministic (%s, global-RNG-invariant, golden-matched), %d props clear of %d keep-outs + bounds, min_sep + horizontal-only + no-ground + degenerate guards hold; spatial hash matches a full scan bit-for-bit and admits no overlapping pair" % [fa, a.size(), keep_outs.size()])
	get_tree().quit(0)


## The spatial-hash separation test must produce EXACTLY what the O(n²) scan it
## replaced produced — same accepts, same rejects, same order — so this replays
## the scatter with a reference full-scan predicate and compares fingerprints.
## Run at several densities including ones far past the committed golden, because
## a neighbourhood bug only shows up once props are dense enough to sit in
## adjacent cells.
func _grid_matches_full_scan() -> bool:
	for spec: Array in [[400, 2.0], [1200, 1.4], [2400, 1.1]]:
		var n: int = spec[0]
		var sep: float = spec[1]
		var params := {
			"seed": 20260718, "count": n, "half_extent": 110.0, "margin": 6.0,
			"min_sep": sep, "keep_outs": _golden_keep_outs(), "height_sampler": _linear_surface,
		}
		var fast := FoliageGen.scatter(params)
		var reference := _scatter_full_scan(params)
		if _fingerprint(fast) != _fingerprint(reference):
			_fail(("spatial hash diverged from the full scan at %d props / min_sep %.1f: %s vs %s — " +
				"the acceleration must be exact, not approximate")
				% [n, sep, _fingerprint(fast), _fingerprint(reference)])
			return false
		if fast.size() != reference.size():
			_fail("spatial hash placed %d props, full scan placed %d" % [fast.size(), reference.size()])
			return false
	return true


## A reference scatter using an O(n²) separation scan — the implementation the
## spatial hash replaced. Mirrors FoliageGen.scatter's RNG order exactly (draw
## x, z, reject before consuming any style RNG), so any difference in output is
## attributable to the separation test alone. Kept here rather than in the
## library so the shipped code carries no dead full-scan path.
func _scatter_full_scan(params: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var count := int(params["count"])
	var half_extent := float(params["half_extent"])
	var margin := float(params.get("margin", 0.0))
	var min_sep := float(params.get("min_sep", 0.0))
	var min_sep_sq := min_sep * min_sep
	var lo := -half_extent + margin
	var hi := half_extent - margin
	var keep_outs: Array = params.get("keep_outs", [])
	var sampler: Callable = params.get("height_sampler", Callable())
	var no_ground := float(params.get("no_ground", FoliageGen.NO_GROUND))
	var rng := RandomNumberGenerator.new()
	rng.seed = int(params.get("seed", 0))
	var attempts := 0
	var max_attempts := int(params.get("max_attempts", count * 32))
	# The loop below mirrors FoliageGen.scatter step for step — including the
	# ground sample sitting BEFORE the style draws (#97) — so the ONLY difference
	# is the separation test. Any divergence is then attributable to the grid and
	# to nothing else.
	while out.size() < count and attempts < max_attempts:
		attempts += 1
		var x := rng.randf_range(lo, hi)
		var z := rng.randf_range(lo, hi)
		if _inside_keep_outs(x, z, keep_outs):
			continue
		if min_sep_sq > 0.0 and _full_scan_too_close(x, z, out, min_sep_sq):
			continue
		var y := 0.0
		if sampler.is_valid():
			y = float(sampler.call(x, z))
			if not is_finite(y) or y <= no_ground:
				continue
		var kind := FoliageGen._pick_kind(rng, [])
		var yaw := rng.randf_range(0.0, TAU)
		var scale := rng.randf_range(FoliageGen.SCALE_MIN, FoliageGen.SCALE_MAX)
		out.append({"kind": kind, "pos": Vector3(x, y, z), "yaw": yaw, "scale": scale})
	return out


## The full scan the grid replaced: compare against EVERY placed prop.
func _full_scan_too_close(x: float, z: float, placed: Array[Dictionary], min_sep_sq: float) -> bool:
	var here := Vector2(x, z)
	for p: Dictionary in placed:
		var pos: Vector3 = p["pos"]
		if here.distance_squared_to(Vector2(pos.x, pos.z)) < min_sep_sq:
			return true
	return false


## Keep-out membership, matching the library's `[centre, radius]` entry shape.
func _inside_keep_outs(x: float, z: float, keep_outs: Array) -> bool:
	var here := Vector2(x, z)
	for c: Array in keep_outs:
		var centre: Vector2 = c[0]
		var r: float = c[1]
		if r > 0.0 and here.distance_squared_to(centre) < r * r:
			return true
	return false


## The invariant the acceleration must never break: no two placed props are
## closer than the requested spacing. A broad phase that pruned a genuinely
## too-close pair would still look plausible in a fingerprint diff, so assert the
## geometric property directly, at a density where cells are crowded.
func _no_overlapping_pair() -> bool:
	var sep := 1.1
	var props := FoliageGen.scatter({
		"seed": 4242, "count": 2400, "half_extent": 110.0, "margin": 6.0, "min_sep": sep,
	})
	var sep_sq := sep * sep
	for i in props.size():
		var a: Vector3 = props[i]["pos"]
		var pa := Vector2(a.x, a.z)
		for j in range(i + 1, props.size()):
			var b: Vector3 = props[j]["pos"]
			if pa.distance_squared_to(Vector2(b.x, b.z)) < sep_sq:
				_fail("spatial hash admitted an overlapping pair: (%.3f, %.3f) and (%.3f, %.3f) are %.3f m apart, under min_sep %.1f"
					% [a.x, a.z, b.x, b.z, pa.distance_to(Vector2(b.x, b.z)), sep])
				return false
	return true


## Record scatter cost across densities (#109's before/after evidence). Timings
## are PRINTED, never asserted: wall-clock on a shared CI runner is far too noisy
## to gate a build on, and a flaky perf assertion would be worse than none. The
## correctness of the acceleration is pinned by the oracle and overlap checks
## above; this is the number a human reads.
func _report_scatter_cost() -> void:
	var line := ""
	for spec: Array in [[900, 1.6], [2400, 1.1], [4000, 0.9], [6000, 0.8]]:
		var n: int = spec[0]
		var sep: float = spec[1]
		var t0 := Time.get_ticks_msec()
		var got := FoliageGen.scatter({
			"seed": 7, "count": n, "half_extent": 110.0, "margin": 6.0, "min_sep": sep,
		})
		line += "%d props/%.1fm: %d ms (placed %d)  " % [n, sep, Time.get_ticks_msec() - t0, got.size()]
	print("SCATTER COST — %s" % line)


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


## A surface with a HOLE over the -X half: solid ground at y = 2 on the +X side,
## and WorldGen's "no ground here" sentinel on the other — what
## surface_height_at actually returns off the terrain grid.
func _holed_surface(x: float, _z: float) -> float:
	return FoliageGen.NO_GROUND if x < 0.0 else 2.0


## The same surface with the hole filled in — the control that proves the
## holed scatter's empty half is the rejection working, not an accident.
func _solid_surface(_x: float, _z: float) -> float:
	return 2.0


## Degenerate samplers: a height that is not a number at all.
func _nan_surface(_x: float, _z: float) -> float:
	return NAN


func _inf_surface(_x: float, _z: float) -> float:
	return INF


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
