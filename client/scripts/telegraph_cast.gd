class_name TelegraphCast
extends RefCounted
## The deterministic cast->resolve core of a telegraphed zone (issue #175,
## Phase 2 combat epic #9).
##
## A telegraph is a promise with a timer: the shape appears, fills for
## `cast_time` seconds, and then — at that one instant — whoever is standing
## inside it is hit. This class owns the promise's CLOCK and its SHAPE, and
## nothing else: no scene tree, no rendering, no wall time (callers feed
## `advance(dt)`), so every law here is unit-testable headless and cannot
## drift between runs.
##
## Two laws are deliberately structural:
##  - GEOMETRY IS DELEGATED. Membership always goes through `Telegraph`
##    (telegraph.gd), the shared client/server spatial core — this file never
##    re-derives a distance or a wedge, so the runtime's answer is the tiers'
##    answer by construction.
##  - ILLEGAL CASTS ARE UNREPRESENTABLE. The only constructors are the
##    validating factories below; a shape that could silently catch nothing
##    (zero radius, degenerate facing, out-of-range threshold, non-positive
##    cast time, non-finite input) is refused loudly at creation, never
##    carried into play as a no-op (the closed-schema idiom the settled laws
##    use everywhere else).
##
## WHEN membership is evaluated — the snapshot-at-resolution dodge law — is
## the caller's contract: `TelegraphRuntime` reads positions exactly once, at
## the resolution instant. This class only makes that easy to do and hard to
## get wrong (`contains` is pure; nothing here caches a position).

## The closed set of shapes a cast can be. Rectangle and ring exist in the
## geometry lib but have no caster yet; they join this set when a slice needs
## them, each with its own validating factory.
enum Shape { CIRCLE, CONE }

## Facings whose planar length is at or below this are refused at creation.
## The geometry lib tolerates a degenerate facing (falls back to world
## forward) because it must never NaN mid-resolution; a CAST authored with one
## is an author error and gets a loud refusal instead of a silent default.
## Mirrors `Telegraph._MIN_FACING`.
const MIN_FACING := 0.0001

## The authoritative tier bounds every telegraph's linear extent —
## `maxTelegraphExtentMM` (4e6 mm) in server/sim/telegraph.go — by CLAMPING,
## not refusing. The factories mirror that clamp with the same value and the
## same semantics: an over-cap authored extent paints exactly the shape the
## authority resolves. Refusing here instead would be the catastrophic
## direction — a client that declines to paint a cast the authority still
## resolves leaves the danger invisible.
const MAX_EXTENT_M := 4000.0

var shape: Shape
## Circle centre or cone apex, world space. Ground telegraphs are
## world-anchored: a moving caster re-begins a new cast, it never drags one.
var origin_point: Vector3
## Cone opening direction (planar; only meaningful for `Shape.CONE`).
var facing: Vector3
## Circle radius in metres (only meaningful for `Shape.CIRCLE`).
var radius: float
## Cone reach in metres (only meaningful for `Shape.CONE`).
var range_m: float
## The cone's angular threshold as the integer scaled cosine BOTH tiers
## compare against (`Telegraph.COS_SCALE`) — carried, never re-derived.
var cos_half_scaled: int
## Seconds from begin to resolution. Always > 0.
var cast_time: float
## Seconds of cast consumed so far. Monotonic; never exceeds meaning once
## `is_resolved` is set.
var elapsed := 0.0
## True exactly from the `advance` call that crossed `cast_time` onward.
var is_resolved := false
## Set by the `TelegraphRuntime` that arms this cast. One cast is one
## telegraph: a second runtime sharing the instance would advance the same
## clock twice (an early resolve on one node, a silently swallowed `resolved`
## on the other), so `begin` refuses an already-armed cast.
var armed := false


## A circular ground telegraph — "the mob casts a circle you must step out
## of". Returns null (with a loud error) when any input is invalid.
static func circle(centre: Vector3, circle_radius: float, time: float) -> TelegraphCast:
	if not centre.is_finite() or not is_finite(circle_radius) or not is_finite(time):
		push_error("TelegraphCast.circle: refusing non-finite input")
		return null
	if circle_radius <= 0.0:
		push_error("TelegraphCast.circle: radius must be > 0 (got %f) — a cast that can catch nothing is a no-op, not a telegraph" % circle_radius)
		return null
	if time <= 0.0:
		push_error("TelegraphCast.circle: cast_time must be > 0 (got %f)" % time)
		return null
	var c := TelegraphCast.new()
	c.shape = Shape.CIRCLE
	c.origin_point = centre
	c.radius = minf(circle_radius, MAX_EXTENT_M)
	c.cast_time = time
	return c


