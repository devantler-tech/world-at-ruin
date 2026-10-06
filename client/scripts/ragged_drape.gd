class_name RaggedDrape
extends RefCounted
## Original static folds on the existing closed ragged wrap. No simulation or
## save mutation. The default-off decision/removal task is #950 (2026-11-01).
## The source's topology and normalized morph deltas are retained verbatim;
## the same base-space offset is added to every absolute morph target.

const FLAG_ENV := "WAR_RAGGED_CLOTH_DRAPE"
const REFINEMENT_FLAG_ENV := "WAR_RAGGED_WRAP_REFINEMENT"
const SOURCE_META := "ragged_drape_source"
const SKIN_SOURCE_META := "ragged_waist_skin_source"
const DERIVATIVE_STEP := 0.0002
const WAIST_ATTACHMENT := 0.888
const WAIST_TOP := 0.913
const HEM := [0.020, -0.012, 0.009, -0.026, 0.015, -0.005, 0.024]


static func enabled() -> bool:
	return OS.get_environment(FLAG_ENV) == "1"


static func refinement_enabled() -> bool:
	return enabled() and OS.get_environment(REFINEMENT_FLAG_ENV) == "1"


## Each composed character owns its mesh. Imported resources, material and
## skin stay shared and untouched; no derived cache can leak a later edit.
static func mesh(source: ArrayMesh, refine: bool = false, shapes: Dictionary = {}) -> ArrayMesh:
	var result := ArrayMesh.new()
	result.blend_shape_mode = source.blend_shape_mode
	for shape in source.get_blend_shape_count():
		result.add_blend_shape(source.get_blend_shape_name(shape))
	for surface in source.get_surface_count():
		var arrays := source.surface_get_arrays(surface)
		var scale := _shell_scale(source, surface, shapes) if refine else 1.0
		var base: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var offsets := PackedVector3Array()
		var frames: Array[Basis] = []
		for point: Vector3 in base:
			offsets.append(_deform(point, refine, scale) - point)
			frames.append(_frame(point, refine, scale))
		var blends := source.surface_get_blend_shape_arrays(surface)
		_transform(arrays, offsets, frames, true)
		for blend: Array in blends:
			_transform(blend, offsets, frames, source.blend_shape_mode == Mesh.BLEND_SHAPE_MODE_NORMALIZED)
		var flags := source.surface_get_format(surface) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		result.add_surface_from_arrays(source.surface_get_primitive_type(surface), arrays, blends, {}, flags)
		result.surface_set_material(surface, source.surface_get_material(surface))
		result.surface_set_name(surface, source.surface_get_name(surface))
	return result


## Keep every original positional morph delta, but choose a base thinning
## that cannot invert the actual selected shape. Rebuild on live slider edits.
static func sync_shape(garment: MeshInstance3D) -> void:
	var values := {}
	for shape in garment.mesh.get_blend_shape_count():
		values[garment.mesh.get_blend_shape_name(shape)] = garment.get_blend_shape_value(shape)
	garment.mesh = mesh(garment.get_meta(SOURCE_META) as ArrayMesh, refinement_enabled(), values)
	for shape in garment.mesh.get_blend_shape_count():
		garment.set_blend_shape_value(shape, values[garment.mesh.get_blend_shape_name(shape)])


static func _shell_scale(source: ArrayMesh, surface: int, shapes: Dictionary) -> float:
	var base: PackedVector3Array = source.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
	var selected := base.duplicate()
	var blends := source.surface_get_blend_shape_arrays(surface)
	for shape in source.get_blend_shape_count():
		var weight := float(shapes.get(source.get_blend_shape_name(shape), 0.0))
		if is_zero_approx(weight):
			continue
		var target: PackedVector3Array = blends[shape][Mesh.ARRAY_VERTEX]
		for i in base.size():
			selected[i] += (target[i] - base[i] if source.blend_shape_mode == Mesh.BLEND_SHAPE_MODE_NORMALIZED else target[i]) * weight
	var pairs := {}
	for i in base.size():
		var point := base[i]
		if absf(point.y - WAIST_ATTACHMENT) < 0.000001 or absf(point.y - 0.940) < 0.000001:
			continue
		var key := Vector3i(roundi(point.x * 1000000.0), roundi(point.y * 1000000.0), signi(roundi(point.z * 1000000.0)))
		var pair: Vector2i = pairs.get(key, Vector2i(i, i))
		if point.z < base[pair.x].z:
			pair.x = i
		if point.z > base[pair.y].z:
			pair.y = i
		pairs[key] = pair
	var scale := _band_scale(base, selected, source.surface_get_arrays(surface)[Mesh.ARRAY_INDEX])
	for pair: Vector2i in pairs.values():
		var original := base[pair.y].z - base[pair.x].z
		if original > 0.00001:
			var gap := selected[pair.y].z - selected[pair.x].z
			scale = maxf(scale, 1.0 + (0.001 - gap) / original)
	return scale


