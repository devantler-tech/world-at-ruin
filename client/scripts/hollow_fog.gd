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

## Whether pools should actually be BUILT this boot.
##
## One condition now, and it is a hardware fact rather than a player choice.
## #211 shipped these pools behind an opt-in flag (`WAR_HOLLOW_FOG`) for a
## stated reason: the ash had no second-order life — it did not drift and did
## not answer the wind — and AGENTS.md names exactly that ("no wind or sway") as
## a placeholder tell that keeps player-facing work default-off. #233 gave it
## drift, so the reason expired and the flag went with it. A release flag is
## short-lived by contract; leaving one that has done its job is flag debt.
##
## Kept as a pure function so both states stay testable where no GPU exists.
static func should_build(volumetrics_on: bool) -> bool:
	return volumetrics_on


## Leading token of the line main.gd prints once the build decision is made
## (#232), parsed by CI's frame-capture job exactly like Volumetrics'.
##
## This marker survives the flag's retirement, and is still not redundant with
## the volumetrics one. The two answer different questions: the volumetrics
## verdict says the froxel pass is running, this says pools were actually built
## into THIS world. They can still disagree — a terrain that offers no hollow
## deep enough to clear [constant MIN_RELIEF] renders volumetrics with zero
## pools — so a capture job reading only the GPU verdict would claim the frames
## show pooling when they cannot. Two facts, two markers.
const CAPTURE_MARKER := "HOLLOW FOG"

## The exact line main.gd prints for a build decision. As with Volumetrics, the
## SECOND whitespace-separated field is the machine-readable verdict, `on` or
## `off`; the rest is for a human reading the log.
static func marker(built: bool, volumetrics_on: bool, pools: int) -> String:
	if built:
		return "%s on — %d drifting ash pools" % [CAPTURE_MARKER, pools]
	var reason: String = (
		"volumetrics unavailable" if not volumetrics_on
		else "no hollow clears the relief threshold"
	)
	return "%s off — %s (%d pools placed, not built)" % [
		CAPTURE_MARKER, reason, pools
	]


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
## volumetric density (0.005). An order of magnitude over that baseline, which
## is what makes a hollow read as thicker air rather than as more of the same.
##
## This is the first value here ever judged on a rendered frame. Every earlier
## one was inert: build_volume() configured a FogMaterial but never assigned it,
## so the volumes rendered at Godot's default density instead — far heavier than
## anything tuned here. That default is what erased the near-field pillars and
## debris in the first version, and narrowing the pools fixed it by changing
## their GEOMETRY; the density constant was never in play. Measured on the
## `sunward` vantage against the same frame at 0.0035: 3.4% of pixels change and
## the left basin's mean luminance moves 0.0025, while the near-field debris,
## pillars and character stay fully legible — and it remains ~16x subtler than
## the materialless default it replaces.

## Density at a pool's core, at full depth.
##
## ⚠️ FogMaterial.density is NOT the same unit as
## Environment.volumetric_fog_density (0.005 there). It is a multiplier applied
## within the volume and Godot's own default is 1.0, so a value picked on the
## environment's scale renders as nothing at all. Tuned by rendering the same
## vantage and judging the frames: 0.005 / 0.02 / 0.05 / 0.12 are all
## indistinguishable from no pools at all (0.05 measured a 0.00025 mean
## luminance delta, against 0.00118 here), 0.7 is readable but very faint, and
## the near field stays crisp well past this value.
const POOL_DENSITY := 1.2
## Relief at which a pool reaches full POOL_DENSITY, in metres. Shallower
## hollows scale down proportionally, so depth reads as density instead of
## every basin looking identically thick.

## Relief at which a pool reaches full POOL_DENSITY, in metres. Shallower
## hollows scale down proportionally, so depth reads as density instead of
## every basin looking identically thick.
##
## Set ABOVE the shipped terrain's deepest hollow (~7.6 m), not below it. At
## 3.0 every hollow deeper than 3 m clamped to the maximum, so the six shipped
## pools spanned 0.0433-0.0500 — a 15% spread across hollows whose depth
## varies nearly threefold. The gradient the dev log promises the player
## ("deeper hollows hold more") existed only in the constant.

