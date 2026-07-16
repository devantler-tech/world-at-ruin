class_name WorldGen
extends Node3D
## Generates the Ashfall Reach slice: terrain, scattered ruins, and the
## Wardens' shrine.
##
## Fully deterministic from SEED — the same world every boot, so differences
## between builds are attributable to code changes, never to chance. All
## geometry is engine primitives and generated meshes; there are no imported
## assets ("as code" premise).

const WORLD_SEED := 1409
const SIZE := 220.0 ## World edge length in metres.
const QUADS := 128 ## Terrain grid resolution per edge.
const HEIGHT_AMP := 7.0
const RUIN_SITES := 44
const SHRINE_CLEAR_RADIUS := 14.0 ## Kept nearly flat and free of ruins.

## Palette — ash, rock, bone, ember.
const COL_ASH := Color(0.38, 0.345, 0.31)
const COL_ROCK := Color(0.24, 0.22, 0.21)
const COL_SCORCH := Color(0.16, 0.14, 0.13)
const COL_STONE := Color(0.42, 0.39, 0.35)
const COL_EMBER := Color(1.0, 0.55, 0.18)

## Returned by surface_height_at outside the terrain grid: "no ground here".
const NO_GROUND := -1.0e6

var _noise := FastNoiseLite.new()
var _detail := FastNoiseLite.new()
var _tint := FastNoiseLite.new()
var _heights := PackedFloat32Array()
var _brazier_light: OmniLight3D
var _brazier_mesh: MeshInstance3D
var _time := 0.0

func _ready() -> void:
	_noise.seed = WORLD_SEED
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.frequency = 0.011
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = 4
	_detail.seed = WORLD_SEED + 1
	_detail.frequency = 0.09
	_tint.seed = WORLD_SEED + 2
	_tint.frequency = 0.05
	_build_terrain()
	_scatter_ruins()
	_build_shrine()

func _process(delta: float) -> void:
	_time += delta
	if _brazier_light:
		# Slow ember breathing, with a faint flicker on top.
		var pulse := 2.2 + 0.5 * sin(_time * 1.4) + 0.15 * sin(_time * 9.7)
		_brazier_light.light_energy = pulse
		var mat := _brazier_mesh.get_surface_override_material(0) as StandardMaterial3D
		mat.emission_energy_multiplier = 1.6 + 0.4 * sin(_time * 1.4)

## Terrain height at world (x, z). Shared by generation, collision, and
## anything that needs to stand on the ground.
func height_at(x: float, z: float) -> float:
	var h := _noise.get_noise_2d(x, z) * HEIGHT_AMP
	h += _detail.get_noise_2d(x, z) * 0.6
	# Ease toward flat within the shrine clearing so the spawn reads as a
	# kept, deliberate place amid the ruin.
	var d := Vector2(x, z).length()
	var keep := smoothstep(0.35, 1.0, clampf(d / SHRINE_CLEAR_RADIUS, 0.0, 1.0))
	return lerpf(h * 0.12, h, keep)

## Height of the actual walkable terrain MESH at world (x, z): the same
## piecewise-linear interpolation of the height grid the collision trimesh is
## built from, including the quad→triangle split. This — not the smooth
## height_at noise — is what physics stands on; anything comparing a body to
## the ground must use it (mid-triangle the two can differ by tens of cm).
## Returns NO_GROUND outside the terrain bounds.
func surface_height_at(x: float, z: float) -> float:
	var step := SIZE / QUADS
	var half := SIZE / 2.0
	var gx := (x + half) / step
	var gz := (z + half) / step
	if gx < 0.0 or gz < 0.0 or gx > QUADS or gz > QUADS or _heights.is_empty():
		return NO_GROUND
	var ix := mini(int(gx), QUADS - 1)
	var iz := mini(int(gz), QUADS - 1)
	var fx := gx - ix
	var fz := gz - iz
	var w := QUADS + 1
	var h00 := _heights[iz * w + ix]
	var h10 := _heights[iz * w + ix + 1]
	var h01 := _heights[(iz + 1) * w + ix]
	var h11 := _heights[(iz + 1) * w + ix + 1]
	# Quads split along the v00→v11 diagonal (see _build_terrain): the
	# (v00, v11, v10) triangle covers fx >= fz, (v00, v01, v11) the rest.
	if fx >= fz:
		return h00 + (h10 - h00) * fx + (h11 - h10) * fz
	return h00 + (h11 - h01) * fx + (h01 - h00) * fz