## Short source-topology edges join the radial inner and outer band faces.
## Protect their actual selected gap too, independently of panel correspondence.
static func _band_scale(base: PackedVector3Array, selected: PackedVector3Array,
		indices: PackedInt32Array) -> float:
	var scale := 0.28
	for triangle in range(0, indices.size(), 3):
		for edge in 3:
			var a := indices[triangle + edge]
			var b := indices[triangle + (edge + 1) % 3]
			if absf(base[a].y - WAIST_ATTACHMENT) > 0.000001 and absf(base[a].y - 0.940) > 0.000001:
				continue
			if absf(base[a].y - base[b].y) > 0.000001:
				continue
			var original := base[b] - base[a]
			if original.length() < 0.00001 or original.length() > 0.012:
				continue
			var direction := original.normalized()
			var collapsed := _refine(base[b], 0.0) - _refine(base[a], 0.0)
			var removed := (original - collapsed).dot(direction)
			if removed > 0.00001:
				var gap := (selected[b] - selected[a]).dot(direction)
				scale = maxf(scale, 1.0 + (0.001 - gap) / removed)
	return scale


## The narrower band exposes skin the imported equipment morph tucked inward.
## Restore only that upper strip in a private body mesh; player-authored shape
## targets and every other equipment inset remain byte-identical.
static func waist_skin(source: ArrayMesh) -> ArrayMesh:
	var result := ArrayMesh.new()
	result.blend_shape_mode = source.blend_shape_mode
	var hide := -1
	for shape in source.get_blend_shape_count():
		var name := source.get_blend_shape_name(shape)
		result.add_blend_shape(name)
		if name == "equip_hide_loincloth_ragged":
			hide = shape
	for surface in source.get_surface_count():
		var arrays := source.surface_get_arrays(surface)
		var blends := source.surface_get_blend_shape_arrays(surface)
		if hide >= 0:
			var base: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var target: PackedVector3Array = blends[hide][Mesh.ARRAY_VERTEX]
			for i in base.size():
				var reveal := smoothstep(0.900, WAIST_TOP, base[i].y)
				var intact := base[i] if source.blend_shape_mode == Mesh.BLEND_SHAPE_MODE_NORMALIZED else Vector3.ZERO
				target[i] = target[i].lerp(intact, reveal)
			blends[hide][Mesh.ARRAY_VERTEX] = target
			for slot: int in [Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT]:
				var values = blends[hide][slot]
				var intact = arrays[slot]
				var components := 1 if slot == Mesh.ARRAY_NORMAL else 4
				for i in base.size():
					var reveal := smoothstep(0.900, WAIST_TOP, base[i].y)
					for component in components:
						var index := i * components + component
						var normal_value = intact[index] if source.blend_shape_mode == Mesh.BLEND_SHAPE_MODE_NORMALIZED else intact[index] * 0.0
						values[index] = values[index].lerp(normal_value, reveal) if slot == Mesh.ARRAY_NORMAL else lerpf(values[index], normal_value, reveal)
				blends[hide][slot] = values
		var flags := source.surface_get_format(surface) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		result.add_surface_from_arrays(source.surface_get_primitive_type(surface), arrays, blends, {}, flags)
		result.surface_set_material(surface, source.surface_get_material(surface))
		result.surface_set_name(surface, source.surface_get_name(surface))
	return result


static func _deform(point: Vector3, refine: bool, scale: float = 0.28) -> Vector3:
	return _drape(_refine(point, scale)) if refine else _drape(point)


