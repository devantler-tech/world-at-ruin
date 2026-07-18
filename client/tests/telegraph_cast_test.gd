extends Node
## Laws of the deterministic telegraph cast core (issue #175).
##
## Pins the three properties the combat children will lean on:
##  1. ILLEGAL CASTS ARE UNREPRESENTABLE — every invalid input to the
##     factories is refused (null), so a no-op telegraph can never reach play.
##     Each refusal is exercised individually; the expected `push_error` lines
##     in the log are the refusals being loud, not failures.
##  2. THE CLOCK IS EXACT — `advance` crosses resolution exactly once, on the
##     call that reaches `cast_time`; negative/non-finite dt changes nothing.
##  3. GEOMETRY IS THE SHARED LIB'S — `contains` agrees with `Telegraph`
##     point-for-point over a sweep with witnesses on both sides, so a future
##     divergence (a re-derived wedge, a cached radius) fails here.
##
## Pure data — no scene load, no save, no wall clock — safe headless anywhere.
##
## Run: godot --headless --path client res://tests/telegraph_cast_test.tscn

var _failed := false


func _ready() -> void:
	_factory_refusals()
	_factory_accepts()
	_clock_laws()
	_geometry_oracle()
	_hit_points()
	if not _failed:
		print("TEST PASS — telegraph cast core laws hold")
		get_tree().quit(0)


func _factory_refusals() -> void:
	print("telegraph_cast_test: the ERROR lines below are expected — they are the factories refusing loudly.")
	var bad: Array = [
		TelegraphCast.circle(Vector3.ZERO, 0.0, 1.0),
		TelegraphCast.circle(Vector3.ZERO, -3.0, 1.0),
		TelegraphCast.circle(Vector3.ZERO, 5.0, 0.0),
		TelegraphCast.circle(Vector3.ZERO, 5.0, -1.0),
		TelegraphCast.circle(Vector3.ZERO, NAN, 1.0),
		TelegraphCast.circle(Vector3(INF, 0, 0), 5.0, 1.0),
		TelegraphCast.cone(Vector3.ZERO, Vector3(0, 0, -1), 0.0, 500_000, 1.0),
		TelegraphCast.cone(Vector3.ZERO, Vector3(0, 0, -1), -2.0, 500_000, 1.0),
		TelegraphCast.cone(Vector3.ZERO, Vector3(0, 0, -1), 8.0, Telegraph.COS_SCALE + 1, 1.0),
		TelegraphCast.cone(Vector3.ZERO, Vector3(0, 0, -1), 8.0, -Telegraph.COS_SCALE - 1, 1.0),
		TelegraphCast.cone(Vector3.ZERO, Vector3(0, 5, 0), 8.0, 500_000, 1.0),
		TelegraphCast.cone(Vector3.ZERO, Vector3.ZERO, 8.0, 500_000, 1.0),
		TelegraphCast.cone(Vector3.ZERO, Vector3(0, 0, -1), 8.0, 500_000, 0.0),
		TelegraphCast.cone(Vector3.ZERO, Vector3(0, 0, NAN), 8.0, 500_000, 1.0),
	]
	for i in bad.size():
		if bad[i] != null:
			_fail("factory refusal case %d produced a cast instead of null" % i)
			return


func _factory_accepts() -> void:
	var c := TelegraphCast.circle(Vector3(3, 1, -2), 5.0, 2.0)
	if c == null:
		_fail("a valid circle cast was refused")
		return
	if c.shape != TelegraphCast.Shape.CIRCLE or c.radius != 5.0 or c.cast_time != 2.0:
		_fail("circle factory did not carry its inputs")
		return
	if c.is_resolved or c.progress() != 0.0:
		_fail("a fresh cast must start unresolved at progress 0")
		return
	# Boundary thresholds are legal: ±COS_SCALE are the degenerate-but-valid
	# extremes (a ray, a full disc) the geometry lib defines behaviour for.
	if TelegraphCast.cone(Vector3.ZERO, Vector3(1, 0, 0), 8.0, Telegraph.COS_SCALE, 1.0) == null:
		_fail("cos_half_scaled == +COS_SCALE must be accepted")
		return
	if TelegraphCast.cone(Vector3.ZERO, Vector3(1, 0, 0), 8.0, -Telegraph.COS_SCALE, 1.0) == null:
		_fail("cos_half_scaled == -COS_SCALE must be accepted")
		return
	# Over-cap extents CLAMP to the authoritative limit (the server's
	# maxTelegraphExtentMM clamps, never refuses — refusing here would leave
	# an authority-resolved cast unpainted, the catastrophic direction).
	var capped_circle := TelegraphCast.circle(Vector3.ZERO, 5000.0, 1.0)
	if capped_circle == null:
		_fail("an over-cap radius must clamp, not be refused")
		return
	if capped_circle.radius != TelegraphCast.MAX_EXTENT_M:
		_fail("over-cap radius clamped to %f, expected %f" % [capped_circle.radius, TelegraphCast.MAX_EXTENT_M])
		return
	var capped_cone := TelegraphCast.cone(Vector3.ZERO, Vector3(1, 0, 0), 9000.0, 500_000, 1.0)
	if capped_cone == null:
		_fail("an over-cap range must clamp, not be refused")
		return
	if capped_cone.range_m != TelegraphCast.MAX_EXTENT_M:
		_fail("over-cap range clamped to %f, expected %f" % [capped_cone.range_m, TelegraphCast.MAX_EXTENT_M])
		return
	if TelegraphCast.circle(Vector3.ZERO, TelegraphCast.MAX_EXTENT_M, 1.0) == null:
		_fail("the exact cap value must be accepted unchanged")
		return