func _build_terrain() -> void:
	var step := SIZE / QUADS
	var half := SIZE / 2.0
	# Precompute the height grid once; kept for surface_height_at lookups.
	_heights.resize((QUADS + 1) * (QUADS + 1))
	for iz in QUADS + 1:
		for ix in QUADS + 1:
			_heights[iz * (QUADS + 1) + ix] = height_at(ix * step - half, iz * step - half)
	var heights := _heights

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for iz in QUADS:
		for ix in QUADS:
			var x0 := ix * step - half
			var z0 := iz * step - half
			var x1 := x0 + step
			var z1 := z0 + step
			var h00 := heights[iz * (QUADS + 1) + ix]
			var h10 := heights[iz * (QUADS + 1) + ix + 1]
			var h01 := heights[(iz + 1) * (QUADS + 1) + ix]
			var h11 := heights[(iz + 1) * (QUADS + 1) + ix + 1]
			var v00 := Vector3(x0, h00, z0)
			var v10 := Vector3(x1, h10, z0)
			var v01 := Vector3(x0, h01, z1)
			var v11 := Vector3(x1, h11, z1)
			# Two flat-shaded triangles per quad (deliberate low-poly look).
			_add_tri(st, v00, v11, v10)
			_add_tri(st, v00, v01, v11)
	st.generate_normals()
	var mesh := st.commit()

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mesh.surface_set_material(0, mat)

	var mi := MeshInstance3D.new()
	mi.name = "Terrain"
	mi.mesh = mesh
	add_child(mi)

	var body := StaticBody3D.new()
	body.name = "TerrainBody"
	var shape := CollisionShape3D.new()
	var trimesh := mesh.create_trimesh_shape() as ConcavePolygonShape3D
	# The ground must be solid from BOTH sides: one-sided collision turns any
	# winding or tunneling slip into a fall through the world.
	trimesh.backface_collision = true
	shape.shape = trimesh
	body.add_child(shape)
	add_child(body)

func _add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	var centre := (a + b + c) / 3.0
	st.set_color(_ground_color(centre))
	# Godot front faces wind CLOCKWISE (not the right-hand-rule order the
	# args are given in) — emit a, c, b so the face points UP. Downward faces
	# render inside-out and are pass-through for raycasts and half-solid for
	# bodies (the v0.1.x sink/bump bugs).
	for v: Vector3 in [a, c, b]:
		st.add_vertex(v)

func _ground_color(at: Vector3) -> Color:
	# Height blend ash -> rock, scorched patches from tint noise.
	var t := clampf(inverse_lerp(-HEIGHT_AMP, HEIGHT_AMP, at.y), 0.0, 1.0)
	var c := COL_ASH.lerp(COL_ROCK, t)
	var scorch := _tint.get_noise_2d(at.x, at.z)
	if scorch > 0.35:
		c = c.lerp(COL_SCORCH, clampf((scorch - 0.35) * 2.5, 0.0, 0.8))
	return c

func _scatter_ruins() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = WORLD_SEED
	var stone := StandardMaterial3D.new()
	stone.albedo_color = COL_STONE
	stone.roughness = 0.95
	var margin := 12.0
	var placed := 0
	while placed < RUIN_SITES:
		var x := rng.randf_range(-SIZE / 2.0 + margin, SIZE / 2.0 - margin)
		var z := rng.randf_range(-SIZE / 2.0 + margin, SIZE / 2.0 - margin)
		if Vector2(x, z).length() < SHRINE_CLEAR_RADIUS + 6.0:
			continue
		_build_ruin_site(rng, Vector3(x, 0, z), stone)
		placed += 1

func _build_ruin_site(rng: RandomNumberGenerator, at: Vector3, stone: StandardMaterial3D) -> void:
	var site := Node3D.new()
	site.name = "Ruin"
	site.position = Vector3(at.x, 0, at.z)
	add_child(site)
	var kind := rng.randi_range(0, 2)
	match kind:
		0: # Broken colonnade: 2-5 columns in a rough line, some fallen.
			var count := rng.randi_range(2, 5)
			var dir := Vector2.from_angle(rng.randf_range(0.0, TAU))
			for i in count:
				var off := dir * (i * rng.randf_range(2.2, 3.0))
				_add_column(rng, site, Vector3(off.x, 0, off.y), stone)
		1: # Wall fragments: 2-4 chunks around a lost floor plan.
			var count := rng.randi_range(2, 4)
			for i in count:
				_add_wall(rng, site, Vector3(rng.randf_range(-4, 4), 0, rng.randf_range(-4, 4)), stone)
		2: # Rubble field.
			var count := rng.randi_range(5, 9)
			for i in count:
				_add_rubble(rng, site, Vector3(rng.randf_range(-3, 3), 0, rng.randf_range(-3, 3)), stone)

