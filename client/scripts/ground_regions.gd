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
##   2. TRANSITIONS, NOT SEAMS. Within `BLEND_BAND` metres of the line between
##      two regions the two palettes mix, so the change reads as ground giving
##      way to other ground rather than a cut in the terrain.
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
## They differ in HUE and in VALUE, not just brightness — the art direction is
## explicit that value alone separating a scene is what makes it read flat.
## They stay inside the world's register: this is a burned world, so nothing
## here is saturated or fresh.
const REGIONS: Array[Dictionary] = [
	{
		# The baseline Ashfall ground. Unchanged from the pre-region palette,
		# so the shrine and the frames already captured there still read as
		# themselves.
		&"name": &"ashflats",
		&"ash": Color(0.38, 0.345, 0.31),
		&"rock": Color(0.24, 0.22, 0.21),
		&"scorch": Color(0.16, 0.14, 0.13),
	},
	{
		# Where the burn sat longest: darker, and warm rather than neutral.
		&"name": &"cinderreach",
		&"ash": Color(0.31, 0.245, 0.205),
		&"rock": Color(0.21, 0.165, 0.145),
		&"scorch": Color(0.13, 0.095, 0.085),
	},
	{
		# Ash scoured off down to the pale stone beneath: lighter, and cool
		# against everything else here.
		&"name": &"bonepale",
		&"ash": Color(0.46, 0.445, 0.42),
		&"rock": Color(0.33, 0.325, 0.32),
		&"scorch": Color(0.21, 0.20, 0.20),
	},
	{
		# Ground stained by the inherited machines rusting into it — ochre,
		# the one region whose colour the world did not make itself.
		&"name": &"rustmoor",
		&"ash": Color(0.40, 0.32, 0.22),
		&"rock": Color(0.27, 0.205, 0.14),
		&"scorch": Color(0.17, 0.13, 0.10),
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


## The region owning a place, and how strongly it owns it.
##
## Returns `{ region, neighbour, blend }` where `blend` is 0 at the boundary
## with `neighbour` and 1 once the place is `BLEND_BAND` metres clear of it.
## Callers that only want the answer can read `region`; callers drawing the
## ground use `blend` to cross-fade.
## `region_sites` is passed in rather than rebuilt per call: the terrain grid
## asks about ~16k places, and rebuilding nine sites for each of them would
## allocate its way through the whole bake for no reason. The seed/extent
## wrappers below are the convenience form for tests and one-off queries.
static func region_for(region_sites: Array[Site], x: float, z: float) -> Dictionary:
	var best := -1
	var best_d := INF
	var second := -1
	var second_d := INF
	for i in region_sites.size():
		var s := region_sites[i]
		var dx := x - s.x
		var dz := z - s.z
		var d := sqrt(dx * dx + dz * dz)
		if d < best_d:
			second = best
			second_d = best_d
			best = i
			best_d = d
		elif d < second_d:
			second = i
			second_d = d
	var owner: int = region_sites[best].region
	var other: int = region_sites[second].region if second >= 0 else owner
	# Distance-difference, not raw distance: it is 0 exactly on the bisector
	# between the two nearest sites and grows as the place commits to one.
	var blend := 1.0
	if second >= 0:
		blend = clampf((second_d - best_d) / BLEND_BAND, 0.0, 1.0)
	# Two sites of the SAME region meeting is not a boundary — there is
	# nothing to cross-fade to, and treating it as one would put a seam of
	# half-strength palette through the middle of a single region.
	if other == owner:
		blend = 1.0
	return {&"region": owner, &"neighbour": other, &"blend": blend}


## The ground palette at a place: `{ ash, rock, scorch }`, already cross-faded
## across a boundary. This is the whole interface the world generator needs.
static func palette_for(region_sites: Array[Site], x: float, z: float) -> Dictionary:
	var at := region_for(region_sites, x, z)
	var a: Dictionary = REGIONS[at[&"region"]]
	var b: Dictionary = REGIONS[at[&"neighbour"]]
	var blend: float = at[&"blend"]
	if blend >= 1.0 or a == b:
		return {&"ash": a[&"ash"], &"rock": a[&"rock"], &"scorch": a[&"scorch"]}
	# Half-way at the boundary: `blend` runs 0..1, and a place exactly on the
	# line is an even mix of the two grounds meeting there.
	var t := (1.0 - blend) * 0.5
	var ash: Color = a[&"ash"]
	var rock: Color = a[&"rock"]
	var scorch: Color = a[&"scorch"]
	return {
		&"ash": ash.lerp(b[&"ash"], t),
		&"rock": rock.lerp(b[&"rock"], t),
		&"scorch": scorch.lerp(b[&"scorch"], t),
	}


## Convenience wrappers: build the sites, then ask. For tests, evidence and
## any caller with a single question — never for a bake loop.
static func region_at(world_seed: int, extent: float, x: float, z: float) -> Dictionary:
	return region_for(sites(world_seed, extent), x, z)


static func palette_at(world_seed: int, extent: float, x: float, z: float) -> Dictionary:
	return palette_for(sites(world_seed, extent), x, z)


## The name of the region owning a place. For logs, tests and evidence.
static func region_name(world_seed: int, extent: float, x: float, z: float) -> StringName:
	return REGIONS[region_at(world_seed, extent, x, z)[&"region"]][&"name"]