func _clock_laws() -> void:
	var c := TelegraphCast.circle(Vector3.ZERO, 4.0, 2.0)
	print("telegraph_cast_test: the next ERROR lines are the expected bad-dt refusals.")
	if c.advance(-0.5):
		_fail("negative dt must not resolve")
		return
	if c.advance(NAN):
		_fail("NaN dt must not resolve")
		return
	if c.elapsed != 0.0:
		_fail("a refused dt must leave the clock untouched (elapsed %f)" % c.elapsed)
		return
	if c.advance(0.0):
		_fail("a zero dt on a fresh cast must not resolve")
		return
	if c.advance(1.0):
		_fail("resolved at 1.0s of a 2.0s cast")
		return
	if absf(c.progress() - 0.5) > 0.000001:
		_fail("progress at 1.0/2.0 should be 0.5 (got %f)" % c.progress())
		return
	if not c.advance(1.0):
		_fail("the call that reaches cast_time must report the crossing")
		return
	if not c.is_resolved:
		_fail("crossing must set is_resolved")
		return
	if c.advance(1.0):
		_fail("a resolved cast must never report a second crossing")
		return
	if c.progress() != 1.0:
		_fail("progress past resolution must clamp to 1.0")
		return

	# One oversized step resolves exactly once, not once per exceeded second.
	var big := TelegraphCast.circle(Vector3.ZERO, 4.0, 0.5)
	if not big.advance(100.0):
		_fail("a single huge dt must cross resolution")
		return
	if big.advance(100.0):
		_fail("a second huge dt must not cross again")
		return


## `contains` must agree with the shared geometry lib point-for-point — with
## real witnesses on BOTH sides so the sweep cannot pass vacuously — and must
## ignore height like the lib does (a telegraph is a mark on the ground).
func _geometry_oracle() -> void:
	var circle := TelegraphCast.circle(Vector3(3, 0, -2), 5.0, 1.0)
	var thr := Telegraph.cos_half_scaled_from_deg(55.0)
	var cone := TelegraphCast.cone(Vector3(1, 0, 1), Vector3(1, 0, -0.4), 8.0, thr, 1.0)
	var in_count := 0
	var out_count := 0
	for xi in range(-10, 11):
		for zi in range(-10, 11):
			for y in [-3.0, 0.0, 7.0]:
				var p := Vector3(float(xi), y, float(zi))
				var want_circle := Telegraph.in_circle(circle.origin_point, circle.radius, p)
				if circle.contains(p) != want_circle:
					_fail("circle.contains diverged from Telegraph.in_circle at %s" % p)
					return
				var want_cone := Telegraph.in_cone_scaled(cone.origin_point, cone.facing,
						cone.range_m, cone.cos_half_scaled, p)
				if cone.contains(p) != want_cone:
					_fail("cone.contains diverged from Telegraph.in_cone_scaled at %s" % p)
					return
				if want_circle or want_cone:
					in_count += 1
				else:
					out_count += 1
	if in_count == 0 or out_count == 0:
		_fail("oracle sweep was vacuous (inside=%d outside=%d) — the grid must witness both sides" % [in_count, out_count])
		return


func _hit_points() -> void:
	var c := TelegraphCast.circle(Vector3.ZERO, 2.0, 1.0)
	var pts := PackedVector3Array([
		Vector3(0, 0, 0),      # inside (centre)
		Vector3(5, 0, 0),      # outside
		Vector3(2, 0, 0),      # inside (inclusive edge)
		Vector3(0, 9, 1),      # inside (height ignored)
		Vector3(-3, 0, -3),    # outside
	])
	var hits := c.hit_points(pts)
	if hits != PackedInt32Array([0, 2, 3]):
		_fail("hit_points returned %s, expected [0, 2, 3]" % [hits])
		return
	if not c.hit_points(PackedVector3Array()).is_empty():
		_fail("hit_points over no points must be empty")
		return


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