func _add_column(rng: RandomNumberGenerator, parent: Node3D, off: Vector3, stone: StandardMaterial3D) -> void:
	var wx := parent.position.x + off.x
	var wz := parent.position.z + off.z
	var ground := height_at(wx, wz)
	var r := rng.randf_range(0.35, 0.55)
	var h := rng.randf_range(1.6, 5.5)
	var mesh := CylinderMesh.new()
	mesh.top_radius = r * 0.9
	mesh.bottom_radius = r
	mesh.height = h
	var fallen := rng.randf() < 0.3
	var body := _solid(mesh, stone)
	if fallen:
		body.position = Vector3(off.x, ground + r, off.z)
		body.rotation = Vector3(PI / 2.0, rng.randf_range(0.0, TAU), 0)
	else:
		body.position = Vector3(off.x, ground + h / 2.0 - 0.15, off.z)
		body.rotation = Vector3(rng.randf_range(-0.08, 0.08), 0, rng.randf_range(-0.08, 0.08))
	parent.add_child(body)

func _add_wall(rng: RandomNumberGenerator, parent: Node3D, off: Vector3, stone: StandardMaterial3D) -> void:
	var wx := parent.position.x + off.x
	var wz := parent.position.z + off.z
	var ground := height_at(wx, wz)
	var mesh := BoxMesh.new()
	mesh.size = Vector3(rng.randf_range(2.0, 5.0), rng.randf_range(1.0, 3.2), 0.45)
	var body := _solid(mesh, stone)
	body.position = Vector3(off.x, ground + mesh.size.y / 2.0 - 0.3, off.z)
	body.rotation.y = rng.randf_range(0.0, TAU)
	parent.add_child(body)

func _add_rubble(rng: RandomNumberGenerator, parent: Node3D, off: Vector3, stone: StandardMaterial3D) -> void:
	var wx := parent.position.x + off.x
	var wz := parent.position.z + off.z
	var ground := height_at(wx, wz)
	var mesh := BoxMesh.new()
	var s := rng.randf_range(0.3, 0.9)
	mesh.size = Vector3(s, s * rng.randf_range(0.5, 1.0), s * rng.randf_range(0.6, 1.2))
	var body := _solid(mesh, stone)
	body.position = Vector3(off.x, ground + mesh.size.y * 0.25, off.z)
	body.rotation = Vector3(rng.randf_range(-0.3, 0.3), rng.randf_range(0.0, TAU), rng.randf_range(-0.3, 0.3))
	parent.add_child(body)

## A mesh with a matching static collision body, so ruins are climbable cover
## rather than ghosts.
func _solid(mesh: Mesh, mat: Material) -> StaticBody3D:
	var body := StaticBody3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.set_surface_override_material(0, mat)
	body.add_child(mi)
	var shape := CollisionShape3D.new()
	shape.shape = mesh.create_convex_shape()
	body.add_child(shape)
	return body

func _build_shrine() -> void:
	var shrine := Node3D.new()
	shrine.name = "WardensShrine"
	add_child(shrine)
	var rng := RandomNumberGenerator.new()
	rng.seed = WORLD_SEED + 7
	var stone := StandardMaterial3D.new()
	stone.albedo_color = COL_STONE.lightened(0.08)
	stone.roughness = 0.9

	# Ring of seven monoliths facing the flame.
	for i in 7:
		var angle := TAU * i / 7.0
		var pos := Vector3(cos(angle) * 6.0, 0, sin(angle) * 6.0)
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.9, rng.randf_range(2.6, 3.4), 0.5)
		var body := _solid(mesh, stone)
		body.position = Vector3(pos.x, height_at(pos.x, pos.z) + mesh.size.y / 2.0 - 0.2, pos.z)
		body.rotation.y = -angle + PI / 2.0
		body.rotation.x = rng.randf_range(-0.05, 0.05)
		shrine.add_child(body)

	# Pedestal and the ember flame.
	var ground := height_at(0, 0)
	var pedestal_mesh := CylinderMesh.new()
	pedestal_mesh.top_radius = 0.7
	pedestal_mesh.bottom_radius = 0.9
	pedestal_mesh.height = 1.0
	var pedestal := _solid(pedestal_mesh, stone)
	pedestal.position = Vector3(0, ground + 0.5, 0)
	shrine.add_child(pedestal)

	_brazier_mesh = MeshInstance3D.new()
	var flame := SphereMesh.new()
	flame.radius = 0.32
	flame.height = 0.64
	_brazier_mesh.mesh = flame
	var ember := StandardMaterial3D.new()
	ember.albedo_color = COL_EMBER
	ember.emission_enabled = true
	ember.emission = COL_EMBER
	ember.emission_energy_multiplier = 1.8
	_brazier_mesh.set_surface_override_material(0, ember)
	_brazier_mesh.position = Vector3(0, ground + 1.25, 0)
	shrine.add_child(_brazier_mesh)

	_brazier_light = OmniLight3D.new()
	_brazier_light.light_color = COL_EMBER
	_brazier_light.omni_range = 22.0
	_brazier_light.light_energy = 2.2
	_brazier_light.shadow_enabled = true
	_brazier_light.position = Vector3(0, ground + 1.8, 0)
	shrine.add_child(_brazier_light)
