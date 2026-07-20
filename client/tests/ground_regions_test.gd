extends Node

## Guards for [GroundRegions] — the ground's regional palette.
##
## This suite exists because the world determinism golden CANNOT cover it.
## `world_gen_determinism_test._world_fingerprint` hashes heights, node
## transforms and mesh vertices; it never reads vertex COLOUR. A region layout
## could therefore drift, or stop being seeded at all, and that golden would
## stay green. So the region field carries its own golden here.
##
## The laws, one arm each:
##   1. DETERMINISM — the same seed gives the same regions, twice over and
##      against a recorded golden.
##   2. COVERAGE — every named region actually appears in the world. Variety
##      that a seed can silently delete is not variety.
##   3. DECIDED INTERIORS — away from a boundary a place is its region
##      outright. This is the law that separates regions from a blend.
##   4. TRANSITIONS — a boundary crossing is gradual, and a blended palette
##      stays between the two grounds meeting there.
##   5. THE SHRINE'S GROUND IS PINNED — the origin is always `ashflats`.
##   6. SPREAD — sites cannot collapse into a clump.

const SEED := 1409
const EXTENT := 220.0

## Recorded from a headless run; regenerate deliberately by setting this to
## "__RECORD__", running the test and committing the printed value. A change
## here means the ground people walk on changed, which is a reviewed act.
const GOLDEN_REGION_FIELD := "9bb0ddab"

var _failures: Array[String] = []


func _ready() -> void:
	_test_determinism_and_golden()
	_test_every_region_appears()
	_test_interiors_are_decided()
	_test_boundaries_transition()
	_test_palette_is_continuous()
	_test_regions_differ_as_substances()
	_test_origin_is_ashflats()
	_test_sites_are_spread()
	_test_extent_scales_with_the_world()

	if _failures.is_empty():
		print("TEST PASS: ground_regions")
	else:
		for f in _failures:
			printerr("FAIL: %s" % f)
		printerr("TEST FAIL: ground_regions (%d)" % _failures.size())
	get_tree().quit(0 if _failures.is_empty() else 1)


func _fail(msg: String) -> void:
	_failures.append(msg)


## A coarse fingerprint of the whole region field: the region index at every
## node of a 48x48 lattice over the world. Coarser than the terrain grid on
## purpose — it is pinning WHICH GROUND IS WHERE, not per-vertex colour.
func _region_field(world_seed: int) -> String:
	var acc := PackedInt32Array()
	var region_sites := GroundRegions.sites(world_seed, EXTENT)
	var steps := 48
	for iz in steps:
		for ix in steps:
			var x := (float(ix) / float(steps - 1) - 0.5) * EXTENT
			var z := (float(iz) / float(steps - 1) - 0.5) * EXTENT
			var at := GroundRegions.region_for(region_sites, x, z)
			acc.append(at[&"region"])
			# Quantised blend too, so a change to the transition width is a
			# reviewed act rather than an invisible one.
			acc.append(roundi(float(at[&"blend"]) * 1000.0))
	return "%x" % hash(acc)


func _test_determinism_and_golden() -> void:
	var a := _region_field(SEED)
	var b := _region_field(SEED)
	if a != b:
		_fail("region field is not deterministic within a run: %s != %s" % [a, b])
		return
	if GOLDEN_REGION_FIELD == "__RECORD__":
		print("RECORDED region field golden: %s" % a)
		return
	if a != GOLDEN_REGION_FIELD:
		_fail("region field %s != golden %s — the ground's regions changed (intended? update the golden) or a boot-varying source crept in" %
			[a, GOLDEN_REGION_FIELD])

	# A DIFFERENT seed must give a different world. Without this the golden
	# would still pass if the layout stopped depending on the seed entirely
	# (every site pinned to its cell centre with one hard-coded region), which
	# is exactly the silent failure "it's deterministic!" can hide.
	if _region_field(SEED + 1) == a:
		_fail("a different seed produced an identical region field — layout is not seeded")