## Relief at which a pool reaches full POOL_DENSITY, in metres. Shallower
## hollows scale down proportionally, so depth reads as density rather than
## every basin looking identically thick.
##
## Matched to the REAL range of the shipped terrain's outdoor hollows, which is
## narrow: 2.60-2.90 m. An earlier value of 8.0 was calibrated against a 7.63 m
## "hollow" that turned out to be the cave massif's buried skirt, and once that
## artifact was filtered out it left every real pool driven at about a third of
## its intended density. The honest consequence is that this terrain offers
## little depth variation to express — the scaling is real, but on Ashfall
## Reach it separates pools by around 1.2x, not by an order of magnitude.
const FULL_DENSITY_RELIEF := 3.0


## Every ash pool this terrain calls for, deepest hollow first.
##
## [param height_sampler] takes (x: float, z: float) and returns the surface
## height there, or [param no_ground] outside the terrain — i.e. exactly
## [method WorldGen.surface_height_at]. [param world_size] is the terrain edge
## length in metres.
##
## [param keep_out] takes (x, z) and returns true where a candidate must be
## refused — in the shipped world, [method WorldGen.cave_protects]. This is not
## optional polish: the height field is deliberately DEPRESSED beneath the
## starter-cave massif, so the buried skirt reads as by far the deepest hollow
## in the world (7.6 m against 2.9 m for the deepest real basin). Without this
## filter the densest pool in the Reach lands inside the starter cave, taking a
## slot from the landscape and fogging an interior whose darkness is designed.
##
## Each entry: `pos` (Vector3, the pool centre in world space), `extents`
## (Vector3, half-sizes), `density` (float, added core density), `relief`
## (float, metres below the surroundings — the reason it was chosen).
static func place(
	height_sampler: Callable, world_size: float, no_ground: float, keep_out: Callable
) -> Array[Dictionary]:
	var candidates := _survey(height_sampler, world_size, no_ground, keep_out)
	# Deepest first, then a total order on position so that two candidates of
	# equal relief can never swap between runs (float equality is reachable
	# here: a symmetric basin yields mirrored samples).
	# Sort on QUANTISED relief compared exactly, never is_equal_approx: an
	# approximate equality is not transitive (a~b and b~c while a!~c), so a
	# comparator built on it is not a total order and sort_custom may order
	# three close candidates inconsistently — which the greedy separation pass
	# and the six-pool cap then turn into different placements. Quantising to
	# millimetres and comparing exactly gives a real total order while still
	# absorbing platform float noise, the same trick the goldens use.
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ra := roundi(float(a["relief"]) * 1000.0)
		var rb := roundi(float(b["relief"]) * 1000.0)
		if ra != rb:
			return ra > rb
		var ax := roundi(float(a["x"]) * 1000.0)
		var bx := roundi(float(b["x"]) * 1000.0)
		if ax != bx:
			return ax < bx
		return roundi(float(a["z"]) * 1000.0) < roundi(float(b["z"]) * 1000.0)
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
static func _survey(
	height_sampler: Callable, world_size: float, no_ground: float, keep_out: Callable
) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var limit := world_size / 2.0 - EDGE_INSET
	var x := -limit
	while x <= limit:
		var z := -limit
		while z <= limit:
			if keep_out.call(x, z):
				z += CANDIDATE_STEP
				continue
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
	# Without this the volume renders nothing at all: a FogVolume with no
	# material contributes no local density, so every pool would be invisible
	# and the whole feature a silent no-op.
	vol.material = mat
	return vol


# ── Drift (#233) ──────────────────────────────────────────────────────────────
#
# Everything above decides WHERE ash gathers, once, at boot. Everything below
# decides how THICK it is, every frame. The split matters: placement is what the
# goldens and the headless tests pin, and drift must never touch it. A pool's
# recorded placement stays its resting state, and drift is a modulation around
# it whose mean is exactly zero — so the world a test fingerprints is the world
# the player sees at rest.
#
# Drift is DENSITY ONLY. The pool never moves; see the note above
# [method drift_density] for the measurement that settled that.
#
# The ash rides the SAME wind as the scrub — same direction, same phase law,
# read through [Wind] — on its own scale. It is not the same size of thing: a
# blade of grass answers a 9 m gust in a second, while a basin of settled ash is
# tens of metres across and heavy. Giving it the scrub's numbers made it strobe.

