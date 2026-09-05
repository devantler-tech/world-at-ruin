extends Node
## Contract tests for the batched raised exposed-stone overlay (#547).
##
## Two halves. The UNIT half holds the geometry module against a small
## hand-built piecewise-linear ground — 4×4 quads of 2 m, creased along every
## grid line and quad diagonal with the same interpolation
## `WorldGen.surface_height_at` uses — where the conformance law is checkable to
## the millimetre: every top vertex sits exactly one thickness above the ground,
## every top TRIANGLE stays planar over the ground under it (a piece that
## straddled a crease floats on one side and sinks on the other at its own
## centroid), every side face is vertical, outward and buried, and the side
## strips split exactly where the ground creases. The INTEGRATION half builds
## the real world once with `WAR_GROUND_PLATES` off and twice with it on: the
## overlay is one surface on one node, identical across the two fresh builds,
## absent when off, and the base terrain mesh, collision, heights and foliage
## are byte-identical in all three.
##
## No cross-platform golden is pinned for the overlay's vertex bytes: the field's
## exposure decision runs through `sin`-based hashes whose last bit can differ
## between libms, and the flag-off world golden already covers everything the
## default game contains. The fingerprint is printed so a reader can compare
## hosts by hand.
##
## Run: godot --headless --path client res://tests/exposed_slab_geometry_test.tscn

const EPS := 0.00001
const UNIT_SIZE := 8.0
const UNIT_QUADS := 4
const UNIT_STEP := UNIT_SIZE / float(UNIT_QUADS)
const UNIT_HALF := UNIT_SIZE * 0.5
const UNIT_THICKNESS := 0.09
## A hand-authored 5×5 height grid with no two neighbours coplanar, so every
## grid line and diagonal really is a crease.
const UNIT_HEIGHTS: Array[float] = [
	0.10, 0.60, 0.20, 0.90, 0.30,
	0.80, 0.15, 0.70, 0.25, 0.95,
	0.35, 0.85, 0.05, 0.65, 0.40,
	0.75, 0.30, 0.55, 0.10, 0.80,
	0.20, 0.90, 0.45, 0.70, 0.05,
]
const EXPECTED_WORLD_CANDIDATES := 36_100

var _failures: Array[String] = []


func _ready() -> void:
	var geometry := ExposedSlabGeometry.new()
	var field := ExposedSlabField.new()
	_test_field_additions(field)
	_test_edge_crossings(geometry)
	_test_grid_split(geometry)
	_test_thickness(geometry)
	_test_unit_conformance(geometry)
	if _failures.is_empty():
		_test_world()
	_report()


## The three field helpers the geometry consumes mirror the shader laws the
## existing field fixtures already pin.
func _test_field_additions(field: ExposedSlabField) -> void:
	if not field.is_slab_identity(Vector3i(1409, -84, -86)):
		_fail("the field's exposed fixture cell (-84, -86) is not a slab")
	var at_site := field.sample(1409, field.site_for(Vector3i(1409, 0, 0)), {&"rock_mix": 0.0})
	if at_site.get(&"id") != Vector2i.ZERO:
		_fail("site_for(0, 0) is owned by %s, expected (0, 0)" % [at_site.get(&"id")])
	var drift := field.ground_drift(Vector2(-13.75, -20.0))
	if absf(drift - 0.64235711097717) > 0.000001:
		_fail("ground_drift at the interior fixture is %.9f, expected 0.642357111" % drift)
	if field.rock_mix_for(0.0, 0.5) != 0.0:
		_fail("flat ground at neutral drift has rock_mix %.6f, expected 0"
			% field.rock_mix_for(0.0, 0.5))
	if field.rock_mix_for(1.0, 0.5) != 1.0:
		_fail("a vertical face has rock_mix %.6f, expected 1" % field.rock_mix_for(1.0, 0.5))
	if absf(field.rock_mix_for(ExposedSlabField.ROCK_SLOPE, 0.5) - 0.5) > 0.000001:
		_fail("the rock_slope contact resolves rock_mix %.6f, expected 0.5"
			% field.rock_mix_for(ExposedSlabField.ROCK_SLOPE, 0.5))
	if field.rock_mix_for(0.5, 0.5) <= field.rock_mix_for(0.3, 0.5):
		_fail("rock_mix does not rise with slope")


