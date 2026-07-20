extends Node
## Regression test for issue #282 — ruin and shrine pieces must be SEATED IN the
## terrain, never floating above it.
##
## The law: no piece's lowest point may sit above the lowest walkable surface
## under its own footprint. Seat there and the piece meets the ground on its low
## side and is buried on its high side, which is what "built into the terrain"
## looks like; seat above it and one corner hangs in the air, which is the hard
## intersection seam #225 reports.
##
## Two defects made that happen before this test existed, both measured on the
## shipped seed:
##  1. Placement sampled `height_at` (the smooth analytic noise) while the ground
##     the player sees and collides with is `surface_height_at` (the baked
##     piecewise-linear grid). Mean gap 36 mm, max 166 mm.
##  2. Each piece took ONE sample at its origin. The real surface varies across a
##     piece's own footprint by a mean of 334 mm and a max of 2373 mm, and 88% of
##     pieces exceed 100 mm — so a single sample necessarily left one side up.
##
## The oracle here is INDEPENDENT of the implementation on purpose: it does not
## call `_footprint_half` or `_footprint_ground`. It takes each piece's final
## world-space AABB — the actual rendered extent, after every rotation and
## in-body offset — and sweeps the real surface under that rectangle itself. A
## test that reused the seating helpers would agree with them by construction and
## could not catch a wrong footprint.
##
## Run: godot --headless --path client res://tests/structure_seating_test.tscn

## Pieces may sit BELOW the ground freely (that is the buried side, and the
## deliberate -0.15/-0.3 sinks). This is the tolerance in the FLOAT direction
## only, and it is float noise, NOT a modelling allowance.
##
## It used to be 20 mm, to absorb a real geometric gap: the sweep visited the
## footprint edges and their grid-line crossings, but not the points where a
## quad's SPLIT DIAGONAL meets a footprint edge — so both the seating helper and
## this oracle could miss the same true minimum, and a piece could still float by
## up to ~13 mm. A tolerance that hides a known failure mode is not a tolerance,
## it is the bug with a number written next to it. Both sides now enumerate those
## crossings, so the seat is exact and the only slack needed is arithmetic.
const FLOAT_TOLERANCE := 0.002

## Non-vacuity floor. If the traversal stops finding pieces — a rename, a
## restructure, a filter that silently matches nothing — this test would pass by
## measuring an empty set. The shipped world builds 44 ruin sites plus 7
## monoliths; 150 is a floor well under that and well over zero.
const MIN_PIECES := 150

## The world must actually be UNEVEN under those pieces for the guard to mean
## anything: on dead-flat ground, centre-sampling and footprint-sampling agree
## and a green result would prove nothing. Assert the premise the fix exists for.
const MIN_SPANNING_PIECES := 100
const SPANNING_THRESHOLD := 0.10

func _ready() -> void:
	var w := WorldGen.new()
	add_child(w)

	var checked := 0
	var spanning := 0
	var floating: Array[String] = []
	var worst_float := -INF
	var worst_name := ""

	for site: Node in w.get_children():
		if not _is_generated_site(site):
			continue
		for piece: Node in site.get_children():
			# Only BUILT pieces — the ones carrying collision. The shrine also
			# holds an ember flame, its light and an interact handle, which hover
			# over the pedestal by design; requiring those to meet the ground
			# would be asserting the opposite of what they are for. Collision is
			# the honest structural marker: if the player can walk into it, it
			# has to sit in the ground.
			if not (piece is StaticBody3D):
				continue
			var poly := _world_footprint(piece as Node3D)
			if poly.size() < 3:
				continue
			var ground := _surface_range_under_poly(w, poly)
			if ground == Vector2.ZERO:
				continue # entirely off-grid
			var bottom := _lowest_point(piece as Node3D)
			if bottom == INF:
				continue
			checked += 1
			if ground.y - ground.x > SPANNING_THRESHOLD:
				spanning += 1
			# How far the piece's underside sits ABOVE the lowest ground beneath
			# it. Negative means buried, which is always fine.
			var gap := bottom - ground.x
			if gap > worst_float:
				worst_float = gap
				worst_name = "%s/%s" % [site.name, piece.name]
			if gap > FLOAT_TOLERANCE:
				floating.append("%s/%s floats %d mm" % [site.name, piece.name, int(round(gap * 1000.0))])

	print("SEATING checked=", checked, " spanning=", spanning,
		" worst_float_mm=", int(round(worst_float * 1000.0)), " at ", worst_name)

	if checked < MIN_PIECES:
		_fail("non-vacuity: only %d pieces measured, expected at least %d — the traversal stopped finding them" % [checked, MIN_PIECES])
		return
	if spanning < MIN_SPANNING_PIECES:
		_fail("premise: only %d of %d pieces stand on ground varying more than %d mm across their footprint; on flat ground this guard would prove nothing" % [spanning, checked, int(SPANNING_THRESHOLD * 1000.0)])
		return
	if not floating.is_empty():
		_fail("%d of %d piece(s) float above the walkable surface under their own footprint:\n  %s" % [floating.size(), checked, "\n  ".join(floating)])
		return

	print("TEST PASS")
	get_tree().quit()