## Metres per radian of gust phase for the ash, against the scrub's
## [constant Wind.WAVELENGTH] of 9 m.
##
## Sized to the SPACING of the pools, not to the pools themselves. At the
## scrub's 9 m, two pools [constant MIN_SEPARATION] apart sit 5.1 radians apart
## in phase — effectively unrelated, so each basin pulses on its own clock and
## the Reach reads as several independent effects rather than one weather
## system. At 120 m that same pair is 0.38 rad apart: visibly staggered,
## unmistakably the same gust arriving a moment later.
const DRIFT_WAVELENGTH := 120.0

## Radians per second of gust phase for the ash, against the scrub's 1.35-1.9.
##
## A full swell every ~22 seconds. Slow on purpose, and slower than it sounds:
## the pools are read peripherally while the player crosses the ground between
## them, and anything quick enough to notice directly reads as the fog
## flickering rather than as air moving.
const DRIFT_SPEED := 0.28

## Half-amplitude of the density swell, as a fraction of a pool's placed
## density — so a pool breathes between 0.78x and 1.22x of its resting value.
##
## SYMMETRIC about the resting density, unlike [method Wind.gust]'s biased
## curve. That bias exists so the scrub is only ever pushed downwind; density
## has no direction to be biased toward, and a biased curve would mean the
## density #211 tuned was never the density on screen. The mean here is exactly
## the placed value.
##
## The magnitude is small because fog density is far more sensitive than it
## feels — #211 found a +0.006 change to the environment baseline erased the
## foreground entirely.
const DRIFT_SWING := 0.22

## ⚠️ THE POOL DOES NOT MOVE, AND THAT IS A MEASURED DECISION, not an omission.
##
## The first build of this change also translated each volume 1.6 m along the
## wind and back, on the reasoning that a density field which TRANSLATES reads
## as drifting while one that only varies in place reads as breathing. Rendered
## and measured, that translation turned out to be invisible: against the
## resting frame it moved the image by a mean |dRGB| of 0.0012, where two
## captures of an IDENTICAL fog state differ by up to 0.0115 — eight times more.
## It was inside the noise, so it was doing nothing a player could see.
##
## It could not be rescued by making it larger, either. The separation law caps
## the excursion below 5 m (see [constant MIN_SEPARATION]: fog volumes composite
## by ADDING optical depth, so two pools that approach each other read as one
## sheet at double density), and a pool is 36 m wide with a faded rim — so even
## the largest legal translation is a few percent of the shape being moved.
##
## It was removed rather than kept and explained away. #211 shipped a density
## constant that turned out to be inert for exactly this reason, and a constant
## that does nothing is worse than no constant: it invites a future reader to
## tune it. Real motion WITHIN a pool needs the density field itself to move,
## which is a fog shader sampling noise against time — tracked in #328.

## The pool's density at [param time], modulating [param placed_density].
##
## Pure: a closed-form function of position and time, with no RNG and no state.
## Two calls at the same time and place agree, which is what lets a test assert
## the swell's shape without rendering anything.
static func drift_density(placed_density: float, pos: Vector3, time: float) -> float:
	var at := Wind.phase(pos, DRIFT_WAVELENGTH, DRIFT_SPEED, time)
	return placed_density * (1.0 + DRIFT_SWING * sin(at))


## Re-densifies one built volume for [param time]. Lives here beside
## [method build_volume] for the same reason that does: the shape the player
## sees and the shape the tests reason about must not drift apart.
##
## Note what it does NOT touch: [member Node3D.position]. The volume stays where
## placement put it, so the resting world the goldens and the headless placement
## record describe is the world on screen at every phase but its density.
static func apply_drift(volume: FogVolume, placement: Dictionary, time: float) -> void:
	var mat := volume.material as FogMaterial
	if mat == null:
		return
	var placed_pos: Vector3 = placement["pos"]
	mat.density = drift_density(float(placement["density"]), placed_pos, time)