func _test_every_region_appears() -> void:
	var seen := {}
	var region_sites := GroundRegions.sites(SEED, EXTENT)
	for s in region_sites:
		seen[s.region] = true
	for i in GroundRegions.REGIONS.size():
		if not seen.has(i):
			var name_i: StringName = GroundRegions.REGIONS[i][&"name"]
			_fail("region '%s' appears nowhere in the world — variety a seed can delete is not variety" % name_i)

	# The guarantee must hold for ANY seed, not just the shipped one: the
	# assignment is built from a cycling multiset precisely so it cannot fail.
	# Sampling a spread of seeds is what proves that construction, rather than
	# the shipped seed happening to be lucky.
	for extra in range(1, 40):
		var seen_extra := {}
		for s in GroundRegions.sites(SEED + extra * 37, EXTENT):
			seen_extra[s.region] = true
		if seen_extra.size() != GroundRegions.REGIONS.size():
			_fail("seed %d yields only %d of %d regions — the coverage guarantee is not structural" %
				[SEED + extra * 37, seen_extra.size(), GroundRegions.REGIONS.size()])
			return


## Away from a boundary, a place must be its region OUTRIGHT — the returned
## palette identical to the region's own colours, not a mix of neighbours.
##
## This is the law that makes these regions rather than a smooth field. Its
## negative control is `_test_boundaries_transition` below: if everything were
## blended everywhere, this arm fails; if nothing ever blended, that one does.
func _test_interiors_are_decided() -> void:
	var region_sites := GroundRegions.sites(SEED, EXTENT)
	var checked := 0
	for s in region_sites:
		# A site itself is the deepest interior point of its own cell.
		var at := GroundRegions.region_for(region_sites, s.x, s.z)
		if at[&"region"] != s.region:
			_fail("a site at (%.1f, %.1f) does not belong to its own region" % [s.x, s.z])
			continue
		var blend: float = at[&"blend"]
		if blend < 1.0:
			_fail("site (%.1f, %.1f) is not fully decided (blend %.3f) — its own centre is being cross-faded" %
				[s.x, s.z, blend])
			continue
		var pal := GroundRegions.palette_for(region_sites, s.x, s.z)
		var own: Dictionary = GroundRegions.REGIONS[s.region]
		var got: Color = pal[&"ash"]
		var want: Color = own[&"ash"]
		if not got.is_equal_approx(want):
			_fail("site (%.1f, %.1f) palette %s is not its region's own %s" % [s.x, s.z, got, want])
			continue
		checked += 1
	if checked == 0:
		_fail("no interior point was actually checked — this arm proved nothing")


