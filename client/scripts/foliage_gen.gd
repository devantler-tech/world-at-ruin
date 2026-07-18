class_name FoliageGen
extends RefCounted
## Environmental foliage scatter — the deterministic spine of the Ashfall
## Reach's ground cover. The world already ships its landmarks (the Wardens'
## Shrine, the starter cave, the 44-site ruin field in WorldGen) but the ground
## between them is bare; Phase 3 (#10) wants the region to read as desolation,
## not emptiness — ashen scrub, dead grass, bone piles, scattered rubble.
##
## This library answers only WHERE cosmetic props sit and WHICH kind each is.
## It is PURE — no scene tree, no engine singletons, no clock, no `user://` — so
## it is deterministic and unit-testable, exactly like `Discovery`'s membership
## and `Telegraph`'s shape predicates. WHAT a prop looks like (mesh, material)
## and getting it on screen (a MultiMesh, LOD) are the caller's concern and a
## separate follow-up; this pins placement, not rendering.
##
## Three product laws are mechanical here, not review-time hopes:
##   1. DETERMINISM — same params, same scatter every boot. Placement is driven
##      by an OWN seeded RandomNumberGenerator (never the process-global RNG),
##      so a build is reproducible and CI can pin a committed golden (the #58
##      WorldGen pattern). Millimetre quantisation makes the golden robust to
##      platform float noise while catching any real drift.
##   2. KEEP-OUTS — nothing lands inside a supplied circle (the shrine clearing,
##      the cave footprint, a ruin's), nothing outside the world bounds, and
##      (optionally) nothing within `min_sep` of an already-placed prop, so
##      scenery never buries a landmark or stacks on itself. This is the same
##      rejection discipline `WorldGen._scatter_ruins` already follows.
##   3. HORIZONTAL-ONLY — foliage is scenery and grants nothing. The placement
##      schema has a CLOSED field set (`kind`/`pos`/`yaw`/`scale`) and a CLOSED
##      cosmetic kind set; there is no representable stat/power field, and
##      `find_forbidden` is the static audit any foliage source must pass — the
##      same guard the ability registry uses so "breadth, never bigger numbers"
##      cannot be quietly broken by a future author.

## The closed set of cosmetic ground props. Purely visual — a kind carries no
## gameplay effect. Adding a kind is a forward-only extension (append; never
## repurpose an existing value, or a shipped world would silently restyle).
enum Kind { ASH_SHRUB, DEAD_GRASS, BONE_PILE, RUBBLE }
const KIND_COUNT := 4

## The CLOSED schema of a placement dictionary. `find_forbidden` rejects any
## placement carrying a key outside this set — so a `power`/`damage`/`stat`
## field simply cannot ride along on a foliage prop (the horizontal-only guard).
const PLACEMENT_KEYS: Array[String] = ["kind", "pos", "yaw", "scale"]

## Default per-prop scale band (metres of visual scale multiplier). Cosmetic.
const SCALE_MIN := 0.7
const SCALE_MAX := 1.5

## Default "there is no ground here" threshold: a sampled height at or below
## this means the candidate has no surface to stand on (a hole, or off the
## terrain grid) and is REJECTED rather than placed. Numerically matches
## `WorldGen.NO_GROUND` (-1e6, what `surface_height_at` returns outside the
## grid) WITHOUT importing it, so this library keeps its deliberate
## independence from WorldGen; callers with a different sentinel override it
## via `params.no_ground`.
const NO_GROUND := -1.0e6