## Crossings of one segment with the 2 m grid: x = 0 at t = 0.5, z = 0 at
## t = 1/3, and the diagonal x - z = 0 at t = 2/3.
func _test_edge_crossings(geometry: ExposedSlabGeometry) -> void:
	var ts := geometry.edge_crossings(
		Vector2(-1.5, -0.5), Vector2(1.5, 1.0), UNIT_HALF, UNIT_STEP)
	var expected := PackedFloat64Array([0.0, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0])
	if ts.size() != expected.size():
		_fail("edge crossings are %s, expected %s" % [ts, expected])
		return
	for index in ts.size():
		if absf(ts[index] - expected[index]) > EPS:
			_fail("edge crossing %d is %.6f, expected %.6f" % [index, ts[index], expected[index]])
	var along := geometry.edge_crossings(
		Vector2(-1.0, 0.0), Vector2(1.0, 0.0), UNIT_HALF, UNIT_STEP)
	if along.size() != 3 or absf(along[1] - 0.5) > EPS:
		_fail("a segment along a grid line still splits at its x crossing: %s" % [along])


## Splitting conserves area, and every piece lies inside one terrain triangle.
func _test_grid_split(geometry: ExposedSlabGeometry) -> void:
	var polygon := _unit_polygon()
	var pieces := geometry.split_by_terrain_grid(polygon, UNIT_HALF, UNIT_STEP)
	if pieces.size() < 4:
		_fail("a hexagon across two grid lines and a diagonal split into %d piece(s)"
			% pieces.size())
		return
	var total := 0.0
	for piece in pieces:
		total += ExposedSlabGeometry.area(piece)
		var centre := ExposedSlabGeometry.centroid(piece)
		var ix := floori((centre.x + UNIT_HALF) / UNIT_STEP)
		var iz := floori((centre.y + UNIT_HALF) / UNIT_STEP)
		var x0 := ix * UNIT_STEP - UNIT_HALF
		var z0 := iz * UNIT_STEP - UNIT_HALF
		var lower := (centre.x - x0) - (centre.y - z0) >= 0.0
		for p in piece:
			if p.x < x0 - EPS or p.x > x0 + UNIT_STEP + EPS \
					or p.y < z0 - EPS or p.y > z0 + UNIT_STEP + EPS:
				_fail("piece vertex %s leaves cell (%d, %d)" % [p, ix, iz])
				return
			var side := (p.x - x0) - (p.y - z0)
			if (lower and side < -EPS) or (not lower and side > EPS):
				_fail("piece vertex %s crosses the diagonal of cell (%d, %d)" % [p, ix, iz])
				return
	if absf(total - ExposedSlabGeometry.area(polygon)) > EPS:
		_fail("split pieces cover %.6f m², the polygon covers %.6f m²" % [total, ExposedSlabGeometry.area(polygon)])


func _test_thickness(geometry: ExposedSlabGeometry) -> void:
	var a := geometry.thickness_for(Vector3i(1409, 3, -7))
	var again := geometry.thickness_for(Vector3i(1409, 3, -7))
	var neighbour := geometry.thickness_for(Vector3i(1409, 4, -7))
	if a != again:
		_fail("thickness_for is not deterministic")
	if a < ExposedSlabGeometry.MIN_THICKNESS or a > ExposedSlabGeometry.MAX_THICKNESS:
		_fail("thickness %.4f leaves the %.2f..%.2f range"
			% [a, ExposedSlabGeometry.MIN_THICKNESS, ExposedSlabGeometry.MAX_THICKNESS])
	if a == neighbour:
		_fail("two neighbouring slabs share the thickness %.4f" % a)
	if ExposedSlabGeometry.SKIRT < 0.05:
		_fail("the lip skirt %.3f is too shallow to bury the seam" % ExposedSlabGeometry.SKIRT)