## Crossing between two DIFFERENT regions must blend, and the blended palette
## must stay between the two grounds meeting there — never introduce a third
## colour, and never overshoot past either neighbour.
func _test_boundaries_transition() -> void:
	var region_sites := GroundRegions.sites(SEED, EXTENT)
	# Find a pair of adjacent sites declaring different regions, and walk the
	# straight line between them.
	var found_blend := false
	var saw_both_ends := false
	for i in region_sites.size():
		for j in range(i + 1, region_sites.size()):
			var a := region_sites[i]
			var b := region_sites[j]
			if a.region == b.region:
				continue
			var first: int = -1
			var last: int = -1
			var min_blend := 1.0
			for step in 201:
				var t := float(step) / 200.0
				var x := lerpf(a.x, b.x, t)
				var z := lerpf(a.z, b.z, t)
				var at := GroundRegions.region_for(region_sites, x, z)
				var here: int = at[&"region"]
				if first < 0:
					first = here
				last = here
				min_blend = minf(min_blend, float(at[&"blend"]))

				# The palette anywhere on this walk must stay inside the box
				# spanned by the two end regions' colours (per channel), with a
				# small tolerance. A value outside it means the cross-fade
				# invented a ground that is not there.
				# Only where these two are the ONLY competitors: near a triple
				# point a third region legitimately contributes, and demanding
				# the two-region box there would fail correct output.
				var shares: PackedFloat32Array = at[&"shares"]
				var only_these := true
				for rr in GroundRegions.REGIONS.size():
					if rr != a.region and rr != b.region and shares[rr] > 0.0:
						only_these = false
						break
				if only_these:
					var pal := GroundRegions.palette_for(region_sites, x, z)
					var ca: Color = GroundRegions.REGIONS[a.region][&"ash"]
					var cb: Color = GroundRegions.REGIONS[b.region][&"ash"]
					var got: Color = pal[&"ash"]
					for ch in 3:
						var lo := minf(ca[ch], cb[ch]) - 0.002
						var hi := maxf(ca[ch], cb[ch]) + 0.002
						if got[ch] < lo or got[ch] > hi:
							_fail("at (%.1f, %.1f) channel %d = %.4f falls outside the two neighbouring grounds [%.4f, %.4f]" %
								[x, z, ch, got[ch], lo, hi])
							return
			if first != last:
				saw_both_ends = true
			if min_blend < 0.999:
				found_blend = true
			if saw_both_ends and found_blend:
				# `blend` is the OWNER'S SHARE now: 1.0 fully decided, 0.5 an even
				# two-way meeting. It must fall to about a half, not to zero.
				if min_blend > 0.6:
					_fail("crossing a boundary never reached a near-even mix (owner share stayed %.3f) — the change is a seam, not a transition" % min_blend)
				return
	if not saw_both_ends:
		_fail("no walk between two different regions was found — this arm proved nothing")
	elif not found_blend:
		_fail("crossing between two regions never blended at all — boundaries are hard seams")


## The ground palette must be CONTINUOUS everywhere — no step, anywhere, ever.
##
## This arm exists because the first implementation cross-faded the owner only
## against its second-nearest site, which put a hard seam wherever the SECOND
## site's identity changed while the owner stayed put. It measured **0.185 in a
## single step at (49.6, 34.0)** on the shipped seed — larger than the gap
## between some whole regions — and every other arm here passed it, because a
## site-to-site walk never crosses the place where the THIRD site takes over.
## Walking dense lines and bounding the step size is what catches that class.
func _test_palette_is_continuous() -> void:
	var region_sites := GroundRegions.sites(SEED, EXTENT)
	# A step this small can only legitimately change the palette by roughly
	# (widest palette gap) * step / BLEND_BAND ~= 0.002. The threshold sits an
	# order of magnitude above that and still an order BELOW the 0.185 seam the
	# old blend produced, so it cannot be satisfied by tuning.
	var step := 0.05
	var max_step_change := 0.01
	var worst := 0.0
	var worst_at := Vector2.ZERO
	# Sweep a lattice of lines rather than one: a single line can miss a triple
	# point, which is exactly where the defect lived.
	for line in 24:
		var z := (float(line) / 23.0 - 0.5) * (EXTENT - 8.0)
		var prev := Color(0, 0, 0)
		var first := true
		var x := -EXTENT * 0.5 + 4.0
		while x <= EXTENT * 0.5 - 4.0:
			var pal := GroundRegions.palette_for(region_sites, x, z)
			var c: Color = pal[&"ash"]
			if not first:
				var d := maxf(maxf(absf(c.r - prev.r), absf(c.g - prev.g)), absf(c.b - prev.b))
				if d > worst:
					worst = d
					worst_at = Vector2(x, z)
			prev = c
			first = false
			x += step
	if worst > max_step_change:
		_fail("the ground palette jumps %.4f in a single %.2f m step at (%.1f, %.1f) — that is a seam, not a transition" %
			[worst, step, worst_at.x, worst_at.y])


