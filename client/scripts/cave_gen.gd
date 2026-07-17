@tool
class_name CaveGen
extends Node3D
## Phase 0 art pipeline, stage 1: a procedural cave chamber, generated
## entirely in-engine ("as code" — no imported assets, no external DCC tool).
##
## @tool means this script runs live in the editor viewport: open a scene with
## a CaveGen node, change SEED or RADIUS in the inspector, and the cave
## rebuilds before your eyes — the taste gate is judged there, lit by the
## scene's SDFGI environment. The same script runs headless in CI (the
## determinism regression test) and can generate instanced caves at runtime
## later — one generator, three surfaces.
##
## Fully deterministic from `seed_value`: FastNoiseLite is seeded and the
## icosphere construction is order-stable, so the same seed produces an
## identical vertex stream (the test fingerprints it).

const SUBDIVISIONS := 5
const ENTRANCE_DEG := 22.0 ## Half-angle of the mouth cut toward +X.
const FLOOR_FRACTION := -0.55 ## Floor band height as a fraction of radius.
const COL_ROCK_DARK := Color(0.16, 0.14, 0.13)
const COL_ROCK_WARM := Color(0.32, 0.28, 0.24)

@export var seed_value: int = 42:
	set(v):
		seed_value = v
		if is_inside_tree():
			rebuild()
@export var radius: float = 8.0:
	set(v):
		radius = v
		if is_inside_tree():
			rebuild()

var _mesh_instance: MeshInstance3D


func _ready() -> void:
	rebuild()


## Rebuilds the chamber mesh from the current parameters.
func rebuild() -> void:
	if _mesh_instance != null:
		_mesh_instance.queue_free()
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.mesh = build_mesh(seed_value, radius)
	add_child(_mesh_instance)


## Pure mesh construction — static so tests can call it without a scene tree.
static func build_mesh(p_seed: int, p_radius: float) -> ArrayMesh:
	var carved := _carve(p_seed, p_radius)
	var verts: PackedVector3Array = carved[0]
	var tris: PackedInt32Array = carved[1]
	var is_floor: PackedByteArray = carved[2]

	# Entrance: drop triangles inside the mouth corridor toward +X. The
	# corridor is judged on the HORIZONTAL direction (Y projected out) — a
	# radial cone stops at -radius*sin(22°), ~1.4 m above the floor band,
	# which left a shell lip the player had to climb (codex review, twice:
	# first the Go prototype, then the radial port of this cut). Pure floor
	# triangles (all three vertices flattened) stay, so the opening reaches
	# exactly down to the walkable surface; mixed floor/wall stitching rows
	# in the corridor are cut with the wall. The cone's top edge bounds the
	# mouth height so it stays a doorway, not a full-height slice. Windings
	# are flipped so the interior is the visible side (the camera lives
	# inside).
	var cone := cos(deg_to_rad(ENTRANCE_DEG))
	var mouth_top := p_radius * sin(deg_to_rad(ENTRANCE_DEG))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for t in range(0, tris.size(), 3):
		var a := verts[tris[t]]
		var b := verts[tris[t + 1]]
		var c := verts[tris[t + 2]]
		var all_floor := is_floor[tris[t]] == 1 \
			and is_floor[tris[t + 1]] == 1 and is_floor[tris[t + 2]] == 1
		var center := (a + b + c) / 3.0
		var flat := Vector3(center.x, 0.0, center.z)
		if not all_floor and center.y < mouth_top and flat.length() > 0.001 \
			and (flat / flat.length()).dot(Vector3(1, 0, 0)) > cone:
			continue
		st.add_vertex(a)
		st.add_vertex(c)
		st.add_vertex(b)
	st.generate_normals()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = COL_ROCK_DARK.lerp(COL_ROCK_WARM, 0.35)
	mat.roughness = 0.95
	st.set_material(mat)
	return st.commit()