## Every law a rendered lip depends on, held against the hand-built ground — for
## the field's own winding AND its reverse. The field emits one orientation, so
## without the reversed case the winding and outward-flip branches that make
## the module orientation-proof run only one way and an ablation of either passes.
func _test_unit_conformance(geometry: ExposedSlabGeometry) -> void:
	_test_unit_conformance_for(geometry, _unit_polygon(), "field winding")
	var reversed := _unit_polygon()
	reversed.reverse()
	_test_unit_conformance_for(geometry, reversed, "reversed winding")


func _test_unit_conformance_for(geometry: ExposedSlabGeometry, polygon: PackedVector2Array,
		label: String) -> void:
	var tag := "[%s] " % label
	var result := geometry.slab_triangles(
		polygon, UNIT_THICKNESS, UNIT_HALF, UNIT_STEP,
		_unit_height, _unit_normal, _unit_color)
	var vertices: PackedVector3Array = result[&"vertices"]
	var normals: PackedVector3Array = result[&"normals"]
	var triangles := int(result[&"triangles"])
	if triangles <= 0 or vertices.size() != triangles * 3 or normals.size() != vertices.size():
		_fail(tag + "unit slab emitted %d triangles over %d vertices and %d normals"
			% [triangles, vertices.size(), normals.size()])
		return
	var centroid := ExposedSlabGeometry.centroid(polygon)
	var tops := 0
	var sides := 0
	var expected_sides := 0
	for index in polygon.size():
		var a := polygon[index]
		var b := polygon[(index + 1) % polygon.size()]
		expected_sides += 2 * (geometry.edge_crossings(a, b, UNIT_HALF, UNIT_STEP).size() - 1)
	for tri in triangles:
		var p0 := vertices[tri * 3]
		var p1 := vertices[tri * 3 + 1]
		var p2 := vertices[tri * 3 + 2]
		var declared := normals[tri * 3]
		# Godot front faces wind clockwise: the geometric front normal of the
		# emitted order is (p2 - p0) × (p1 - p0).
		var front := (p2 - p0).cross(p1 - p0)
		if front.length() <= ExposedSlabGeometry.MIN_TRIANGLE_AREA:
			_fail(tag + "triangle %d is degenerate" % tri)
			return
		if front.normalized().dot(declared) < 0.999:
			_fail(tag + "triangle %d winds against its declared normal %s (front %s)"
				% [tri, declared, front.normalized()])
			return
		if declared.y > 0.5:
			tops += 1
			var offsets := PackedFloat64Array()
			for v in [p0, p1, p2]:
				var offset: float = v.y - _unit_height(v.x, v.z)
				offsets.append(offset)
				if absf(offset - UNIT_THICKNESS) > EPS:
					_fail(tag + "top vertex %s sits %.5f above the ground, expected %.5f"
						% [v, offset, UNIT_THICKNESS])
					return
			var centre := (p0 + p1 + p2) / 3.0
			var centre_offset: float = centre.y - _unit_height(centre.x, centre.z)
			if absf(centre_offset - UNIT_THICKNESS) > EPS:
				_fail(tag + "top triangle %d is not planar over the ground: its centre floats %.5f, expected %.5f"
					% [tri, centre_offset, UNIT_THICKNESS])
				return
			var ground_normal := _unit_normal(centre.x, centre.z)
			if ground_normal.dot(declared) < 0.999:
				_fail(tag + "top triangle %d declares normal %s over ground normal %s"
					% [tri, declared, ground_normal])
				return
		else:
			sides += 1
			if absf(declared.y) > EPS:
				_fail(tag + "side triangle %d is not vertical: normal %s" % [tri, declared])
				return
			var mid := Vector2((p0.x + p1.x + p2.x) / 3.0, (p0.z + p1.z + p2.z) / 3.0)
			if Vector2(declared.x, declared.z).dot(mid - centroid) <= 0.0:
				_fail(tag + "side triangle %d faces inward" % tri)
				return
			var footprints := {}
			for v in [p0, p1, p2]:
				footprints[Vector2(v.x, v.z)] = true
				var offset: float = v.y - _unit_height(v.x, v.z)
				var is_top := absf(offset - UNIT_THICKNESS) <= EPS
				var is_bottom := absf(offset + ExposedSlabGeometry.SKIRT) <= EPS
				if not is_top and not is_bottom:
					_fail(tag + "side vertex %s sits %.5f from the ground — neither the lip top nor the buried skirt"
						% [v, offset])
					return
			if footprints.size() != 2:
				_fail(tag + "side triangle %d spans %d footprints, expected 2" % [tri, footprints.size()])
				return
	if tops == 0 or sides == 0:
		_fail(tag + "unit slab emitted %d tops and %d sides" % [tops, sides])
	if sides != expected_sides:
		_fail(tag + "unit slab emitted %d side triangles, expected %d from the edge crossings"
			% [sides, expected_sides])


