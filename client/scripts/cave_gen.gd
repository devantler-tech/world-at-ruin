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
	var noise := FastNoiseLite.new()
	noise.seed = p_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	noise.frequency = 1.6 / p_radius

	var rng := RandomNumberGenerator.new()
	rng.seed = p_seed
	var roughness := rng.randf_range(0.16, 0.24)
	var floor_z := FLOOR_FRACTION * p_radius

	var sphere := _icosphere(SUBDIVISIONS)
	var verts: PackedVector3Array = sphere[0]
	var tris: PackedInt32Array = sphere[1]

	# Carve: displace along the normal by fractal noise, flatten a floor band.
	for i in verts.size():
		var pos := verts[i] * p_radius
		var d := noise.get_noise_3dv(pos)
		pos += verts[i] * (d * roughness * p_radius)
		if pos.z < floor_z:
			var rumple := 0.08 * p_radius * noise.get_noise_3d(pos.x * 3.0 / p_radius, pos.y * 3.0 / p_radius, 7.31)
			pos.z = floor_z + rumple
		verts[i] = pos

	# Entrance: drop triangles whose outward direction is within the cone
	# toward +X and above the floor band; flip windings so the interior is
	# the visible side (the camera lives inside).
	var cone := cos(deg_to_rad(ENTRANCE_DEG))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for t in range(0, tris.size(), 3):
		var a := verts[tris[t]]
		var b := verts[tris[t + 1]]
		var c := verts[tris[t + 2]]
		var center := (a + b + c) / 3.0
		if center.normalized().dot(Vector3(1, 0, 0)) > cone and center.z > floor_z * 0.5:
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
