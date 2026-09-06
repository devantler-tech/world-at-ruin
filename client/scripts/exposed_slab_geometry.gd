class_name ExposedSlabGeometry
extends RefCounted
## Batched raised tops and closed lip faces for the opt-in exposed-stone slab
## field (#547, ADR 0001).
##
## The terrain shader paints the slabs; this gives them THICKNESS. Every slab the
## deterministic [ExposedSlabField] decides is stone AND exposed contributes a
## top polygon lifted a few centimetres above the walkable ground and a ring of
## side faces that close the lip and bury their lower edge in the ash. All of it
## is packed into ONE static `ArrayMesh` surface that shares the terrain's own
## `ShaderMaterial`: the shader derives plate identity, substance and exposure
## from world position, so a lifted top renders as the same slab the ground
## beneath it would have — no per-slab node, material or draw call exists.
##
## Tops conform to the ground EXACTLY rather than approximately. The walkable
## terrain is piecewise linear — one plane per terrain triangle, creased along
## every grid line and every quad diagonal — and a slab (about 1.2 m) is smaller
## than a terrain quad (1.72 m), so a polygon routinely straddles a crease. A
## single fan over the polygon would then sit above the ground on one side of
## the crease and dip into it on the other. So each polygon is first split by the
## grid lines and diagonals it crosses; every piece lies inside one terrain
## triangle, where the ground is one plane, and lifting each vertex by the slab's
## thickness lifts the whole piece by exactly that much. Side strips are split
## at the same crossings so their bottom edge follows the ground rather than
## cutting a chord through it.
##
## Render-only and default-off. With `WAR_GROUND_PLATES` unset nothing here
## runs; with it set the base terrain, its collision, world height, cave and
## foliage placement are untouched, because this only ADDS an overlay above the
## ground. Collision for the raised tops is #548, and until it lands a walking
## player's feet still stand on the base ground beneath a lifted top.

## Thickness range of a slab lip, metres. The lower bound is what a standing
## player reads as a step in stone rather than a paint edge at walking distance;
## the upper bound keeps the tallest lip under the height a sole would catch on
## before #548 gives the top collision.
const MIN_THICKNESS := 0.06
const MAX_THICKNESS := 0.14
## How far below the ground a side face reaches, metres. The bottom edge is
## buried, so the seam where stone meets ash is the ground's own contact line and
## never an open gap under the lip.
const SKIRT := 0.10
## Polygons are clipped this far inside the terrain square so every generated
## vertex has real ground under it: `surface_height_at` answers NO_GROUND on the
## far side of the last row of vertices.
const WORLD_INSET := 0.001
## Share of a slab's polygon corners that must ALSO be exposed before it is lifted,
## on top of its site. The shader decides exposure per fragment, so the ash sheet's
## contact routinely crosses a 1.2 m slab, and a slab lifted with ash still painted
## over most of its top reads as a raised drift rather than stone. Judged on the
## close-range frames in `docs/evidence/issue-547-ground-plate-geometry/`: at 1.0
## (every corner exposed) 439 slabs lift and read as sparse random tiles, at 0.0
## (site only) 5,424 lift and the mid-field starts to pave, at 0.5 about 3,400
## lift and the slope reads as scattered broken slabs. Halfway is the decision.
const MIN_EXPOSED_CORNER_SHARE := 0.5
## Explicit triangle bound per built slab for the 220 m world. A polygon has at
## most 24 vertices and a 1.2 m slab meets at most a 3×3 block of 1.72 m cells,
## each split by its diagonal — 18 planar pieces of a convex polygon are at most
## 18 + 24 - 2 fan triangles, and the side ring is at most two triangles per
## sub-segment over the same crossings. 200 is that bound rounded up; `build()`
## reports the measured maximum so a regression is a number, not a feeling.
const MAX_TRIANGLES_PER_SLAB := 200
## Half-plane classification tolerance, in metres. Kept tiny so a piece never
## strays measurably across a terrain crease.
const EPS := 0.0000001
## Two points closer than this are ONE point, in metres. `Vector2` is single
## precision, so two clip intersections that meet at a grid corner land up to a
## few float32 ulps apart — about 1e-7 m near the origin, ~1e-5 m at the world
## edge — and a fan over such a pair emits a zero-area triangle. A tenth of a
## millimetre is far above that noise and far below anything a frame can show.
const WELD := 0.0001
## Fan triangles and side strips thinner than this are dropped rather than
## emitted; the test asserts nothing thinner reaches the mesh.
const MIN_TRIANGLE_AREA := 0.00000001


