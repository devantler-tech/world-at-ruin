class_name ExposedSlabField
extends RefCounted
## Pure CPU representation of the opt-in exposed-stone slab field.
##
## The arithmetic in this first slice matches the shipping terrain shader for
## the current world: one 3×3 jittered-cell ownership search, the same
## three-octave drift field, the same named-substance bands, and the same
## discrete slab decision. Every scalar transcendental/mix step is rounded back
## to binary32, matching the shader's precision instead of GDScript's float64.
## GPU vendors may still approximate `sin` differently; the mesh child must
## compare these fixed fixtures on its actual render device before enabling
## visible topology. This child deliberately creates none.

const PLATE_SCALE := 0.85
const DRIFT_SCALE := 0.055
const ASH_CONTACT := 0.035
const EXPOSED_THRESHOLD := 0.47
const EXPOSURE_WIDTH_MAX := 0.25
## The terrain shader's `rock_slope` default: above this slope (1 = vertical) a face
## is treated as scoured rock, ash or no ash.
const ROCK_SLOPE := 0.34
## How far the drift field tilts that threshold either way: the shader's
## `(drift - 0.5) * 0.22`, named so the parity test can build its pinned shader
## text from the same number the mirror computes with.
const DRIFT_TILT := 0.22
## The shader literal rounded to the binary32 value its scalar path receives.
const HASH_SCALE_F32 := 43758.546875
## A fragment searches 3×3 cells around itself. Relative to one possible owner,
## that admits competitors two lattice cells away: a 5×5 window, minus itself.
const MAX_VERTICES_PER_POLYGON := 24
## `candidate_identities(1409, 220.0)` spans cell -95 through 94 on each axis:
## 190² candidates, including the one-cell halo reachable at each world edge.
const MAX_CANDIDATES_220M := 36_100

const CANDIDATE_HALO := 1
const CLIP_RADIUS := 2.0
const CLIP_EPSILON := 0.0000001

## Jittered cell sites, memoised per identity: a site is asked for by every
## fragment-style sample in its 3×3 window, by every neighbour clip in
## `polygon_for`, and once by `site_for`, so a 36,100-cell world would otherwise
## recompute each of its two sin-hashes some sixteen times over.
var _centres := {}


## Resolve the field at one world-space XZ point. `region_context.rock_mix`
## carries the slope-aware exposed-rock term that the terrain shader receives.
## `region_context.exposure_width` carries that rendered sample's effective
## `fwidth`-expanded transition, clamped to the shader's 0.035..0.25 range.
## Static geometry uses the 0.035 default so its topology is camera-independent;
## a rendered parity probe supplies the measured footprint explicitly.
## `region_context.drift`, when present, is the caller's own `ground_drift()` of
## this point — the geometry builder needs it to form `rock_mix` and would
## otherwise pay its 24 hashes twice; absent, it is computed here as before.
func sample(world_seed: int, world_xz: Vector2, region_context: Dictionary) -> Dictionary:
	var id := _plate_id(world_xz * PLATE_SCALE)
	var drift := float(region_context[&"drift"]) if region_context.has(&"drift") \
		else _ground_noise(world_xz, DRIFT_SCALE)
	var rock_mix := _f32(clampf(
		float(region_context.get(&"rock_mix", 0.0)), 0.0, 1.0))
	var exposure_width := _f32(clampf(
		float(region_context.get(&"exposure_width", ASH_CONTACT)),
		ASH_CONTACT,
		EXPOSURE_WIDTH_MAX))
	var sheet := _f32(clampf(_f32(
		_smoothstep_f32(
			-exposure_width, exposure_width, _f32(drift - EXPOSED_THRESHOLD))
		+ rock_mix), 0.0, 1.0))
	var is_slab := is_slab_identity(Vector3i(world_seed, id.x, id.y))
	return {
		&"world_seed": world_seed,
		&"id": id,
		&"identity": Vector3i(world_seed, id.x, id.y),
		&"substance": _substance(id),
		&"drift": drift,
		&"exposure_width": exposure_width,
		&"exposed": is_slab and sheet >= 0.5,
	}


## The bounded, row-major identities whose cells can meet a square world
## centred on the origin. Identities are value types: enumerating candidates
## creates no Node, mesh, material, or draw call per plate.
func candidate_identities(world_seed: int, world_size: float) -> Array[Vector3i]:
	var identities: Array[Vector3i] = []
	if not is_finite(world_size) or world_size <= 0.0:
		return identities
	var half_uv := world_size * 0.5 * PLATE_SCALE
	var minimum := floori(-half_uv) - CANDIDATE_HALO
	var maximum := floori(half_uv) + CANDIDATE_HALO
	identities.resize((maximum - minimum + 1) * (maximum - minimum + 1))
	var index := 0
	for y in range(minimum, maximum + 1):
		for x in range(minimum, maximum + 1):
			identities[index] = Vector3i(world_seed, x, y)
			index += 1
	return identities


