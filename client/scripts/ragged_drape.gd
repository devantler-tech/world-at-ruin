class_name RaggedDrape
extends RefCounted
## Original static folds on the existing closed ragged wrap. No simulation or
## save mutation. The default-off decision/removal task is #950 (2026-11-01).
## The source's topology and normalized morph deltas are retained verbatim;
## the same base-space offset is added to every absolute morph target.

const FLAG_ENV := "WAR_RAGGED_CLOTH_DRAPE"
const SOURCE_META := "ragged_drape_source"
const DERIVATIVE_STEP := 0.0002


static func enabled() -> bool:
	return OS.get_environment(FLAG_ENV) == "1"


## Each composed character owns its mesh. Imported resources, material and
## skin stay shared and untouched; no derived cache can leak a later edit.
static func mesh(source: ArrayMesh) -> ArrayMesh:
	var result := ArrayMesh.new()
	result.blend_shape_mode = source.blend_shape_mode
	for shape in source.get_blend_shape_count():
		result.add_blend_shape(source.get_blend_shape_name(shape))
	for surface in source.get_surface_count():
		var arrays := source.surface_get_arrays(surface)
		var base: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var offsets := PackedVector3Array()
		var frames: Array[Basis] = []
		for point: Vector3 in base:
			offsets.append(_drape(point) - point)
			frames.append(_frame(point))
		var blends := source.surface_get_blend_shape_arrays(surface)
		_transform(arrays, offsets, frames, true)
		for blend: Array in blends:
			_transform(blend, offsets, frames, source.blend_shape_mode == Mesh.BLEND_SHAPE_MODE_NORMALIZED)
		var flags := source.surface_get_format(surface) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		result.add_surface_from_arrays(source.surface_get_primitive_type(surface), arrays, blends, {}, flags)
		result.surface_set_material(surface, source.surface_get_material(surface))
		result.surface_set_name(surface, source.surface_get_name(surface))
	return result


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
static func _frame(point: Vector3) -> Basis:
	var axes: Array[Vector3] = []
	for axis: Vector3 in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
		var step := axis * DERIVATIVE_STEP
		axes.append((_drape(point + step) - _drape(point - step)) / (2.0 * DERIVATIVE_STEP))
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
