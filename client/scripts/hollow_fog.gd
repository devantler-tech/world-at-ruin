class_name HollowFog
## Deterministic placement of local ash pools in the terrain's hollows (#211).
##
## The froxel volumetrics enabled by #158 are uniform: the same density
## everywhere, so a hollow holds no more ash than a ridgeline and the air reads
## placeless. This library picks the places where ash would actually gather —
## ground that sits below its own surroundings — so [FogVolume] nodes can
## thicken the air there while the rest of the Reach keeps the tuned baseline.
##
## PURE and RNG-FREE by construction: every decision comes from sampling the
## already-baked height field through the caller's sampler. It draws from no
## random stream at all, shared or local, so it cannot shift the draw order
## that the worldgen and foliage goldens pin (the #109 oracle lesson — an
## unmirrored ordering change reads as a phantom divergence downstream).
##
## Placement is computed on every boot, including where the #158 probe answers
## no; only the *rendering* is gated. That keeps the property testable under
## `--headless`, where volumetrics never initialise and a FogVolume would
## contribute no pixels to read back.

## Edge inset, in metres. Candidates never sit near the world edge, where the
## surrounding ring would sample outside the terrain and the relief measure
## would be reading absent ground rather than a hollow.
const EDGE_INSET := 24.0
## Spacing of the candidate lattice, in metres. Coarse: this is looking for
## basin-scale relief, not surface roughness.
const CANDIDATE_STEP := 8.0
## Radius of the ring sampled around a candidate to establish what "the
## surroundings" are, in metres. Sized to the basin scale the low-frequency
## terrain noise produces, not to the grid step.
const RING_RADIUS := 14.0
## Number of samples taken around that ring. Enough that a single spur or gully
## cutting the ring cannot dominate the mean.
const RING_SAMPLES := 12
## Minimum relief (metres the ground sits below its ring mean) for a candidate
## to count as a hollow at all. Below this the terrain is merely undulating,
## and thickening the air there would just restore the uniformity #211 is
## about. Calibrated against HEIGHT_AMP 7.0: a real basin clears this easily.
const MIN_RELIEF := 0.9
## Minimum distance between two placed volumes, in metres. This MUST stay
## comfortably above twice POOL_RADIUS, and that is not a stylistic preference:
## fog volumes composite by adding optical depth, so two overlapping pools do
## not read as two pools — they read as one sheet at double density. The first
## tuning of this change had 44 m-wide pools only 30 m apart and turned the
## whole near field into a flat haze that swallowed the ruin pillars and the
## ground debris. Disjoint pools are what make pooling legible as pooling.
const MIN_SEPARATION := 46.0
## Hard cap on placed volumes. Volumetric fog is a per-froxel cost; a handful
## of large pools is the visual goal anyway, and the cap keeps the cost bounded
## no matter what a future terrain seed does.
const MAX_VOLUMES := 6
## Horizontal radius of a pool, in metres. Wide enough that the density
## gradient is felt while walking in rather than crossed in one step, but held
## below MIN_SEPARATION / 2 so pools never merge (see MIN_SEPARATION).
const POOL_RADIUS := 18.0
## Vertical thickness of a pool, in metres. Shallow relative to its width: ash
## settling in a basin is a layer, not a sphere. Kept low deliberately — a tall
## volume fogs the player's own eye level instead of being something they look
## down into, which is what made the first tuning read as a wall of haze.
const POOL_HEIGHT := 6.0
## How far the pool's centre sits above the hollow floor, as a fraction of
## POOL_HEIGHT. Slightly under half, so the densest part hugs the ground.
const POOL_LIFT_FRACTION := 0.38
## Added density at the pool's core, on top of the environment's baseline
## volumetric density (0.005). Deliberately well UNDER the baseline: the goal
## is a visible difference between hollow and ridge, not a wall of fog that
## costs readability. Tuned down from 0.006 after the first version erased the
## near-field debris and pillars entirely — density that reads as "thicker air"
## from outside a basin is much lower than it feels like it should be, because
## the volume's depth along the view ray does most of the work.
const POOL_DENSITY := 0.0035
## Relief at which a pool reaches full POOL_DENSITY, in metres. Shallower
## hollows scale down proportionally, so depth reads as density instead of
## every basin looking identically thick.
const FULL_DENSITY_RELIEF := 3.0