## A region must be a SUBSTANCE, not a tint: the regions have to differ in how
## they answer light, not only in colour. Without this, flattening every
## `rough` to the same value would leave four paints on one material and no
## other arm here would notice.
func _test_regions_differ_as_substances() -> void:
	var seen := {}
	var lo := INF
	var hi := -INF
	for r in GroundRegions.REGIONS:
		var rough: float = r[&"rough"]
		seen[rough] = true
		lo = minf(lo, rough)
		hi = maxf(hi, rough)
	if seen.size() < 3:
		_fail("only %d distinct roughness values across %d regions — the regions are tints of one material" %
			[seen.size(), GroundRegions.REGIONS.size()])
	# Wide enough to survive the shader's own grain term (+-0.03) and still read.
	if hi - lo < 0.08:
		_fail("roughness spread is only %.3f — too narrow to separate the grounds as substances" % (hi - lo))
	# And the blend must carry it: a place between two regions takes a
	# roughness between theirs, or the colour and the surface disagree.
	var region_sites := GroundRegions.sites(SEED, EXTENT)
	for s in region_sites:
		var pal := GroundRegions.palette_for(region_sites, s.x, s.z)
		var want: float = GroundRegions.REGIONS[s.region][&"rough"]
		var got: float = pal[&"rough"]
		if absf(got - want) > 1e-5:
			_fail("site (%.1f, %.1f) reports roughness %.4f, not its region's %.4f" % [s.x, s.z, got, want])
			return


func _test_origin_is_ashflats() -> void:
	var got := GroundRegions.region_name(SEED, EXTENT, 0.0, 0.0)
	if got != &"ashflats":
		_fail("the shrine's ground is '%s', not 'ashflats' — the opening shot got reskinned" % got)
	# Must hold for any seed: the origin cell is pinned by construction.
	for extra in range(1, 25):
		var s := SEED + extra * 53
		var n := GroundRegions.region_name(s, EXTENT, 0.0, 0.0)
		if n != &"ashflats":
			_fail("seed %d puts '%s' on the shrine — the origin pin is not structural" % [s, n])
			return


## Sites come from a jittered grid so they cannot clump. Free scatter can leave
## a whole quarter of the world with no site of its own, which is how a region
## silently stops existing on the ground even while it exists in the list.
func _test_sites_are_spread() -> void:
	var region_sites := GroundRegions.sites(SEED, EXTENT)
	if region_sites.size() != GroundRegions.SITE_COUNT:
		_fail("expected %d sites, got %d" % [GroundRegions.SITE_COUNT, region_sites.size()])
		return
	var cell := EXTENT / float(GroundRegions.GRID)
	# JITTER < 0.5 means two sites can approach no closer than the gap between
	# their cell centres minus the two jitters.
	var floor_sep := cell * (1.0 - 2.0 * GroundRegions.JITTER)
	for i in region_sites.size():
		for j in range(i + 1, region_sites.size()):
			var a := region_sites[i]
			var b := region_sites[j]
			var d := Vector2(a.x - b.x, a.z - b.z).length()
			if d < floor_sep:
				_fail("sites %d and %d are %.2f m apart, closer than the %.2f m the grid guarantees" %
					[i, j, d, floor_sep])
				return
	# Every site must land inside the world.
	for s in region_sites:
		if absf(s.x) > EXTENT * 0.5 or absf(s.z) > EXTENT * 0.5:
			_fail("site at (%.1f, %.1f) lies outside the %.0f m world" % [s.x, s.z, EXTENT])
			return


## The layout is expressed in world metres, so a different world size must move
## the sites with it. Pins that `extent` is genuinely load-bearing rather than
## an ignored parameter that happens to be passed the right number today.
func _test_extent_scales_with_the_world() -> void:
	var small := GroundRegions.sites(SEED, EXTENT * 0.5)
	var big := GroundRegions.sites(SEED, EXTENT)
	if small.size() != big.size():
		_fail("changing extent changed the site count")
		return
	for i in small.size():
		if is_equal_approx(small[i].x, big[i].x) and is_equal_approx(small[i].z, big[i].z):
			_fail("site %d did not move when the world halved — extent is not load-bearing" % i)
			return
		if small[i].region != big[i].region:
			_fail("site %d changed region when only the world SIZE changed" % i)
			return