## The real world: off leaves nothing behind, on adds one batched node, two fresh
## builds agree, and the base ground is untouched in every build.
func _test_world() -> void:
	OS.set_environment("WAR_GROUND_PLATES", "0")
	var off := WorldGen.new()
	add_child(off)
	if off.get_node_or_null(WorldGen.GROUND_PLATES_NODE) != null:
		_fail("WAR_GROUND_PLATES=0 still built a %s node" % WorldGen.GROUND_PLATES_NODE)
	if not off.ground_plates_stats().is_empty():
		_fail("WAR_GROUND_PLATES=0 recorded overlay stats %s" % [off.ground_plates_stats()])
	if _plates_uniform(off) != false:
		_fail("WAR_GROUND_PLATES=0 left the terrain's plates_enabled uniform on")
	var off_names := _child_names(off)
	var off_terrain := _terrain_hash(off)
	var off_collision := _collision_hash(off)
	var off_foliage := off.foliage_placements()

	OS.set_environment("WAR_GROUND_PLATES", "1")
	var a := WorldGen.new()
	add_child(a)
	OS.set_environment("WAR_GROUND_PLATES", "0")
	var overlay := a.get_node_or_null(WorldGen.GROUND_PLATES_NODE) as MeshInstance3D
	if overlay == null or overlay.mesh == null:
		_fail("WAR_GROUND_PLATES=1 built no %s mesh" % WorldGen.GROUND_PLATES_NODE)
		return
	if _plates_uniform(a) != true:
		_fail("WAR_GROUND_PLATES=1 left the terrain's plates_enabled uniform off")
	var on_names := _child_names(a)
	var expected_names := off_names.duplicate()
	expected_names.append(WorldGen.GROUND_PLATES_NODE)
	if on_names != expected_names:
		_fail("the on-state tree is %s, expected the off-state tree plus one %s"
			% [on_names, WorldGen.GROUND_PLATES_NODE])
	if _terrain_hash(a) != off_terrain:
		_fail("the base terrain mesh changed with the flag on")
	if _collision_hash(a) != off_collision:
		_fail("the terrain collision changed with the flag on")
	if a.foliage_placements() != off_foliage:
		_fail("foliage placement changed with the flag on")
	for probe: Vector2 in [Vector2(3.0, 4.0), Vector2(-40.5, 61.25), Vector2(77.0, -33.0)]:
		if a.surface_height_at(probe.x, probe.y) != off.surface_height_at(probe.x, probe.y):
			_fail("surface_height_at%s differs between the flag states" % [probe])
			break
	if overlay.mesh.get_surface_count() != 1:
		_fail("the overlay carries %d surfaces, expected exactly one batch"
			% overlay.mesh.get_surface_count())
	if overlay.mesh.surface_get_material(0) != _terrain_material(a):
		_fail("the overlay does not share the terrain's ShaderMaterial")
	var stats := a.ground_plates_stats()
	_check_stats(stats, overlay.mesh)
	var fingerprint_a := _mesh_hash(overlay.mesh)
	_check_world_conformance(a, overlay.mesh)
	_check_toggle(a, off, fingerprint_a, stats)
	print("OVERLAY FINGERPRINT %s built=%d exposed=%d partial=%d kept_out=%d slabs=%d candidates=%d vertices=%d triangles=%d max_per_slab=%d"
		% [fingerprint_a, stats[&"built"], stats[&"exposed"], stats[&"partial"],
			stats[&"kept_out"], stats[&"slabs"], stats[&"candidates"], stats[&"vertices"],
			stats[&"triangles"], stats[&"max_triangles_per_slab"]])


