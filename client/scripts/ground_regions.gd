class_name GroundRegions
extends RefCounted

## The Reach's ground regions: what the ground is MADE OF, decided per place.
##
## Before this, the whole 220 m world drew from one three-colour palette, so
## walking 200 m changed nothing about the ground. The fix the art direction
## asks for (docs/art-direction/README.md) is not more noise — it is for the
## generator to make DECISIONS. So the world is partitioned into a handful of
## named regions, each with its own palette, and a place belongs to exactly
## one of them.
##
## Two properties are deliberate:
##
##   1. DECIDED INTERIORS. Away from a boundary a place is its region's palette
##      outright, not a blend of everything nearby. A continuous blend of four
##      palettes is just the old uniform field with extra steps.
##   2. TRANSITIONS, NOT SEAMS. Within `BLEND_BAND` metres of a boundary the
##      competing palettes mix, so the change reads as ground giving way to
##      other ground rather than a cut in the terrain. This holds EVERYWHERE,
##      including where three regions meet — see `region_for` for why that took
##      weighting every region rather than only the runner-up.
##
## A region is a SUBSTANCE, not a tint: each carries its own roughness as well
## as its own colours, so scoured stone answers the low sun differently from
## loose ash. Colour alone would have made them one material in four paints.
##
## Everything here is integer-hash derived from the world seed: no `randf()`,
## no `FastNoiseLite`, no static mutable state. The same seed gives the same
## regions on every boot and every platform, which `ground_regions_test.gd`
## pins with its own golden — the world determinism golden cannot do it,
## because that fingerprint hashes geometry and never looks at vertex colour.

## Sites are placed one per cell of a GRID x GRID jittered grid. A jittered
## grid rather than free scatter because free scatter clumps, and a clump
## leaves part of the world with no region of its own — the very defect this
## is fixing.
const GRID := 3
const SITE_COUNT := GRID * GRID

## How far from a region boundary the two palettes are still mixing, in metres.
## Wide enough to read as ground changing underfoot at walking pace, narrow
## against the ~73 m cells so interiors stay decided.
const BLEND_BAND := 9.0

## How far a site may wander from its cell centre, as a fraction of the cell.
## Below 0.5 so cells cannot swap places and the grid's spread guarantee holds.
const JITTER := 0.34

## The palettes. Each region names a substance and states it in three colours,
## matching the layers `_ground_color` already blends: ash on the flats, rock
## where height exposes it, scorch in the sheltered lows.
##
## They stay inside the world's register — this is a burned world, so nothing
## here is saturated or fresh — but the SEPARATION between them is much wider
## than it looks on paper, and that is measured rather than taste.
##
## The Reach is lit by a low orange sun through heavy haze, and both multiply
## every surface toward the same warm value. A first pass at this used gentle,
## tasteful differences (ash values spanning 0.26-0.44 luma) and rendered as
## ONE uniform ochre wash: the regions were reaching the screen correctly and
## were still invisible. A control that swapped the palettes for saturated
## primaries proved the path was sound and the differences merely too small.
##
## Two consequences that will outlive these particular numbers:
##
##   * SEPARATE BY VALUE FIRST. Hue is what this atmosphere eats. `rustmoor`
##     is the hardest region to read precisely because ochre sits closest to
##     the sun's own colour, so it is pitched darker than `ashflats` rather
##     than merely more orange.
##   * THIS READS UNDERFOOT, NOT ACROSS THE WORLD — and the atmosphere eats
##     most of it. Measured against the same cameras on the pre-region build:
##     standing ON the bonepale moved the frame by 0.034 luma (a 16% relative
##     change), while looking ACROSS a boundary twenty metres out moved it by
##     0.013, and the original distance vantages by 0.010 with under half a
##     degree of hue. The baked vertex colours span a 3.1x luma range
##     (cinderreach 0.140 to bonepale 0.437), so roughly a THIRD of the
##     difference reaches the screen; the low sun, the haze and the exposure
##     take the rest.
##
##     That ceiling is not something a palette can fix — pushing the colours
##     far enough to beat it would leave the world's register entirely. It is
##     tracked separately, and it bounds what any ground-colour work here can
##     deliver until it moves.
const REGIONS: Array[Dictionary] = [
	{
		# The baseline Ashfall ground. Unchanged from the pre-region palette,
		# so the shrine and the frames already captured there still read as
		# themselves.
		&"name": &"ashflats",
		&"ash": Color(0.38, 0.345, 0.31),
		&"rock": Color(0.24, 0.22, 0.21),
		&"scorch": Color(0.16, 0.14, 0.13),
		# Loose ash: the baseline surface, and the roughest ground here.
		&"rough": 0.0,
	},
	{
		# Where the burn sat longest: much darker, and warm rather than neutral.
		&"name": &"cinderreach",
		&"ash": Color(0.24, 0.155, 0.125),
		&"rock": Color(0.15, 0.10, 0.08),
		&"scorch": Color(0.10, 0.065, 0.05),
		# Fire-fused crust: slightly slicker than loose ash.
		&"rough": -0.06,
	},
	{
		# Ash scoured off down to the pale stone beneath: much lighter, and the
		# only cool ground in the Reach.
		&"name": &"bonepale",
		&"ash": Color(0.55, 0.545, 0.525),
		&"rock": Color(0.35, 0.345, 0.33),
		&"scorch": Color(0.23, 0.23, 0.22),
		# Scoured stone, wind-polished: the least rough ground in the Reach.
		&"rough": -0.14,
	},
	{
		# Ground stained by the inherited machines rusting into it — ochre, the
		# one colour the world did not make itself. Ochre sits close to this
		# world's sun, so hue alone cannot carry it (measured — see the note on
		# separation below): it is pitched DARKER than the ashflats so value
		# does the separating.
		&"name": &"rustmoor",
		&"ash": Color(0.42, 0.275, 0.135),
		&"rock": Color(0.27, 0.175, 0.085),
		&"scorch": Color(0.18, 0.115, 0.055),
		# Corroded, pitted ground: rougher even than the ash.
		&"rough": 0.05,
	},
]