## Exact jittered-cell Voronoi polygon for one seeded identity, in world XZ
## metres and counter-clockwise winding. The current shader partition is based
## on world coordinates rather than a seed offset, so the seed namespaces the
## identity without moving its geometry.
func polygon_for(identity: Vector3i) -> PackedVector2Array:
	var id := Vector2i(identity.y, identity.z)
	var own_centre := _centre(id)
	var polygon := PackedVector2Array([
		own_centre + Vector2(-CLIP_RADIUS, -CLIP_RADIUS),
		own_centre + Vector2(CLIP_RADIUS, -CLIP_RADIUS),
		own_centre + Vector2(CLIP_RADIUS, CLIP_RADIUS),
		own_centre + Vector2(-CLIP_RADIUS, CLIP_RADIUS),
	])
	for j in range(-2, 3):
		for i in range(-2, 3):
			if i == 0 and j == 0:
				continue
			polygon = _clip_to_bisector(
				polygon, own_centre, _centre(id + Vector2i(i, j)))
	var world_polygon := PackedVector2Array()
	world_polygon.resize(polygon.size())
	for index in polygon.size():
		world_polygon[index] = polygon[index] / PLATE_SCALE
	return world_polygon



## Whether one seeded identity carries stone at all — the shader's
## `step(0.60, hash3(vec3(plate_id * 2.3, 19.0)))` slab pick, resolved from the
## cell id alone. Geometry asks this before spending a full `sample()` on a cell:
## a cell that is not a slab has no top or lip whatever the ash sheet does.
func is_slab_identity(identity: Vector3i) -> bool:
	return _hash3(Vector3(float(identity.y), float(identity.z), 0.0) * Vector3(2.3, 2.3, 0.0)
		+ Vector3(0.0, 0.0, 19.0)) >= 0.60


## The jittered site one seeded identity's cell is measured from, in world XZ
## metres. It lies inside its own Voronoi cell by construction, so it is the one
## point whose owner is known without a search.
func site_for(identity: Vector3i) -> Vector2:
	return _centre(Vector2i(identity.y, identity.z)) / PLATE_SCALE


## The shader's broad drift field at one world XZ point — the same three-octave
## value noise `sample()` folds into its exposure decision, exposed so a caller
## can build the region context that decision takes.
func ground_drift(world_xz: Vector2) -> float:
	return _ground_noise(world_xz, DRIFT_SCALE)


## The terrain shader's slope-aware bare-rock term on the opt-in path, mirrored
## in binary32: `smoothstep(-aw, aw, slope + (drift - 0.5) * 0.22 - rock_slope)`
## with `aw` the ash contact width. `slope` is `1 - normal.y` of the flat-shaded
## terrain triangle, which is what the shader's `world_normal` carries, so static
## geometry sampling the same triangle normal receives the same answer the
## fragment does. The contact width defaults to the shader's `ash_contact`;
## a rendered probe may pass its measured `fwidth`-expanded width instead, and a
## material that overrides the `rock_slope` uniform passes its value.
func rock_mix_for(slope: float, drift: float, contact_width: float = ASH_CONTACT,
		rock_slope: float = ROCK_SLOPE) -> float:
	var aw := _f32(clampf(contact_width, ASH_CONTACT, EXPOSURE_WIDTH_MAX))
	var ash_edge := _f32(_f32(_f32(clampf(slope, 0.0, 1.0))
		+ _f32(_f32(drift - 0.5) * DRIFT_TILT)) - rock_slope)
	return _smoothstep_f32(-aw, aw, ash_edge)



func _plate_id(uv: Vector2) -> Vector2i:
	var base := Vector2i(floori(uv.x), floori(uv.y))
	var nearest := base
	var nearest_distance := INF
	for j in range(-1, 2):
		for i in range(-1, 2):
			var cell := base + Vector2i(i, j)
			var centre := _centre(cell)
			var distance := uv.distance_to(centre)
			if distance < nearest_distance:
				nearest_distance = distance
				nearest = cell
	return nearest