func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)

## Ruin sites are scriptless Node3D containers, and the shrine is a named one.
## They CANNOT be matched by name alone: duplicate add_child names uniquify by
## native CLASS (@Node3D@N), so only the FIRST ruin site is called "Ruin".
## world_gen.gd's own foliage keep-out pass uses this same structural filter.
func _is_generated_site(n: Node) -> bool:
	if n.name == "WardensShrine":
		return true
	return n.get_class() == "Node3D" and n.get_script() == null

## A piece's real extent in world space: its mesh AABB carried through its own
## global transform, so rotation and any in-body child offset are included.
## A piece's TRUE footprint in world XZ: the convex hull of its mesh box's eight
## corners carried through its own global transform. NOT the enclosing rectangle
## — a wall rotated off-axis leaves most of that rectangle covering ground the
## wall never stands on, and taking a minimum from there would demand the piece
## sink to meet ground it does not touch.
##
## Derived here from the mesh's global_transform, independently of the
## generator's `_footprint_polygon`, so this oracle cannot inherit a wrong
## footprint from the code it audits.
func _world_footprint(piece: Node3D) -> PackedVector2Array:
	var mi := _mesh_child(piece)
	if mi == null:
		return PackedVector2Array()
	var local := mi.mesh.get_aabb()
	var xf := mi.global_transform
	var pts := PackedVector2Array()
	for i in 8:
		var corner := local.position + Vector3(
			local.size.x * float(i & 1),
			local.size.y * float((i >> 1) & 1),
			local.size.z * float((i >> 2) & 1))
		var v := xf * corner
		pts.append(Vector2(v.x, v.z))
	var hull := Geometry2D.convex_hull(pts)
	return hull if hull.size() >= 3 else PackedVector2Array()

func _mesh_child(piece: Node3D) -> MeshInstance3D:
	for c: Node in piece.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
			return c as MeshInstance3D
	if piece is MeshInstance3D and (piece as MeshInstance3D).mesh != null:
		return piece as MeshInstance3D
	return null

## The piece's lowest world-space point.
func _lowest_point(piece: Node3D) -> float:
	var mi := _mesh_child(piece)
	if mi == null:
		return INF
	return (mi.global_transform * mi.mesh.get_aabb()).position.y

## Lowest and highest walkable surface under a footprint POLYGON, as (low, high).
## Samples the polygon's corners, its edges wherever they cross a grid line or a
## quad's split diagonal (`surface_height_at` splits on `fx >= fz`, i.e. along
## the world lines x - z = k*step), and the grid vertices inside it. Enumerating
## those independently is what stops this oracle sharing a blind spot with the
## code it audits — structural independence is not enough if both omit the same
## candidate.
func _surface_range_under_poly(w: WorldGen, poly: PackedVector2Array) -> Vector2:
	if poly.size() < 3:
		return Vector2.ZERO
	var step := WorldGen.SIZE / WorldGen.QUADS
	var half := WorldGen.SIZE / 2.0
	var pts := PackedVector2Array()
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for p: Vector2 in poly:
		pts.append(p)
		min_x = minf(min_x, p.x); max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.y); max_z = maxf(max_z, p.y)
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		var d := b - a
		if not is_zero_approx(d.x):
			for k in range(ceili((minf(a.x, b.x) + half) / step), floori((maxf(a.x, b.x) + half) / step) + 1):
				var t := (k * step - half - a.x) / d.x
				if t > 0.0 and t < 1.0:
					pts.append(a + d * t)
		if not is_zero_approx(d.y):
			for k in range(ceili((minf(a.y, b.y) + half) / step), floori((maxf(a.y, b.y) + half) / step) + 1):
				var t := (k * step - half - a.y) / d.y
				if t > 0.0 and t < 1.0:
					pts.append(a + d * t)
		var dd := d.x - d.y
		if not is_zero_approx(dd):
			var s0 := a.x - a.y
			var s1 := b.x - b.y
			for k in range(ceili(minf(s0, s1) / step), floori(maxf(s0, s1) / step) + 1):
				var t := (k * step - s0) / dd
				if t > 0.0 and t < 1.0:
					pts.append(a + d * t)
	for ix in range(ceili((min_x + half) / step), floori((max_x + half) / step) + 1):
		for iz in range(ceili((min_z + half) / step), floori((max_z + half) / step) + 1):
			var pt := Vector2(ix * step - half, iz * step - half)
			if Geometry2D.is_point_in_polygon(pt, poly):
				pts.append(pt)
	var lo := INF
	var hi := -INF
	for p: Vector2 in pts:
		var s := w.surface_height_at(p.x, p.y)
		if s <= WorldGen.NO_GROUND + 1.0:
			continue
		lo = minf(lo, s)
		hi = maxf(hi, s)
	if lo > hi:
		return Vector2.ZERO
	return Vector2(lo, hi)