## A cone ("sector") ground telegraph — "one telegraph you cast (a cone)".
## The angular threshold arrives as the shared integer scaled cosine (see
## `Telegraph.COS_SCALE` / ability data's `cos_half_scaled`), never as
## degrees: resolution-path trig is banned, and re-deriving the threshold is
## the divergence the shared integer exists to eliminate. Returns null (with
## a loud error) when any input is invalid.
static func cone(apex: Vector3, cone_facing: Vector3, reach_m: float,
		threshold_scaled: int, time: float) -> TelegraphCast:
	if not apex.is_finite() or not cone_facing.is_finite() \
			or not is_finite(reach_m) or not is_finite(time):
		push_error("TelegraphCast.cone: refusing non-finite input")
		return null
	if reach_m <= 0.0:
		push_error("TelegraphCast.cone: range must be > 0 (got %f)" % reach_m)
		return null
	if threshold_scaled < -Telegraph.COS_SCALE or threshold_scaled > Telegraph.COS_SCALE:
		push_error("TelegraphCast.cone: cos_half_scaled %d is outside [-%d, %d] — refusing rather than clamping an authoring error"
			% [threshold_scaled, Telegraph.COS_SCALE, Telegraph.COS_SCALE])
		return null
	if Vector2(cone_facing.x, cone_facing.z).length() <= MIN_FACING:
		push_error("TelegraphCast.cone: facing has no planar direction — a cone cast needs a real heading")
		return null
	if time <= 0.0:
		push_error("TelegraphCast.cone: cast_time must be > 0 (got %f)" % time)
		return null
	var c := TelegraphCast.new()
	c.shape = Shape.CONE
	c.origin_point = apex
	c.facing = cone_facing
	c.range_m = minf(reach_m, MAX_EXTENT_M)
	c.cos_half_scaled = threshold_scaled
	c.cast_time = time
	return c


## Do this cast's fields satisfy every law the factories enforce? The
## factories guarantee it at creation, but GDScript cannot make the fields
## immutable — a hand-rolled `TelegraphCast.new()` or a post-factory field
## write can carry illegal state. `TelegraphRuntime.begin` re-checks through
## this before trusting a cast it did not construct.
func is_valid() -> bool:
	if not origin_point.is_finite() or not is_finite(cast_time) or cast_time <= 0.0:
		return false
	if not is_finite(elapsed) or elapsed < 0.0:
		return false
	match shape:
		Shape.CIRCLE:
			return is_finite(radius) and radius > 0.0 and radius <= MAX_EXTENT_M
		Shape.CONE:
			if not facing.is_finite() or Vector2(facing.x, facing.z).length() <= MIN_FACING:
				return false
			if cos_half_scaled < -Telegraph.COS_SCALE or cos_half_scaled > Telegraph.COS_SCALE:
				return false
			return is_finite(range_m) and range_m > 0.0 and range_m <= MAX_EXTENT_M
	return false


## A fresh, factory-built copy of this cast's SPEC (shape + timing, clock at
## zero). The runtime arms a private copy so a caller mutating their instance
## after `begin` can never desync the painted shape from the resolved one.
## Only meaningful on a valid cast (`is_valid`).
func duplicate_spec() -> TelegraphCast:
	match shape:
		Shape.CIRCLE:
			return TelegraphCast.circle(origin_point, radius, cast_time)
		Shape.CONE:
			return TelegraphCast.cone(origin_point, facing, range_m, cos_half_scaled, cast_time)
	return null


## Consume `dt` seconds of cast. Returns true exactly once: on the call that
## crossed `cast_time` (the resolution instant). A negative or non-finite dt
## is refused loudly with no state change; advancing a resolved cast is a
## quiet no-op returning false (the runtime keeps stepping through its linger
## without re-resolving).
func advance(dt: float) -> bool:
	if not is_finite(dt) or dt < 0.0:
		push_error("TelegraphCast.advance: dt must be finite and >= 0 (got %s)" % dt)
		return false
	if is_resolved:
		return false
	elapsed += dt
	if elapsed >= cast_time:
		is_resolved = true
		return true
	return false


## Cast completion in [0, 1] — the presentation's fill fraction.
func progress() -> float:
	return clampf(elapsed / cast_time, 0.0, 1.0)


## Is this world-space point inside the telegraphed zone right now? Pure
## delegation to the shared geometry core — planar XZ, inclusive edges,
## height ignored — so the answer here is the answer everywhere.
func contains(point: Vector3) -> bool:
	match shape:
		Shape.CIRCLE:
			return Telegraph.in_circle(origin_point, radius, point)
		Shape.CONE:
			return Telegraph.in_cone_scaled(origin_point, facing, range_m, cos_half_scaled, point)
	push_error("TelegraphCast.contains: unhandled shape %d" % shape)
	return false


## Indices of `points` that are inside the zone — the resolution helper for
## callers that snapshot a target list. Order-preserving.
func hit_points(points: PackedVector3Array) -> PackedInt32Array:
	var hits := PackedInt32Array()
	for i in points.size():
		if contains(points[i]):
			hits.append(i)
	return hits