## Keep the part of `polygon` on the inner side of the line through `point` whose
## outward direction is `outside` — Sutherland–Hodgman against one half-plane.
## A vertex within `inside_epsilon` of the line counts as inside; consecutive
## output points closer than `weld` are one point. The one clipper the slab
## field and the slab geometry share: the field clips cells to bisectors at its
## own float precision, the geometry clips polygons to terrain cells with a
## coarser weld, and neither carries a second copy of the algorithm.
static func clip_half_plane(polygon: PackedVector2Array, point: Vector2, outside: Vector2,
		inside_epsilon: float, weld: float) -> PackedVector2Array:
	var clipped := PackedVector2Array()
	if polygon.is_empty():
		return clipped
	var previous := polygon[polygon.size() - 1]
	var previous_distance := (previous - point).dot(outside)
	var previous_inside := previous_distance <= inside_epsilon
	for current in polygon:
		var current_distance := (current - point).dot(outside)
		var current_inside := current_distance <= inside_epsilon
		if current_inside != previous_inside:
			var denominator := previous_distance - current_distance
			if absf(denominator) > inside_epsilon:
				_append_distinct(
					clipped, previous.lerp(current, previous_distance / denominator), weld)
		if current_inside:
			_append_distinct(clipped, current, weld)
		previous = current
		previous_distance = current_distance
		previous_inside = current_inside
	if clipped.size() > 1 \
			and clipped[0].distance_squared_to(clipped[clipped.size() - 1]) <= weld * weld:
		clipped.remove_at(clipped.size() - 1)
	return clipped


func _clip_to_bisector(
		polygon: PackedVector2Array,
		own_centre: Vector2,
		other_centre: Vector2) -> PackedVector2Array:
	return clip_half_plane(
		polygon, (own_centre + other_centre) * 0.5, other_centre - own_centre,
		CLIP_EPSILON, CLIP_EPSILON)


static func _append_distinct(points: PackedVector2Array, point: Vector2, weld: float) -> void:
	if points.is_empty() \
			or points[points.size() - 1].distance_squared_to(point) > weld * weld:
		points.append(point)


func _centre(id: Vector2i) -> Vector2:
	if _centres.has(id):
		return _centres[id]
	var cell := Vector2(id)
	var jitter := Vector2(
		_hash3(Vector3(cell.x, cell.y, 0.0)),
		_hash3(Vector3(cell.x, cell.y, 7.0)))
	var centre := cell + Vector2(0.15, 0.15) + 0.7 * jitter
	_centres[id] = centre
	return centre


func _substance(id: Vector2i) -> StringName:
	var cell := Vector2(id) * 1.7
	var pick := _hash3(Vector3(cell.x, cell.y, 3.0))
	if pick < 0.38:
		return &"rock"
	if pick < 0.66:
		return &"basalt"
	if pick < 0.86:
		return &"ferric"
	return &"pale"


func _ground_noise(world_xz: Vector2, scale: float) -> float:
	return _fbm(Vector3(world_xz.x, 0.0, world_xz.y) * scale)


func _fbm(p_in: Vector3) -> float:
	var p := p_in
	var amplitude := 0.5
	var total := 0.0
	for _octave in 3:
		total = _f32(total + _f32(amplitude * _value_noise(p)))
		p *= 2.03
		amplitude = _f32(amplitude * 0.5)
	return total


func _value_noise(p: Vector3) -> float:
	var cell := p.floor()
	var fraction := p - cell
	var blend := fraction * fraction * (Vector3.ONE * 3.0 - fraction * 2.0)
	var n000 := _hash3(cell)
	var n100 := _hash3(cell + Vector3(1.0, 0.0, 0.0))
	var n010 := _hash3(cell + Vector3(0.0, 1.0, 0.0))
	var n110 := _hash3(cell + Vector3(1.0, 1.0, 0.0))
	var n001 := _hash3(cell + Vector3(0.0, 0.0, 1.0))
	var n101 := _hash3(cell + Vector3(1.0, 0.0, 1.0))
	var n011 := _hash3(cell + Vector3(0.0, 1.0, 1.0))
	var n111 := _hash3(cell + Vector3(1.0, 1.0, 1.0))
	return _lerp_f32(
		_lerp_f32(
			_lerp_f32(n000, n100, blend.x),
			_lerp_f32(n010, n110, blend.x),
			blend.y),
		_lerp_f32(
			_lerp_f32(n001, n101, blend.x),
			_lerp_f32(n011, n111, blend.x),
			blend.y),
		blend.z)


func _hash3(p: Vector3) -> float:
	var dotted := p.dot(Vector3(127.1, 311.7, 74.7))
	var wave := _f32(sin(dotted))
	var value := _f32(wave * HASH_SCALE_F32)
	return _f32(value - floor(value))


func _lerp_f32(from: float, to: float, weight: float) -> float:
	var delta := _f32(to - from)
	return _f32(from + _f32(delta * weight))


func _smoothstep_f32(from: float, to: float, value: float) -> float:
	var weight := _f32(_f32(value - from) / _f32(to - from))
	weight = _f32(clampf(weight, 0.0, 1.0))
	return _f32(_f32(weight * weight) * _f32(3.0 - _f32(2.0 * weight)))


## Standard Godot vectors store binary32 components. Round-tripping one scalar
## through a component makes every mirrored shader scalar operation explicit
## without allocating a PackedFloat32Array for each of millions of hash calls.
func _f32(value: float) -> float:
	return Vector2(value, 0.0).x
