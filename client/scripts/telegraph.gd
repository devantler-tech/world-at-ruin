class_name Telegraph
extends RefCounted
## Telegraph geometry — the deterministic spatial core of telegraphed combat,
## the "signal in the ground, not the frames" the design leans on (AGENTS.md).
##
## A telegraph is a shape painted on the floor that resolves after a cast: step
## out and you are safe, stand in it and you are hit. Both tiers ask the SAME
## spatial question and must get the SAME answer — the server to resolve a hit
## authoritatively (physics stays out of the auth path; this is planar capsule
## math, not a collision engine), and the client to preview/predict so the
## player can see whether they are standing in danger before it lands.
##
## This library answers only that one question: "is this point inside this
## shape right now?". It is PURE — no scene tree, no engine state, no time — so
## it is deterministic and unit-testable, exactly like the planar selector
## `Interactable.choose`. Cast timing and snapshot-at-resolution semantics (WHEN
## to evaluate membership) are the caller's — the authoritative server's —
## concern; the visible telegraph decal and its taste-gated readability are a
## separate follow-up. Callers pass world-space points; membership is measured
## on the XZ plane so a target's height never changes whether it is caught.

## Facings shorter than this (in metres) are treated as degenerate and fall
## back to world-forward (-Z), matching `Interactable.choose`, so a zero or
## near-zero facing yields a deterministic shape rather than a NaN.
const _MIN_FACING := 0.0001

## The fixed-point scale for a cone's half-angle cosine, mirroring
## `sim.CosScale` in server/sim/telegraph.go EXACTLY.
##
## A cone's angular threshold is carried between the tiers as the INTEGER
## `cos(half_angle)·COS_SCALE`, and both tiers compare against that one number.
## This is the single source of truth the two tiers share: previously the server
## held a precomputed scaled cosine while this file called
## `cos(deg_to_rad(half))` at resolution time, so each tier derived its own
## threshold and they agreed only up to quantization. A cone whose angle is not
## exactly representable at this scale then gives the two tiers slightly
## different wedges — and the failure mode is a player-visible desync (dodged on
## screen, hit on the server), the exact class telegraph geometry exists to
## prevent. Consuming one shared integer removes the divergence BY
## CONSTRUCTION rather than by convention.
const COS_SCALE := 1_000_000


## Convert an author's half-angle in degrees to the integer scaled cosine both
## tiers consume. This is an AUTHORING/INGESTION-time conversion — it is the one
## place a trigonometric function may be called, deliberately outside the
## resolution path so the authoritative tick core stays trig-free and
## integer-only (platform math libraries are not bit-identical).
##
## Rounding is CEIL (toward +1) rather than nearest, and that direction is
## load-bearing, not incidental. A larger cosine is a NARROWER wedge, so
## rounding up guarantees the shared threshold is never WIDER than the exact
## angle an author wrote. The residual sub-quantum disagreement can then only
## ever spare a player the client drew as hit, never hit one the client drew as
## safe — the failure direction a dodge-based game should prefer. The server's
## `CosScale` doc states this as a rule authors must follow; here it is
## MECHANICAL, so an author cannot round the other way.
##
## `half_angle_deg` is clamped to [0, 180] to match `in_cone`, so 180 yields
## -COS_SCALE (a full disc) and 0 yields +COS_SCALE (a degenerate ray).
static func cos_half_scaled_from_deg(half_angle_deg: float) -> int:
	var half := clampf(half_angle_deg, 0.0, 180.0)
	return int(ceil(cos(deg_to_rad(half)) * COS_SCALE))


## The point projected onto the XZ plane. Height is deliberately dropped: a
## telegraph is a mark on the ground, so a tall target standing in it is caught
## and a hovering one at the same footprint is caught the same way.
static func _xz(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)


## A normalised planar heading from a world-space direction, defaulting to
## world-forward (-Z) when the input is too short to have a stable direction.
static func _planar_dir(v: Vector3) -> Vector2:
	var d := Vector2(v.x, v.z)
	return d.normalized() if d.length() > _MIN_FACING else Vector2(0, -1)


