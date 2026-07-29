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


## Resolve the field at one world-space XZ point. `region_context.rock_mix`
## carries the slope-aware exposed-rock term that the terrain shader receives.
## `region_context.exposure_width` carries that rendered sample's effective
## `fwidth`-expanded transition, clamped to the shader's 0.035..0.25 range.
## Static geometry uses the 0.035 default so its topology is camera-independent;
## a rendered parity probe supplies the measured footprint explicitly.
func sample(world_seed: int, world_xz: Vector2, region_context: Dictionary) -> Dictionary:
	var id := _plate_id(world_xz * PLATE_SCALE)
	var drift := _ground_noise(world_xz, DRIFT_SCALE)
	var rock_mix := _f32(clampf(
		float(region_context.get(&"rock_mix", 0.0)), 0.0, 1.0))
	var exposure_width := _f32(clampf(
		float(region_context.get(&"exposure_width", ASH_CONTACT)),
		ASH_CONTACT,
		EXPOSURE_WIDTH_MAX))
	var sheet := _f32(clampf(_f32(
		smoothstep(-exposure_width, exposure_width, _f32(drift - EXPOSED_THRESHOLD))
		+ rock_mix), 0.0, 1.0))
	var is_slab := _hash3(Vector3(float(id.x), float(id.y), 0.0) * Vector3(2.3, 2.3, 0.0)
		+ Vector3(0.0, 0.0, 19.0)) >= 0.60
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


func _clip_to_bisector(
		polygon: PackedVector2Array,
		own_centre: Vector2,
		other_centre: Vector2) -> PackedVector2Array:
	var clipped := PackedVector2Array()
	if polygon.is_empty():
		return clipped
	var normal := other_centre - own_centre
	var midpoint := (own_centre + other_centre) * 0.5
	var previous := polygon[polygon.size() - 1]
	var previous_distance := (previous - midpoint).dot(normal)
	var previous_inside := previous_distance <= CLIP_EPSILON
	for current in polygon:
		var current_distance := (current - midpoint).dot(normal)
		var current_inside := current_distance <= CLIP_EPSILON
		if current_inside != previous_inside:
			var denominator := previous_distance - current_distance
			if absf(denominator) > CLIP_EPSILON:
				var t := previous_distance / denominator
				_append_distinct(clipped, previous.lerp(current, t))
		if current_inside:
			_append_distinct(clipped, current)
		previous = current
		previous_distance = current_distance
		previous_inside = current_inside
	if clipped.size() > 1 \
			and clipped[0].distance_squared_to(clipped[clipped.size() - 1]) \
				<= CLIP_EPSILON * CLIP_EPSILON:
		clipped.remove_at(clipped.size() - 1)
	return clipped


func _append_distinct(points: PackedVector2Array, point: Vector2) -> void:
	if points.is_empty() \
			or points[points.size() - 1].distance_squared_to(point) \
				> CLIP_EPSILON * CLIP_EPSILON:
		points.append(point)


func _centre(id: Vector2i) -> Vector2:
	var cell := Vector2(id)
	var jitter := Vector2(
		_hash3(Vector3(cell.x, cell.y, 0.0)),
		_hash3(Vector3(cell.x, cell.y, 7.0)))
	return cell + Vector2(0.15, 0.15) + 0.7 * jitter


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


## Standard Godot vectors store binary32 components. Round-tripping one scalar
## through a component makes every mirrored shader scalar operation explicit
## without allocating a PackedFloat32Array for each of millions of hash calls.
func _f32(value: float) -> float:
	return Vector2(value, 0.0).x