## Build the overlay for one world.
##
## `field` decides which cells are stone and exposed; `height`, `normal` and
## `color` are the ground's own samplers — `WorldGen.surface_height_at`,
## `surface_normal_at` and `rendered_ground_color_at` — so the top carries the
## exact vertex colour the shader receives beneath it. `keep_out(x, z)` excludes
## a slab whose site it claims (the starter cave's hull padding, where a lifted
## top would poke through the massif's doorway).
##
## Returns `{"mesh": ArrayMesh or null, "stats": Dictionary}`. The mesh is null
## when no slab qualified; the stats always report every count the acceptance
## criteria name, so a caller can tell an empty world from a broken build.
## `vertices` counts the indexed mesh's distinct vertices, `triangles` its faces.
func build(field: ExposedSlabField, world_seed: int, world_size: float, quads: int,
		height: Callable, normal: Callable, color: Callable, keep_out: Callable) -> Dictionary:
	var stats := {
		&"candidates": 0,
		&"slabs": 0,
		&"exposed": 0,
		&"partial": 0,
		&"kept_out": 0,
		&"built": 0,
		&"vertices": 0,
		&"triangles": 0,
		&"surfaces": 0,
		&"max_triangles_per_slab": 0,
		&"nearest_built_site": Vector3.ZERO,
	}
	if field == null or not is_finite(world_size) or world_size <= 0.0 or quads <= 0 \
			or not height.is_valid() or not normal.is_valid() or not color.is_valid():
		return {&"mesh": null, &"stats": stats}
	var half := world_size * 0.5
	var step := world_size / float(quads)
	var identities := field.candidate_identities(world_seed, world_size)
	stats[&"candidates"] = identities.size()

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var triangles := 0
	var nearest_distance := INF
	for identity in identities:
		if not field.is_slab_identity(identity):
			continue
		stats[&"slabs"] += 1
		var site := field.site_for(identity)
		if absf(site.x) > half - WORLD_INSET or absf(site.y) > half - WORLD_INSET:
			continue
		if not _exposed_at(field, world_seed, site, normal):
			continue
		var polygon := field.polygon_for(identity)
		if polygon.size() < 3:
			continue
		# The shader decides exposure per fragment, so a slab whose ash sheet ends
		# halfway across it is stone on one side and ash on the other. A lifted top
		# there would be a raised ash lump. Only a slab exposed at its site AND at
		# enough of its corners is lifted; the count stops as soon as the verdict
		# is settled either way.
		var needed := ceili(MIN_EXPOSED_CORNER_SHARE * float(polygon.size()) - EPS)
		var exposed_corners := 0
		for index in polygon.size():
			if exposed_corners >= needed or exposed_corners + polygon.size() - index < needed:
				break
			var corner := polygon[index]
			var probe := Vector2(clampf(corner.x, -half, half), clampf(corner.y, -half, half))
			if _exposed_at(field, world_seed, probe, normal):
				exposed_corners += 1
		if exposed_corners < needed:
			stats[&"partial"] += 1
			continue
		stats[&"exposed"] += 1
		if keep_out.is_valid() and bool(keep_out.call(site.x, site.y)):
			stats[&"kept_out"] += 1
			continue
		var inset := half - WORLD_INSET
		polygon = _clip_rect(polygon, Vector2(-inset, -inset), Vector2(inset, inset))
		if polygon.size() < 3:
			continue
		var slab_triangles := _emit_slab(
			st, polygon, thickness_for(identity), half, step, height, normal, color)
		if slab_triangles <= 0:
			continue
		stats[&"built"] += 1
		triangles += slab_triangles
		stats[&"max_triangles_per_slab"] = maxi(
			int(stats[&"max_triangles_per_slab"]), slab_triangles)
		var site_distance := site.length_squared()
		if site_distance < nearest_distance:
			nearest_distance = site_distance
			stats[&"nearest_built_site"] = Vector3(
				site.x, float(height.call(site.x, site.y)), site.y)
	stats[&"triangles"] = triangles
	if triangles == 0:
		return {&"mesh": null, &"stats": stats}
	# Index before committing: every top fan shares one normal and one colour per
	# position and both triangles of a side quad share their corners, so the
	# vertex buffer the GPU walks on every pass shrinks to the distinct tuples.
	st.index()
	var mesh := st.commit()
	stats[&"surfaces"] = mesh.get_surface_count()
	stats[&"vertices"] = (
		mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	return {&"mesh": mesh, &"stats": stats}


## One slab's lip thickness, metres — the client's shared platform-independent
## unit hash over its seeded identity, so two fresh builds of one world agree,
## neighbouring slabs differ, and no `sin`-based hash makes the overlay's
## fingerprint depend on the host's libm.
static func thickness_for(identity: Vector3i) -> float:
	var key := (identity.y * 73856093) ^ (identity.z * 19349663) ^ (identity.x * 83492791)
	return lerpf(MIN_THICKNESS, MAX_THICKNESS, GroundRegions.unit_hash(key))


## Top pieces and side strips for one slab polygon, as non-indexed packed arrays
## (one vertex per corner of every triangle, so a caller can walk them in
## threes). Exposed on its own so a test can hold the conformance law against a
## small ground it can reason about by hand. Returns `triangles`, `vertices`
## and per-vertex `normals`.
static func slab_triangles(polygon: PackedVector2Array, thickness: float, half: float,
		step: float, height: Callable, normal: Callable, color: Callable) -> Dictionary:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var count := _emit_slab(st, polygon, thickness, half, step, height, normal, color)
	if count <= 0:
		return {&"triangles": 0, &"vertices": PackedVector3Array(), &"normals": PackedVector3Array()}
	var arrays := st.commit_to_arrays()
	return {
		&"triangles": count,
		&"vertices": arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array,
		&"normals": arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array,
	}


## Split a convex XZ polygon along the terrain's grid lines and quad diagonals so
## every returned piece lies inside one terrain triangle. Exposed for the test.
static func split_by_terrain_grid(polygon: PackedVector2Array, half: float, step: float) \
		-> Array[PackedVector2Array]:
	var pieces: Array[PackedVector2Array] = []
	if polygon.size() < 3 or step <= 0.0:
		return pieces
	var lo := polygon[0]
	var hi := polygon[0]
	for p in polygon:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	var ix0 := floori((lo.x + half) / step)
	var ix1 := floori((hi.x + half) / step)
	var iz0 := floori((lo.y + half) / step)
	var iz1 := floori((hi.y + half) / step)
	for iz in range(iz0, iz1 + 1):
		for ix in range(ix0, ix1 + 1):
			var cell_lo := Vector2(ix * step - half, iz * step - half)
			var cell := _clip_rect(polygon, cell_lo, cell_lo + Vector2(step, step))
			if cell.size() < 3:
				continue
			# The quad splits along v00→v11: (x - x0) - (z - z0) >= 0 is the
			# (v00, v11, v10) triangle, the rest is (v00, v01, v11) — the same
			# convention `surface_height_at` interpolates with.
			var lower := _clip(cell, cell_lo, Vector2(-1.0, 1.0))
			var upper := _clip(cell, cell_lo, Vector2(1.0, -1.0))
			if area(lower) > EPS:
				pieces.append(lower)
			if area(upper) > EPS:
				pieces.append(upper)
	return pieces


## Parameters along a → b, ascending and including 0 and 1, where the segment
## crosses a grid line or a quad diagonal. The ground is linear between two
## consecutive values, so a side strip built between them lies on the terrain
## rather than cutting through it. Exposed for the test.
static func edge_crossings(a: Vector2, b: Vector2, half: float, step: float) -> PackedFloat64Array:
	var ts := PackedFloat64Array([0.0, 1.0])
	_append_axis_crossings(ts, a.x + half, b.x + half, step)
	_append_axis_crossings(ts, a.y + half, b.y + half, step)
	# Diagonals are the lines x - z = k * step.
	_append_axis_crossings(ts, a.x - a.y, b.x - b.y, step)
	ts.sort()
	var length := a.distance_to(b)
	var weld_t := WELD / length if length > WELD else 1.0
	var distinct := PackedFloat64Array()
	for t in ts:
		if distinct.is_empty() or t - distinct[distinct.size() - 1] > weld_t:
			distinct.append(t)
	if distinct.size() > 1 and distinct[distinct.size() - 1] < 1.0:
		distinct[distinct.size() - 1] = 1.0
	return distinct


## Shoelace area of an XZ polygon, whichever way it winds.
static func area(polygon: PackedVector2Array) -> float:
	var twice := 0.0
	for index in polygon.size():
		twice += polygon[index].cross(polygon[(index + 1) % polygon.size()])
	return absf(twice) * 0.5


## Vertex-average centre of an XZ polygon — inside it for the convex polygons
## this module handles.
static func centroid(polygon: PackedVector2Array) -> Vector2:
	var sum := Vector2.ZERO
	for p in polygon:
		sum += p
	return sum / float(maxi(polygon.size(), 1))


## The field's exposure verdict at one point, with the region context the terrain
## shader's fragment would have there: the slope of the flat-shaded ground
## triangle and the broad drift, computed once and handed in so `sample()` does
## not pay for the drift a second time.
static func _exposed_at(field: ExposedSlabField, world_seed: int, at: Vector2,
		normal: Callable) -> bool:
	var n: Vector3 = normal.call(at.x, at.y)
	var slope := clampf(1.0 - n.y, 0.0, 1.0)
	var drift := field.ground_drift(at)
	var verdict := field.sample(world_seed, at, {
		&"rock_mix": field.rock_mix_for(slope, drift),
		&"drift": drift,
	})
	return bool(verdict.get(&"exposed", false))


static func _emit_slab(st: SurfaceTool, polygon: PackedVector2Array, thickness: float,
		half: float, step: float, height: Callable, normal: Callable, color: Callable) -> int:
	if polygon.size() < 3 or area(polygon) <= EPS:
		return 0
	var slab_centre := centroid(polygon)
	# The ground colour at one footprint is the same for every vertex standing on
	# it — a top corner, the lip's top and the lip's buried edge — so it is
	# resolved once per footprint rather than once per emitted vertex.
	var colors := {}
	var count := 0
	for piece in split_by_terrain_grid(polygon, half, step):
		var piece_centre := centroid(piece)
		var up: Vector3 = normal.call(piece_centre.x, piece_centre.y)
		var lifted := PackedVector3Array()
		lifted.resize(piece.size())
		for index in piece.size():
			var p := piece[index]
			lifted[index] = Vector3(p.x, float(height.call(p.x, p.y)) + thickness, p.y)
		for index in range(1, piece.size() - 1):
			var fan_area := absf(
				(piece[index] - piece[0]).cross(piece[index + 1] - piece[0])) * 0.5
			if fan_area < MIN_TRIANGLE_AREA:
				continue
			_add_triangle(st, lifted[0], lifted[index], lifted[index + 1], up, color, colors)
			count += 1
	for index in polygon.size():
		var a := polygon[index]
		var b := polygon[(index + 1) % polygon.size()]
		# An edge at or below WELD collapses `edge_crossings` to a single parameter, so
		# it emits no side quad at all — deliberately, since a sub-tenth-of-a-millimetre
		# face is far below anything a frame resolves. This guard is the coarser EPS one
		# only because a zero-length edge must not reach `normalized()` below.
		var edge := b - a
		if edge.length_squared() <= EPS * EPS:
			continue
		# Outward in XZ, decided against the slab's own centroid rather than an
		# assumed winding, so a clipped polygon cannot turn its lip inside out.
		var outward := Vector2(edge.y, -edge.x).normalized()
		if outward.dot((a + b) * 0.5 - slab_centre) < 0.0:
			outward = -outward
		var side_normal := Vector3(outward.x, 0.0, outward.y)
		var ts := edge_crossings(a, b, half, step)
		for k in range(ts.size() - 1):
			var p := a.lerp(b, ts[k])
			var q := a.lerp(b, ts[k + 1])
			if p.distance_squared_to(q) < WELD * WELD:
				continue
			var hp := float(height.call(p.x, p.y))
			var hq := float(height.call(q.x, q.y))
			var top_p := Vector3(p.x, hp + thickness, p.y)
			var top_q := Vector3(q.x, hq + thickness, q.y)
			var bottom_p := Vector3(p.x, hp - SKIRT, p.y)
			var bottom_q := Vector3(q.x, hq - SKIRT, q.y)
			# Two triangles facing `side_normal`; `_add_triangle` orients the
			# winding, so the edge direction need not be known here.
			_add_triangle(st, bottom_p, bottom_q, top_q, side_normal, color, colors)
			_add_triangle(st, bottom_p, top_q, top_p, side_normal, color, colors)
			count += 2
	return count


## Emit a triangle so its front face points along `facing`. Godot front faces
## wind CLOCKWISE, so a triangle whose right-hand normal (b - a) × (c - a)
## already agrees with `facing` goes out as a, c, b — the same convention
## `WorldGen._add_tri` uses for the terrain this sits on — and one that
## disagrees goes out as a, b, c. Either way the face points where asked.
static func _add_triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		facing: Vector3, color: Callable, colors: Dictionary) -> void:
	var order := [a, c, b]
	if (b - a).cross(c - a).dot(facing) < 0.0:
		order = [a, b, c]
	st.set_normal(facing.normalized())
	for v: Vector3 in order:
		var footprint := Vector2(v.x, v.z)
		if not colors.has(footprint):
			colors[footprint] = color.call(v.x, v.z)
		st.set_color(colors[footprint])
		st.add_vertex(v)


## The part of `polygon` inside the axis-aligned rectangle `lo`..`hi`.
static func _clip_rect(polygon: PackedVector2Array, lo: Vector2, hi: Vector2) -> PackedVector2Array:
	var out := _clip(polygon, lo, Vector2(-1.0, 0.0))
	out = _clip(out, hi, Vector2(1.0, 0.0))
	out = _clip(out, lo, Vector2(0.0, -1.0))
	return _clip(out, hi, Vector2(0.0, 1.0))


static func _clip(polygon: PackedVector2Array, point: Vector2, outside: Vector2) -> PackedVector2Array:
	return ExposedSlabField.clip_half_plane(polygon, point, outside, EPS, WELD)


static func _append_axis_crossings(ts: PackedFloat64Array, from: float, to: float,
		step: float) -> void:
	if absf(to - from) <= EPS:
		return
	var lo := minf(from, to)
	var hi := maxf(from, to)
	var k0 := ceili(lo / step - EPS)
	var k1 := floori(hi / step + EPS)
	for k in range(k0, k1 + 1):
		var t := (k * step - from) / (to - from)
		if t > EPS and t < 1.0 - EPS:
			ts.append(t)