## Every ash pool this terrain calls for, deepest hollow first.
##
## [param height_sampler] takes (x: float, z: float) and returns the surface
## height there, or [param no_ground] outside the terrain — i.e. exactly
## [method WorldGen.surface_height_at]. [param world_size] is the terrain edge
## length in metres.
##
## Each entry: `pos` (Vector3, the pool centre in world space), `extents`
## (Vector3, half-sizes), `density` (float, added core density), `relief`
## (float, metres below the surroundings — the reason it was chosen).
static func place(height_sampler: Callable, world_size: float, no_ground: float) -> Array[Dictionary]:
	var candidates := _survey(height_sampler, world_size, no_ground)
	# Deepest first, then a total order on position so that two candidates of
	# equal relief can never swap between runs (float equality is reachable
	# here: a symmetric basin yields mirrored samples).
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(a["relief"], b["relief"]):
			return a["relief"] > b["relief"]
		if not is_equal_approx(a["x"], b["x"]):
			return a["x"] < b["x"]
		return a["z"] < b["z"]
	)
	var placed: Array[Dictionary] = []
	for cand: Dictionary in candidates:
		if placed.size() >= MAX_VOLUMES:
			break
		if _too_close(placed, cand["x"], cand["z"]):
			continue
		placed.append(_pool(cand))
	return placed


## Candidate hollows: lattice points whose ground sits at least MIN_RELIEF
## below the mean of the ring around them. Points whose ring leaves the terrain
## are discarded rather than clamped — a half-sampled ring measures the world
## edge, not a basin.
static func _survey(height_sampler: Callable, world_size: float, no_ground: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var limit := world_size / 2.0 - EDGE_INSET
	var x := -limit
	while x <= limit:
		var z := -limit
		while z <= limit:
			var centre: float = height_sampler.call(x, z)
			if centre <= no_ground:
				z += CANDIDATE_STEP
				continue
			var ring := _ring_mean(height_sampler, x, z, no_ground)
			if is_nan(ring):
				z += CANDIDATE_STEP
				continue
			var relief := ring - centre
			if relief >= MIN_RELIEF:
				out.append({"x": x, "z": z, "floor": centre, "relief": relief})
			z += CANDIDATE_STEP
		x += CANDIDATE_STEP
	return out


## Mean surface height on the ring around (x, z), or NAN if any sample falls
## outside the terrain.
static func _ring_mean(height_sampler: Callable, x: float, z: float, no_ground: float) -> float:
	var total := 0.0
	for i in RING_SAMPLES:
		var angle := TAU * float(i) / float(RING_SAMPLES)
		var h: float = height_sampler.call(
			x + cos(angle) * RING_RADIUS,
			z + sin(angle) * RING_RADIUS
		)
		if h <= no_ground:
			return NAN
		total += h
	return total / float(RING_SAMPLES)


static func _too_close(placed: Array[Dictionary], x: float, z: float) -> bool:
	for p: Dictionary in placed:
		var pos: Vector3 = p["pos"]
		if Vector2(pos.x - x, pos.z - z).length() < MIN_SEPARATION:
			return true
	return false


## A candidate turned into a pool: centred just above the hollow floor, with
## density scaled by how deep the hollow actually is.
static func _pool(cand: Dictionary) -> Dictionary:
	var relief: float = cand["relief"]
	var scale := clampf(relief / FULL_DENSITY_RELIEF, 0.0, 1.0)
	return {
		"pos": Vector3(
			cand["x"],
			float(cand["floor"]) + POOL_HEIGHT * POOL_LIFT_FRACTION,
			cand["z"]
		),
		"extents": Vector3(POOL_RADIUS, POOL_HEIGHT / 2.0, POOL_RADIUS),
		"density": POOL_DENSITY * scale,
		"relief": relief,
	}


## Builds the renderable node for one placement. Kept here beside the placement
## rules so the shape the player sees and the shape the tests reason about
## cannot drift apart.
static func build_volume(placement: Dictionary) -> FogVolume:
	var vol := FogVolume.new()
	vol.shape = RenderingServer.FOG_VOLUME_SHAPE_ELLIPSOID
	var extents: Vector3 = placement["extents"]
	vol.size = extents * 2.0
	vol.position = placement["pos"]
	var mat := FogMaterial.new()
	mat.density = placement["density"]
	# Same ash the environment volume uses, so a pool reads as more of the same
	# air rather than a differently-coloured object hanging in the world.
	mat.albedo = Volumetrics.ALBEDO
	# Fade the ellipsoid's rim so a pool has no visible boundary — a hard edge
	# would read as a dome of fog, which is exactly the "placed object" tell
	# this change exists to remove.
	mat.edge_fade = 0.6
	# Density falls off toward the top of the volume: ash is heaviest on the
	# floor of the hollow and thins as it fills, which is what makes walking
	# down into one feel like descending into it.
	mat.height_falloff = 0.4
	return vol