## Thin a closed shell toward its retained exterior, then ease the band from
## 52 to 25 mm. The original attachment is fixed and the y derivative remains
## positive, so shared seams and front/rear overlap stay closed.
static func _refine(point: Vector3, scale: float = 0.28) -> Vector3:
	var result := point
	if absf(point.y - WAIST_ATTACHMENT) < 0.0005 or absf(point.y - 0.940) < 0.0005:
		var depth := 0.116 if point.z >= 0.018 else 0.113
		var angle := atan2((point.z - 0.018) / depth, point.x / 0.158)
		var exterior := Vector3(0.158 * cos(angle), point.y, 0.018 + depth * sin(angle))
		result = exterior + (point - exterior) * scale
	else:
		var exterior := _panel_exterior(point)
		result.z = exterior + (point.z - exterior) * scale
	result.y -= 0.027 * smoothstep(WAIST_ATTACHMENT, 0.940, point.y)
	return result


## Recover the original generator's panel coordinates, rather than assuming
## exporter vertex order. Smooth interpolation through its authored hem knots
## keeps finite-difference lighting continuous beside the stored grid points.
static func _panel_exterior(point: Vector3) -> float:
	var front := point.z > 0.0
	var length := 0.223 if front else 0.173
	var width := 0.137 if front else 0.126
	var taper := 0.040 if front else 0.038
	var t := clampf((0.908 - point.y) / length, 0.0, 1.0)
	var u := 0.5
	for iteration in 10:
		u = clampf(0.5 + point.x / (2.0 * (width - taper * t)), 0.0, 1.0)
		var h := _hem(u if front else 1.0 - u) * (1.0 if front else 0.65)
		t = clampf((0.908 - point.y) / (length - h), 0.0, 1.0)
	var fold := (0.006 + 0.009 * t) * cos(3.0 * PI * u)
	return 0.119 + fold if front else -0.086 - fold


static func _hem(u: float) -> float:
	var position := clampf(u, 0.0, 1.0) * 6.0
	var index := mini(floori(position), 5)
	return lerpf(HEM[index], HEM[index + 1], smoothstep(0.0, 1.0, position - index))


## The belt is pinned; both sides of a flap receive the same displacement so
## thickness and joins remain closed. Folds open outward and soften the hem
## without narrowing the existing opaque coverage.
static func _drape(point: Vector3) -> Vector3:
	if point.y >= 0.888:
		return point
	var t := clampf((0.888 - point.y) / 0.20, 0.0, 1.25)
	# Ten millimetres of smooth onset avoids a kink in both positions and
	# lighting at the pinned waist. Clearance keeps its independent depth
	# ramp instead of being delayed by the gather's onset.
	var hanging := t * smoothstep(0.0, 0.05, t)
	var u := point.x / 0.14
	var side := 1.0 if point.z > 0.0 else -1.0
	var fold := 0.5 + 0.5 * cos(u * PI * 2.0 + t * 0.55)
	# The upper rear panel needs clearance from the standing body's curvature.
	# A smooth onset leaves both the closed belt and its lighting frame pinned;
	# the identical offset on every target preserves saved positional morphs.
	var rear_allowance := 0.008 * smoothstep(0.0, 0.15, t) if point.z < 0.0 else 0.0
	return point + Vector3(point.x * 0.10 * hanging,
		-0.009 * hanging * (0.65 + 0.35 * cos(u * PI)),
		side * (hanging * (0.012 + 0.018 * fold + 0.005 * t) + rear_allowance))


## Transform authored smooth normals and tangents by the deformation's
## Jacobian. Rebuilding triangle normals would introduce the imported UV
## seams into lighting and turn smooth cloth into disconnected flat facets.
static func _frame(point: Vector3, refine: bool = false, scale: float = 0.28) -> Basis:
	var axes: Array[Vector3] = []
	for axis: Vector3 in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
		var step := axis * DERIVATIVE_STEP
		axes.append((_deform(point + step, refine, scale) - _deform(point - step, refine, scale)) / (2.0 * DERIVATIVE_STEP))
	return Basis(axes[0], axes[1], axes[2])


static func _transform(arrays: Array, offsets: PackedVector3Array, frames: Array[Basis], absolute: bool) -> void:
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
	for index in positions.size():
		if absolute:
			positions[index] += offsets[index]
		var normal := frames[index].inverse().transposed() * normals[index]
		normals[index] = normal.normalized() if absolute else normal
		var tangent := frames[index] * Vector3(tangents[index * 4], tangents[index * 4 + 1], tangents[index * 4 + 2])
		if absolute:
			tangent = (tangent - normals[index] * tangent.dot(normals[index])).normalized()
		for component in 3:
			tangents[index * 4 + component] = tangent[component]
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