func _check_stats(stats: Dictionary, mesh: ArrayMesh) -> void:
	if int(stats.get(&"candidates", 0)) != EXPECTED_WORLD_CANDIDATES:
		_fail("the overlay counted %s candidates, expected %d"
			% [stats.get(&"candidates"), EXPECTED_WORLD_CANDIDATES])
	var slabs := int(stats.get(&"slabs", 0))
	var exposed := int(stats.get(&"exposed", 0))
	var built := int(stats.get(&"built", 0))
	var triangles := int(stats.get(&"triangles", 0))
	if slabs <= 0 or exposed <= 0 or built <= 0 or triangles <= 0:
		_fail("the overlay built nothing: %s" % [stats])
		return
	if exposed > slabs or built > exposed:
		_fail("slab counts are inconsistent: %s" % [stats])
	var arrays: Array = mesh.surface_get_arrays(0)
	var mesh_vertices := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	# A non-indexed surface carries Nil here, and a typed cast of Nil would abort
	# this function silently — which is a PASS by default. Ask first.
	var raw_indices: Variant = arrays[Mesh.ARRAY_INDEX]
	if not (raw_indices is PackedInt32Array):
		_fail("the overlay is not indexed: its surface carries no index buffer")
		return
	var mesh_indices := (raw_indices as PackedInt32Array).size()
	if int(stats.get(&"vertices", 0)) != mesh_vertices:
		_fail("stats report %s vertices, the mesh holds %d" % [stats.get(&"vertices"), mesh_vertices])
	if mesh_indices != triangles * 3:
		_fail("stats report %d triangles, the mesh indexes %d corners" % [triangles, mesh_indices])
	if mesh_vertices >= triangles * 3:
		_fail("the overlay is not indexed: %d vertices for %d triangles" % [mesh_vertices, triangles])
	var max_per_slab := int(stats.get(&"max_triangles_per_slab", 0))
	if max_per_slab <= 0 or max_per_slab > ExposedSlabGeometry.MAX_TRIANGLES_PER_SLAB:
		_fail("the largest slab used %d triangles, bound %d"
			% [max_per_slab, ExposedSlabGeometry.MAX_TRIANGLES_PER_SLAB])
	var site: Vector3 = stats.get(&"nearest_built_site", Vector3.ZERO)
	if site == Vector3.ZERO or absf(site.x) > WorldGen.SIZE * 0.5 or absf(site.z) > WorldGen.SIZE * 0.5:
		_fail("nearest built site %s is not inside the world" % site)