## The carved chamber shape shared by the interior and shell meshes:
## displace an icosphere along its normals by fractal noise, flatten a floor
## band. The floor is flattened along Y — Godot's elevation axis (WorldGen
## emits Vector3(x, height, z) and player gravity acts on velocity.y), so the
## walkable plane must be a constant-Y band, not constant-Z. Flattened
## vertices are tracked so the entrance cut can tell floor triangles from
## wall shell exactly, with no normal/height threshold tuning.
## Returns [PackedVector3Array verts, PackedInt32Array tris, PackedByteArray is_floor].
static func _carve(p_seed: int, p_radius: float) -> Array:
	var noise := FastNoiseLite.new()
	noise.seed = p_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	noise.frequency = 1.6 / p_radius

	var rng := RandomNumberGenerator.new()
	rng.seed = p_seed
	var roughness := rng.randf_range(0.16, 0.24)
	var floor_y := FLOOR_FRACTION * p_radius

	var sphere := _icosphere(SUBDIVISIONS)
	var verts: PackedVector3Array = sphere[0]
	var tris: PackedInt32Array = sphere[1]

	var is_floor := PackedByteArray()
	is_floor.resize(verts.size())
	for i in verts.size():
		var pos := verts[i] * p_radius
		var d := noise.get_noise_3dv(pos)
		pos += verts[i] * (d * roughness * p_radius)
		if pos.y < floor_y:
			var rumple := 0.08 * p_radius * noise.get_noise_3d(pos.x * 3.0 / p_radius, pos.z * 3.0 / p_radius, 7.31)
			pos.y = floor_y + rumple
			is_floor[i] = 1
		verts[i] = pos
	return [verts, tris, is_floor]


## The chamber's OUTSIDE: the same carved shape pushed outward a little and
## wound so the exterior is the visible side — the rock dome the cave lives
## inside when it stands in the open world. The same entrance corridor is cut
## so the mouth opens through both meshes.
static func build_shell_mesh(p_seed: int, p_radius: float, p_thickness := 0.4) -> ArrayMesh:
	var carved := _carve(p_seed, p_radius)
	var verts: PackedVector3Array = carved[0]
	var tris: PackedInt32Array = carved[1]
	var is_floor: PackedByteArray = carved[2]
	var grow := 1.0 + p_thickness / p_radius

	var cone := cos(deg_to_rad(ENTRANCE_DEG))
	var mouth_top := p_radius * sin(deg_to_rad(ENTRANCE_DEG))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for t in range(0, tris.size(), 3):
		var a := verts[tris[t]]
		var b := verts[tris[t + 1]]
		var c := verts[tris[t + 2]]
		var all_floor := is_floor[tris[t]] == 1 \
			and is_floor[tris[t + 1]] == 1 and is_floor[tris[t + 2]] == 1
		if all_floor:
			continue  # The shell has no outside floor — terrain is the ground.
		var center := (a + b + c) / 3.0
		var flat := Vector3(center.x, 0.0, center.z)
		if center.y < mouth_top and flat.length() > 0.001 \
			and (flat / flat.length()).dot(Vector3(1, 0, 0)) > cone:
			continue
		# Winding NOT flipped: the visible side faces outward.
		st.add_vertex(a * grow)
		st.add_vertex(b * grow)
		st.add_vertex(c * grow)
	st.generate_normals()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = COL_ROCK_DARK.lerp(COL_ROCK_WARM, 0.2)
	mat.roughness = 0.97
	st.set_material(mat)
	return st.commit()


## Order-stable fingerprint of the generated geometry; the determinism test
## compares it across builds.
static func fingerprint(mesh: ArrayMesh) -> String:
	var arrays := mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var aabb := AABB(v[0], Vector3.ZERO)
	for p in v:
		aabb = aabb.expand(p)
	return "verts=%d hash=%d aabb=%s" % [v.size(), hash(v.to_byte_array()), aabb]


## Icosphere as [PackedVector3Array verts, PackedInt32Array tris]; construction
## is fully order-stable (fixed seed vertices, midpoint cache on sorted edges).
## Built on a by-reference Array (packed arrays copy on argument passing in
## GDScript, which would drop midpoints added inside a helper).
static func _icosphere(subdivisions: int) -> Array:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var verts: Array[Vector3] = [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
	]
	for i in verts.size():
		verts[i] = verts[i].normalized()
	var tris := PackedInt32Array([
		0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11,
		1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
		3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9,
		4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
	])
	for _s in subdivisions:
		var cache := {}
		var next := PackedInt32Array()
		for t_i in range(0, tris.size(), 3):
			var a := tris[t_i]
			var b := tris[t_i + 1]
			var c := tris[t_i + 2]
			var ab := _midpoint(cache, verts, a, b)
			var bc := _midpoint(cache, verts, b, c)
			var ca := _midpoint(cache, verts, c, a)
			next.append_array(PackedInt32Array([a, ab, ca, b, bc, ab, c, ca, bc, ab, bc, ca]))
		tris = next
	return [PackedVector3Array(verts), tris]


static func _midpoint(cache: Dictionary, verts: Array[Vector3], a: int, b: int) -> int:
	var key := Vector2i(mini(a, b), maxi(a, b))
	if cache.has(key):
		return cache[key]
	verts.push_back(((verts[a] + verts[b]) * 0.5).normalized())
	cache[key] = verts.size() - 1
	return cache[key]
