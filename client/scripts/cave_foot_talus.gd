class_name CaveFootTalus
extends RefCounted
## Deterministic, render-only talus placement for the starter cave foot.
##
## The terrain-contact mesh is the authority: every stone starts from a
## sky-exposed contact triangle, then moves a short distance along the rock's
## outward normal before being dropped onto the supplied ground sampler. This
## keeps the treatment attached to the cave instead of becoming another
## unrelated world scatter. The returned dictionaries use FoliageGen's closed
## cosmetic schema and deliberately carry no collision or gameplay data.

const MAX_PLACEMENTS := 72
const MIN_SEPARATION := 1.25
const CONTACT_QUANTUM := 1.0 / 255.0
const MIN_OFFSET := 1.65
const MAX_OFFSET := 2.30
const MOUTH_BACK := 4.0
const MOUTH_HALF_WIDTH := 4.5


## Produce cosmetic rubble placements from `contact_mesh`.
##
## Missing or malformed source data fails closed. An owned RNG makes the result
## independent of the process-global random stream.
func placements(contact_mesh: ArrayMesh, ground: Callable,
		mouth: Vector3, authored_seed: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if contact_mesh == null or not ground.is_valid() \
			or contact_mesh.get_surface_count() == 0:
		return out

	var arrays: Array = contact_mesh.surface_get_arrays(0)
	if arrays.size() < Mesh.ARRAY_MAX:
		return out
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if verts.is_empty() or normals.size() != verts.size() \
			or colors.size() != verts.size() or indices.size() % 3 != 0:
		return out

	var rng := RandomNumberGenerator.new()
	rng.seed = authored_seed
	var candidates: Array[Dictionary] = []
	for tri: int in range(0, indices.size(), 3):
		var ia: int = indices[tri]
		var ib: int = indices[tri + 1]
		var ic: int = indices[tri + 2]
		if ia < 0 or ib < 0 or ic < 0 \
				or ia >= verts.size() or ib >= verts.size() or ic >= verts.size():
			continue
		if maxf(colors[ia].a, maxf(colors[ib].a, colors[ic].a)) < CONTACT_QUANTUM:
			continue

		var centre: Vector3 = (verts[ia] + verts[ib] + verts[ic]) / 3.0
		var outward_3d: Vector3 = normals[ia] + normals[ib] + normals[ic]
		var outward := Vector2(outward_3d.x, outward_3d.z)
		if outward.length_squared() < 0.01:
			outward = Vector2(centre.x - mouth.x, centre.z - mouth.z)
		if outward.length_squared() < 0.01:
			continue
		outward = outward.normalized()
		if centre.x >= mouth.x - 8.0:
			# At the approach-facing foot, bias the short fall outward toward
			# the player. Otherwise the entrance's established jamb boulders
			# occlude the new debris from the committed cave-mouth vantage.
			outward = (outward + Vector2.RIGHT * 1.15).normalized()

		# Tangential jitter breaks a mathematically even ring while remaining
		# tied to this triangle and comfortably inside the contact-reach budget.
		var tangent := Vector2(-outward.y, outward.x)
		var offset: float = rng.randf_range(MIN_OFFSET, MAX_OFFSET)
		var sideways: float = rng.randf_range(-0.28, 0.28)
		var xz := Vector2(centre.x, centre.z) + outward * offset + tangent * sideways
		if _inside_mouth_corridor(xz, mouth):
			continue
		var y := float(ground.call(xz.x, xz.y))
		if not is_finite(y):
			continue
		candidates.append({
			"kind": FoliageGen.Kind.RUBBLE,
			"pos": Vector3(xz.x, y, xz.y),
			"yaw": rng.randf_range(0.0, TAU),
			# The shared mesh is a palm-sized ground-rubble cluster. Talus has
			# to bridge massif scale, so each placement becomes a half- to
			# one-metre angular heap instead of an invisible pebble at the
			# committed player-height approach camera.
			"scale": rng.randf_range(2.2, 3.8),
		})

	# Seeded candidate order prevents a mesh's index origin from making one side
	# win every spacing conflict. Fisher-Yates uses only this helper's RNG.
	for i: int in range(candidates.size() - 1, 0, -1):
		var swap_index: int = rng.randi_range(0, i)
		var held: Dictionary = candidates[i]
		candidates[i] = candidates[swap_index]
		candidates[swap_index] = held

	var min_separation_sq := MIN_SEPARATION * MIN_SEPARATION
	for candidate: Dictionary in candidates:
		var pos: Vector3 = candidate[&"pos"]
		var blocked := false
		for existing: Dictionary in out:
			var other: Vector3 = existing[&"pos"]
			var delta := Vector2(pos.x - other.x, pos.z - other.z)
			if delta.length_squared() < min_separation_sq:
				blocked = true
				break
		if blocked:
			continue
		out.append(candidate)
		if out.size() >= MAX_PLACEMENTS:
			break
	return out


static func _inside_mouth_corridor(point: Vector2, mouth: Vector3) -> bool:
	return point.x >= mouth.x - MOUTH_BACK \
		and absf(point.y - mouth.z) < MOUTH_HALF_WIDTH