## Inside a filled disc of `radius` around planar `center` (inclusive edge).
## A negative radius is degenerate and catches nothing. This is the "mob casts
## a circle you must step out of" telegraph.
static func in_circle(center: Vector3, radius: float, point: Vector3) -> bool:
	if radius < 0.0:
		return false
	return _xz(point).distance_squared_to(_xz(center)) <= radius * radius


## Inside the annulus (ring band) around planar `center`, between `inner` and
## `outer` radii (both edges inclusive) — the danger band with a safe hole in
## the middle and safety beyond the rim. The two radii may be given in either
## order; a negative inner is clamped to 0 (a filled disc). A negative outer is
## degenerate and catches nothing.
static func in_ring(center: Vector3, inner: float, outer: float, point: Vector3) -> bool:
	var ri := maxf(0.0, minf(inner, outer))
	var ro := maxf(inner, outer)
	if ro < 0.0:
		return false
	var d2 := _xz(point).distance_squared_to(_xz(center))
	return d2 >= ri * ri and d2 <= ro * ro


## Inside a sector ("cone") with its apex at `apex`, opening toward planar
## `facing`, reaching `range_m` metres, and whose angular threshold is the
## INTEGER scaled cosine `cos_half_scaled` (see `COS_SCALE`) — the same number
## the authoritative server compares against, carried by ability data rather
## than derived independently by each tier.
##
## The apex itself counts as inside; a negative range catches nothing;
## `cos_half_scaled` is clamped to [-COS_SCALE, +COS_SCALE], so -COS_SCALE
## degenerates to a full disc of `range_m`. Both the range edge and the angular
## edge are inclusive. This is the "one telegraph you cast (a cone)" telegraph.
##
## This is the RESOLUTION-path entry point and it calls no trigonometric
## function: the threshold arrives already quantized, so the client's wedge is
## the server's wedge by construction.
static func in_cone_scaled(apex: Vector3, facing: Vector3, range_m: float,
		cos_half_scaled: int, point: Vector3) -> bool:
	if range_m < 0.0:
		return false
	var to := _xz(point) - _xz(apex)
	var dist := to.length()
	if dist > range_m:
		return false
	# On the apex: fully inside rather than dividing by ~0 for the facing test.
	if dist < _MIN_FACING:
		return true
	var threshold := clampi(cos_half_scaled, -COS_SCALE, COS_SCALE)
	var faced := _planar_dir(facing).dot(to / dist)
	return faced >= float(threshold) / float(COS_SCALE)


## Inside a sector ("cone") given the half-angle in DEGREES — an authoring and
## presentation convenience that quantizes through `cos_half_scaled_from_deg`
## and then defers to `in_cone_scaled`.
##
## Prefer `in_cone_scaled` wherever a resolution answer must match the server:
## this overload re-derives the threshold from degrees, which is exactly the
## independent derivation the shared integer exists to eliminate. It is safe
## here only because it quantizes through the SAME ceil-rounded conversion the
## authoritative value uses, so it can never be WIDER than the shared wedge.
static func in_cone(apex: Vector3, facing: Vector3, range_m: float,
		half_angle_deg: float, point: Vector3) -> bool:
	return in_cone_scaled(
		apex, facing, range_m, cos_half_scaled_from_deg(half_angle_deg), point)


## Inside an oriented rectangle ("beam") whose near edge sits at `origin` and
## which extends `length_m` metres forward along planar `facing`, `half_width`
## metres to each side. `origin` is the caster end: points behind it (negative
## projection) are outside. A negative length or width is degenerate and
## catches nothing; all edges are inclusive.
static func in_rect(origin: Vector3, facing: Vector3, length_m: float,
		half_width: float, point: Vector3) -> bool:
	if length_m < 0.0 or half_width < 0.0:
		return false
	var dir := _planar_dir(facing)
	# Planar perpendicular (left/right axis) of the facing.
	var side := Vector2(-dir.y, dir.x)
	var to := _xz(point) - _xz(origin)
	var along := to.dot(dir)
	if along < 0.0 or along > length_m:
		return false
	return absf(to.dot(side)) <= half_width