## The same conformance law over every triangle of the real overlay, against
## the real ground: tops one thickness above and planar, sides vertical and
## buried, every vertex inside the terrain square.
func _check_world_conformance(world: WorldGen, mesh: ArrayMesh) -> void:
	var arrays: Array = mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var raw_indices: Variant = arrays[Mesh.ARRAY_INDEX]
	if not (raw_indices is PackedInt32Array):
		_fail("the overlay is not indexed: its surface carries no index buffer")
		return
	var indices := raw_indices as PackedInt32Array
	if vertices.is_empty() or normals.size() != vertices.size() or indices.size() % 3 != 0 \
			or indices.is_empty():
		_fail("overlay arrays are malformed: %d vertices, %d normals, %d indices"
			% [vertices.size(), normals.size(), indices.size()])
		return
	var half := WorldGen.SIZE * 0.5
	var slack := 0.001
	for tri in range(0, indices.size(), 3):
		var corners := [vertices[indices[tri]], vertices[indices[tri + 1]], vertices[indices[tri + 2]]]
		var declared := normals[indices[tri]]
		var offsets := PackedFloat64Array()
		var front: Vector3 = (corners[2] - corners[0]).cross(corners[1] - corners[0])
		if front.length() <= ExposedSlabGeometry.MIN_TRIANGLE_AREA:
			_fail("overlay triangle %d is degenerate: %s" % [tri / 3, corners])
			return
		if front.normalized().dot(declared) < 0.999:
			_fail("overlay triangle %d winds against its declared normal" % (tri / 3))
			return
		for k in 3:
			var v: Vector3 = corners[k]
			if not is_finite(v.x) or not is_finite(v.y) or not is_finite(v.z):
				_fail("overlay vertex %s is not finite" % v)
				return
			if absf(v.x) > half or absf(v.z) > half:
				_fail("overlay vertex %s leaves the terrain square" % v)
				return
			var ground := world.surface_height_at(v.x, v.z)
			if ground <= WorldGen.NO_GROUND + 1.0:
				_fail("overlay vertex %s stands on no ground" % v)
				return
			offsets.append(v.y - ground)
		if declared.y > 0.5:
			for offset in offsets:
				if offset < ExposedSlabGeometry.MIN_THICKNESS - slack \
						or offset > ExposedSlabGeometry.MAX_THICKNESS + slack:
					_fail("a top vertex sits %.4f above the ground, outside %.2f..%.2f"
						% [offset, ExposedSlabGeometry.MIN_THICKNESS,
							ExposedSlabGeometry.MAX_THICKNESS])
					return
			if absf(offsets[0] - offsets[1]) > slack or absf(offsets[0] - offsets[2]) > slack:
				_fail("a top triangle is not a uniform lift: offsets %s" % [offsets])
				return
			var centre: Vector3 = (corners[0] + corners[1] + corners[2]) / 3.0
			var centre_offset := centre.y - world.surface_height_at(centre.x, centre.z)
			if absf(centre_offset - offsets[0]) > slack:
				_fail("a top triangle straddles a terrain crease: centre lift %.4f vs corner lift %.4f"
					% [centre_offset, offsets[0]])
				return
		else:
			if absf(declared.y) > slack:
				_fail("a side triangle is not vertical: %s" % declared)
				return
			for offset in offsets:
				var is_top := offset >= ExposedSlabGeometry.MIN_THICKNESS - slack \
					and offset <= ExposedSlabGeometry.MAX_THICKNESS + slack
				var is_bottom := absf(offset + ExposedSlabGeometry.SKIRT) <= slack
				if not is_top and not is_bottom:
					_fail("a side vertex sits %.4f from the ground — neither lip nor skirt" % offset)
					return


## The same-run toggle the measurement tools depend on: it flips the uniform and
## the overlay together, and builds the overlay lazily on a world that booted
## with the flag off.
func _check_toggle(on_world: WorldGen, off_world: WorldGen, boot_fingerprint: String,
		boot_stats: Dictionary) -> void:
	on_world.set_ground_plates_enabled(false)
	var overlay := on_world.get_node_or_null(WorldGen.GROUND_PLATES_NODE) as MeshInstance3D
	if overlay == null or overlay.visible or _plates_uniform(on_world) != false:
		_fail("disabling plates at runtime did not hide the overlay and clear the uniform")
	on_world.set_ground_plates_enabled(true)
	if overlay == null or not overlay.visible or _plates_uniform(on_world) != true:
		_fail("re-enabling plates at runtime did not show the overlay and set the uniform")
	off_world.set_ground_plates_enabled(true)
	var lazy := off_world.get_node_or_null(WorldGen.GROUND_PLATES_NODE) as MeshInstance3D
	if lazy == null or lazy.mesh == null or off_world.ground_plates_stats().is_empty():
		_fail("enabling plates on a flag-off world did not build the overlay")
	elif _mesh_hash(lazy.mesh) != boot_fingerprint or off_world.ground_plates_stats() != boot_stats:
		_fail("two fresh builds of one world disagree: %s / %s"
			% [boot_fingerprint, _mesh_hash(lazy.mesh)])


func _unit_polygon() -> PackedVector2Array:
	var polygon := PackedVector2Array()
	for k in 6:
		var angle := TAU * float(k) / 6.0 + 0.3
		polygon.append(Vector2(0.35, -0.25) + Vector2(cos(angle), sin(angle)) * 0.9)
	return polygon