## Scatter `count` cosmetic props across the square region
## [-half_extent, half_extent]² (inset by `margin`), avoiding every keep-out
## circle and — when `min_sep > 0` — each other, deterministically from `seed`.
##
## `params` (all but `seed` optional):
##   seed:           int    — RNG seed; the whole scatter is a pure function of it.
##   count:          int    — target number of props (result may be fewer if the
##                            region is crowded; never more).
##   half_extent:    float  — half the region edge; bounds are ±half_extent on x,z.
##   margin:         float  — inset from the bounds edge (like the ruin scatter).
##   keep_outs:      Array  — circles to avoid, each [Vector2 centre_xz, float radius];
##                            malformed entries are skipped, never a crash.
##   min_sep:        float  — minimum planar spacing between placed props (0 = off).
##   max_attempts:   int    — hard cap on rejection draws so a crowded region always
##                            terminates (default count * 32).
##   no_ground:      float  — sampled heights at or below this (and any
##                            non-finite height) mean "no surface here", so the
##                            candidate is REJECTED rather than placed at a
##                            sentinel depth (default NO_GROUND = -1e6, matching
##                            WorldGen.surface_height_at's off-grid return).
##   height_sampler: Callable(x, z) -> float — ground height for the prop's y
##                            (default 0.0); decouples the lib from WorldGen so it
##                            stays unit-testable with an analytic surface.
##   kind_weights:   Array[float] — length KIND_COUNT relative weights for kind
##                            selection (default uniform); non-positive/short arrays
##                            fall back to uniform.
##
## Returns placements in placement order (itself deterministic), each a Dictionary
## {kind:int, pos:Vector3, yaw:float, scale:float}. Height is dropped from every
## keep-out and spacing test — a prop is a mark on the ground.
static func scatter(params: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var count := int(params.get("count", 0))
	var half_extent := float(params.get("half_extent", 0.0))
	if count <= 0 or half_extent <= 0.0:
		return out
	var margin := maxf(0.0, float(params.get("margin", 0.0)))
	var lo := -half_extent + margin
	var hi := half_extent - margin
	if lo >= hi:
		return out
	var min_sep := maxf(0.0, float(params.get("min_sep", 0.0)))
	var min_sep_sq := min_sep * min_sep
	var max_attempts := int(params.get("max_attempts", count * 32))
	var keep_outs := _sanitize_keep_outs(params.get("keep_outs", []))
	var weights := _sanitize_weights(params.get("kind_weights", []))
	# A malformed (non-Callable) sampler is ignored, never a crash — ground
	# height then defaults to 0, matching an omitted sampler.
	var sampler := Callable()
	var raw_sampler: Variant = params.get("height_sampler", null)
	if raw_sampler is Callable:
		sampler = raw_sampler
	var no_ground := float(params.get("no_ground", NO_GROUND))

	var rng := RandomNumberGenerator.new()
	rng.seed = int(params.get("seed", 0))

	var attempts := 0
	while out.size() < count and attempts < max_attempts:
		attempts += 1
		# Draw the candidate FIRST and reject before consuming any style RNG, so
		# the stream advances by exactly 2 per rejection — placement stays a pure
		# function of the seed regardless of how crowded the region is.
		var x := rng.randf_range(lo, hi)
		var z := rng.randf_range(lo, hi)
		if _inside_any_keep_out(x, z, keep_outs):
			continue
		if min_sep_sq > 0.0 and _too_close(x, z, out, min_sep_sq):
			continue
		# Ground BEFORE style: a candidate with no surface under it is rejected
		# like any other, so it too costs exactly 2 draws and the stream
		# invariant above still holds. Sampling here (rather than at the end)
		# also means the sampler is never called for an already-rejected
		# candidate — and because reading a height consumes no RNG, moving this
		# up leaves every accepted placement, and the committed golden, byte
		# identical.
		var y := 0.0
		if sampler.is_valid():
			y = float(sampler.call(x, z))
			if not is_finite(y) or y <= no_ground:
				continue
		var kind := _pick_kind(rng, weights)
		var yaw := rng.randf_range(0.0, TAU)
		var scale := rng.randf_range(SCALE_MIN, SCALE_MAX)
		out.append({"kind": kind, "pos": Vector3(x, y, z), "yaw": yaw, "scale": scale})
	return out


## Whether `k` names a valid cosmetic kind.
static func is_valid_kind(k: int) -> bool:
	return k >= 0 and k < KIND_COUNT


## The horizontal-only / schema audit: returns every placement in `placements`
## that is not a well-formed cosmetic prop — a non-Dictionary entry, a key
## outside PLACEMENT_KEYS (e.g. a `power`/`stat`/`damage` field a future author
## tried to attach), a missing required key, or a kind outside the closed set.
## An empty result means the batch is provably cosmetic-only. Any foliage source
## must pass this, the same way the ability registry must pass its power-budget
## and dominance guards.
static func find_forbidden(placements: Array) -> Array:
	var bad: Array = []
	for p: Variant in placements:
		if p is not Dictionary:
			bad.append(p)
			continue
		var d: Dictionary = p
		var ok := true
		for key: Variant in d:
			if not (key is String) or not PLACEMENT_KEYS.has(key):
				ok = false
				break
		if ok:
			for req: String in PLACEMENT_KEYS:
				if not d.has(req):
					ok = false
					break
		if ok and not is_valid_kind(int(d["kind"])):
			ok = false
		if not ok:
			bad.append(p)
	return bad


## Keep only well-formed [Vector2 centre, float radius] circles; a negative
## radius is degenerate (catches nothing) and harmlessly kept.
static func _sanitize_keep_outs(raw: Variant) -> Array:
	var out: Array = []
	if raw is not Array:
		return out
	for entry: Variant in raw:
		if entry is not Array:
			continue
		var a: Array = entry
		if a.size() < 2 or a[0] is not Vector2:
			continue
		out.append([a[0] as Vector2, float(a[1])])
	return out


## Normalise kind weights to a usable cumulative table, or [] for uniform. A
## short array, a non-Array, or a non-positive total all fall back to uniform.
static func _sanitize_weights(raw: Variant) -> Array:
	if raw is not Array:
		return []
	var a: Array = raw
	if a.size() != KIND_COUNT:
		return []
	var cum: Array = []
	var total := 0.0
	for w: Variant in a:
		total += maxf(0.0, float(w))
		cum.append(total)
	if total <= 0.0:
		return []
	return cum


## A weighted kind draw (or uniform when `cum` is empty). Uniform consumes one
## randi; weighted consumes one randf — deterministic per config either way.
static func _pick_kind(rng: RandomNumberGenerator, cum: Array) -> int:
	if cum.is_empty():
		return rng.randi_range(0, KIND_COUNT - 1)
	var pick := rng.randf() * float(cum[cum.size() - 1])
	for i in KIND_COUNT:
		if pick <= float(cum[i]):
			return i
	return KIND_COUNT - 1


## Inside any keep-out circle on the XZ plane (inclusive edge). Height ignored.
static func _inside_any_keep_out(x: float, z: float, keep_outs: Array) -> bool:
	for c: Array in keep_outs:
		var centre: Vector2 = c[0]
		var r: float = c[1]
		if r < 0.0:
			continue
		if Vector2(x, z).distance_squared_to(centre) <= r * r:
			return true
	return false


## Within `min_sep` (squared) of an already-placed prop on the XZ plane.
static func _too_close(x: float, z: float, placed: Array[Dictionary], min_sep_sq: float) -> bool:
	var here := Vector2(x, z)
	for p: Dictionary in placed:
		var pos: Vector3 = p["pos"]
		if here.distance_squared_to(Vector2(pos.x, pos.z)) < min_sep_sq:
			return true
	return false