## The cell holding the world origin, which is where the shrine stands. Pinned
## to `ashflats` so the starting ground is the established one and a re-seed
## can never reskin the opening shot.
const ORIGIN_CELL := (GRID * GRID) / 2


## A region site: its position in world metres and which region it declares.
class Site:
	extends RefCounted
	var x: float
	var z: float
	var region: int

	func _init(px: float, pz: float, r: int) -> void:
		x = px
		z = pz
		region = r


## 32-bit integer avalanche (Murmur-style finaliser). Used instead of any
## engine RNG so region layout is reproducible across boots and platforms by
## construction rather than by hoping a generator is stable.
static func _hash_u32(value: int) -> int:
	var x := value & 0xFFFFFFFF
	x = ((x ^ (x >> 16)) * 0x7feb352d) & 0xFFFFFFFF
	x = ((x ^ (x >> 15)) * 0x846ca68b) & 0xFFFFFFFF
	x = (x ^ (x >> 16)) & 0xFFFFFFFF
	return x


## `_hash_u32` mapped to [0, 1).
static func _unit(value: int) -> float:
	return float(_hash_u32(value)) / 4294967296.0


## Which region each site declares.
##
## Built from a fixed multiset that cycles through every region, then shuffled,
## so EVERY region is guaranteed to appear somewhere in the world. Drawing each
## site's region independently would let a seed produce a world missing one
## entirely — variety left to chance is what this is replacing.
static func _region_assignment(world_seed: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in SITE_COUNT:
		out.append(i % REGIONS.size())
	# Fisher-Yates, hashed. Descending so each draw is over a shrinking range.
	for i in range(SITE_COUNT - 1, 0, -1):
		var j := int(_unit(world_seed * 7919 + i * 104729 + 17) * float(i + 1))
		j = clampi(j, 0, i)
		var tmp := out[i]
		out[i] = out[j]
		out[j] = tmp
	# The shrine's ground is not up for grabs: whatever landed on the origin
	# cell trades places with the ashflats site, preserving the multiset (and
	# so the guarantee that every region still appears).
	if out[ORIGIN_CELL] != 0:
		for i in SITE_COUNT:
			if out[i] == 0:
				out[i] = out[ORIGIN_CELL]
				out[ORIGIN_CELL] = 0
				break
	return out


## The region sites for a seed, over a world `extent` metres on a side and
## centred on the origin. Ordered by cell index, so site N is always cell N.
static func sites(world_seed: int, extent: float) -> Array[Site]:
	var out: Array[Site] = []
	var regions := _region_assignment(world_seed)
	var cell := extent / float(GRID)
	for iz in GRID:
		for ix in GRID:
			var index := iz * GRID + ix
			# Cell centre, then jittered inside the cell.
			var cx := (float(ix) + 0.5) * cell - extent * 0.5
			var cz := (float(iz) + 0.5) * cell - extent * 0.5
			var jx := (_unit(world_seed * 2654435761 + index * 2 + 1) - 0.5) * 2.0 * JITTER * cell
			var jz := (_unit(world_seed * 2654435761 + index * 2 + 2) - 0.5) * 2.0 * JITTER * cell
			out.append(Site.new(cx + jx, cz + jz, regions[index]))
	return out


## How strongly each region competes for a place.
##
## Returns `{ region, neighbour, blend, shares }`:
##   * `region`    — the region owning the place (the nearest site's).
##   * `neighbour` — the strongest region that is NOT the owner, or the owner
##     itself where nothing else competes. For tests and evidence.
##   * `blend`     — the owner's share, in (0, 1]. **1.0 means fully decided**;
##     0.5 is an even two-way meeting; lower where three regions meet.
##   * `shares`    — the normalised weight of every region, indexed like REGIONS.
##
## 🔴 EVERY competing region is weighted, not just the runner-up, and that is a
## correctness requirement rather than a refinement. Cross-fading the owner only
## against its SECOND-nearest site puts a hard seam wherever the *second* site's
## identity changes while the owner stays put: the mix jumps from one palette to
## another in a single step. Not hypothetical — on the shipped seed that
## produced a **0.185 one-step colour jump at (49.6, 34.0)**, larger than the gap
## between some whole regions, and it survived every site-to-site walk a test
## could take because the discontinuity lies where the THIRD site takes over.
## `ground_regions_test._test_palette_is_continuous` now RED-proves it.
##
## Weighting every region removes it by construction: a region's weight falls
## continuously to zero as it stops competing, so no region can appear or vanish
## in a step. Taking the MAX weight per region (not the sum) is what makes two
## sites of the same region meeting a non-event — the owner keeps weight 1 and
## the place stays decided, with no special case needed.
##
## `region_sites` is passed in rather than rebuilt per call: the terrain grid
## asks about ~16k places, and rebuilding nine sites for each of them would
## allocate its way through the whole bake for no reason. The seed/extent
## wrappers below are the convenience form for tests and one-off queries.
static func region_for(region_sites: Array[Site], x: float, z: float) -> Dictionary:
	var dists := PackedFloat32Array()
	var nearest := -1
	var nearest_d := INF
	for i in region_sites.size():
		var s := region_sites[i]
		var dx := x - s.x
		var dz := z - s.z
		var d := sqrt(dx * dx + dz * dz)
		dists.append(d)
		if d < nearest_d:
			nearest_d = d
			nearest = i

	# Per-region weight: 1 for the nearest site, falling linearly to 0 for a
	# site a full BLEND_BAND further away. Continuous in position, so the mix is.
	var weights := PackedFloat32Array()
	for _r in REGIONS.size():
		weights.append(0.0)
	for i in region_sites.size():
		var w := 1.0 - (dists[i] - nearest_d) / BLEND_BAND
		if w <= 0.0:
			continue
		var r: int = region_sites[i].region
		if w > weights[r]:
			weights[r] = w

	var total := 0.0
	for r in REGIONS.size():
		total += weights[r]

	var owner: int = region_sites[nearest].region
	var shares := PackedFloat32Array()
	var other := owner
	var other_w := 0.0
	for r in REGIONS.size():
		shares.append(weights[r] / total)
		if r != owner and weights[r] > other_w:
			other_w = weights[r]
			other = r
	return {
		&"region": owner,
		&"neighbour": other,
		&"blend": shares[owner],
		&"shares": shares,
	}


## The ground palette at a place: `{ ash, rock, scorch, rough }`, already
## cross-faded across every region competing for it. The whole interface the
## world generator needs.
static func palette_for(region_sites: Array[Site], x: float, z: float) -> Dictionary:
	var at := region_for(region_sites, x, z)
	var shares: PackedFloat32Array = at[&"shares"]
	var owner: int = at[&"region"]
	if at[&"blend"] >= 1.0:
		var only: Dictionary = REGIONS[owner]
		return {
			&"ash": only[&"ash"],
			&"rock": only[&"rock"],
			&"scorch": only[&"scorch"],
			&"rough": only[&"rough"],
		}
	var ash := Color(0.0, 0.0, 0.0)
	var rock := Color(0.0, 0.0, 0.0)
	var scorch := Color(0.0, 0.0, 0.0)
	var rough := 0.0
	for r in REGIONS.size():
		var w := shares[r]
		if w <= 0.0:
			continue
		var reg: Dictionary = REGIONS[r]
		var a: Color = reg[&"ash"]
		var k: Color = reg[&"rock"]
		var s: Color = reg[&"scorch"]
		ash += a * w
		rock += k * w
		scorch += s * w
		rough += float(reg[&"rough"]) * w
	return {&"ash": ash, &"rock": rock, &"scorch": scorch, &"rough": rough}


## Convenience wrappers: build the sites, then ask. For tests, evidence and
## any caller with a single question — never for a bake loop.
static func region_at(world_seed: int, extent: float, x: float, z: float) -> Dictionary:
	return region_for(sites(world_seed, extent), x, z)


static func palette_at(world_seed: int, extent: float, x: float, z: float) -> Dictionary:
	return palette_for(sites(world_seed, extent), x, z)


## The name of the region owning a place. For logs, tests and evidence.
static func region_name(world_seed: int, extent: float, x: float, z: float) -> StringName:
	return REGIONS[region_at(world_seed, extent, x, z)[&"region"]][&"name"]