## The hand-built ground, interpolated exactly as `WorldGen.surface_height_at`.
func _unit_height(x: float, z: float) -> float:
	var gx := (x + UNIT_HALF) / UNIT_STEP
	var gz := (z + UNIT_HALF) / UNIT_STEP
	var ix := mini(int(gx), UNIT_QUADS - 1)
	var iz := mini(int(gz), UNIT_QUADS - 1)
	var fx := gx - ix
	var fz := gz - iz
	var w := UNIT_QUADS + 1
	var h00 := UNIT_HEIGHTS[iz * w + ix]
	var h10 := UNIT_HEIGHTS[iz * w + ix + 1]
	var h01 := UNIT_HEIGHTS[(iz + 1) * w + ix]
	var h11 := UNIT_HEIGHTS[(iz + 1) * w + ix + 1]
	if fx >= fz:
		return h00 + (h10 - h00) * fx + (h11 - h10) * fz
	return h00 + (h11 - h01) * fx + (h01 - h00) * fz


func _unit_normal(x: float, z: float) -> Vector3:
	var gx := (x + UNIT_HALF) / UNIT_STEP
	var gz := (z + UNIT_HALF) / UNIT_STEP
	var ix := mini(int(gx), UNIT_QUADS - 1)
	var iz := mini(int(gz), UNIT_QUADS - 1)
	var fx := gx - ix
	var fz := gz - iz
	var w := UNIT_QUADS + 1
	var x0 := ix * UNIT_STEP - UNIT_HALF
	var z0 := iz * UNIT_STEP - UNIT_HALF
	var v00 := Vector3(x0, UNIT_HEIGHTS[iz * w + ix], z0)
	var v10 := Vector3(x0 + UNIT_STEP, UNIT_HEIGHTS[iz * w + ix + 1], z0)
	var v01 := Vector3(x0, UNIT_HEIGHTS[(iz + 1) * w + ix], z0 + UNIT_STEP)
	var v11 := Vector3(x0 + UNIT_STEP, UNIT_HEIGHTS[(iz + 1) * w + ix + 1], z0 + UNIT_STEP)
	if fx >= fz:
		return (v11 - v00).cross(v10 - v00).normalized()
	return (v01 - v00).cross(v11 - v00).normalized()


func _unit_color(_x: float, _z: float) -> Color:
	return Color(0.5, 0.5, 0.5, 0.5)


## Unnamed children (ruin pieces, foliage batches) get engine-assigned `@Node3D@N`
## names that differ between two instances, so those are compared by class.
func _child_names(world: Node) -> Array[String]:
	var names: Array[String] = []
	for child in world.get_children():
		var name := String(child.name)
		names.append(("@" + child.get_class()) if name.begins_with("@") else name)
	return names


func _terrain_material(world: Node) -> ShaderMaterial:
	var terrain := world.get_node_or_null("Terrain") as MeshInstance3D
	if terrain == null or terrain.mesh == null:
		return null
	return terrain.mesh.surface_get_material(0) as ShaderMaterial


func _plates_uniform(world: Node) -> Variant:
	var material := _terrain_material(world)
	if material == null:
		return null
	return material.get_shader_parameter("plates_enabled")


func _terrain_hash(world: Node) -> String:
	var terrain := world.get_node_or_null("Terrain") as MeshInstance3D
	if terrain == null or terrain.mesh == null:
		return "no-terrain"
	return _mesh_hash(terrain.mesh)


func _collision_hash(world: Node) -> String:
	var shape := world.get_node_or_null("TerrainBody/CollisionShape3D") as CollisionShape3D
	if shape == null or shape.shape == null:
		return "no-collision"
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update((shape.shape as ConcavePolygonShape3D).get_faces().to_byte_array())
	return ctx.finish().hex_encode().substr(0, 16)


func _mesh_hash(mesh: Mesh) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for surface in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(surface)
		ctx.update((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).to_byte_array())
		ctx.update((arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array).to_byte_array())
		var colors: Variant = arrays[Mesh.ARRAY_COLOR]
		if colors is PackedColorArray:
			ctx.update((colors as PackedColorArray).to_byte_array())
	return ctx.finish().hex_encode().substr(0, 16)


func _fail(message: String) -> void:
	_failures.append(message)
	push_error(message)


func _report() -> void:
	if _failures.is_empty():
		print("TEST PASS: exposed slab geometry")
		get_tree().quit(0)
		return
	for failure in _failures:
		print("TEST FAIL: %s" % failure)
	get_tree().quit(1)
