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

## The starter cave: the chamber every wanderer wakes in, seamlessly part of
## the open world (no loading screens, ever) — a rock dome on a flattened
## clearing, mouth facing the shrine, roughly a minute's walk away.
const CAVE_SITE := Vector2(-56.0, -20.0)
const CAVE_SEED := 42 ## Same chamber as the taste-gate scene.
const CAVE_RADIUS := 8.0
const CAVE_CLEAR_RADIUS := 15.0 ## Terrain flattened so the dome sits clean.

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
var _cave_clearing_h := 0.0
var _cave_spawn := Vector3.ZERO

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
	# The cave clearing level is the UNFLATTENED height at the site centre;
	# it must be fixed before any height_at call (height_at flattens toward it).
	_cave_clearing_h = _raw_height(CAVE_SITE.x, CAVE_SITE.y)
	_build_terrain()
	_build_starter_cave()
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
	var h := _raw_height(x, z)
	# Ease toward flat within the shrine clearing so the spawn reads as a
	# kept, deliberate place amid the ruin.
	var d := Vector2(x, z).length()
	var keep := smoothstep(0.35, 1.0, clampf(d / SHRINE_CLEAR_RADIUS, 0.0, 1.0))
	h = lerpf(h * 0.12, h, keep)
	# Flatten the starter-cave clearing to one level: the cave floor sits just
	# above it, so the chamber never clips terrain and the anti-embed safety
	# net (which treats "below the heightfield" as invalid) stays honest
	# inside the cave.
	var cave_d := Vector2(x - CAVE_SITE.x, z - CAVE_SITE.y).length()
	var cave_keep := smoothstep(0.5, 1.0, clampf(cave_d / CAVE_CLEAR_RADIUS, 0.0, 1.0))
	return lerpf(_cave_clearing_h, h, cave_keep)

## The undisturbed noise height — no clearings applied.
func _raw_height(x: float, z: float) -> float:
	return _noise.get_noise_2d(x, z) * HEIGHT_AMP + _detail.get_noise_2d(x, z) * 0.6

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

## Where a new wanderer wakes: on the starter cave's floor, deep enough in
## that the mouth is a doorway of light ahead.
func cave_spawn_point() -> Vector3:
	return _cave_spawn

func _build_starter_cave() -> void:
	var cave := Node3D.new()
	cave.name = "StarterCave"
	# Mouth (+X in cave space) faces the shrine at the origin.
	var mouth_dir := (Vector2.ZERO - CAVE_SITE).normalized()
	var yaw := atan2(-mouth_dir.y, mouth_dir.x)
	add_child(cave)

	var interior := CaveGen.build_mesh(CAVE_SEED, CAVE_RADIUS)
	var shell := CaveGen.build_shell_mesh(CAVE_SEED, CAVE_RADIUS)

	# Seat the chamber so its LOWEST floor vertex sits just above the flat
	# clearing — the floor never dips into terrain, and every floor point is
	# above the heightfield (anti-embed safe). Deterministic: derived from the
	# seeded mesh itself.
	var floor_band := -0.55 * CAVE_RADIUS + 0.08 * CAVE_RADIUS + 0.001
	var min_floor := 0.0
	var mouth_edge := -10.0
	var verts: PackedVector3Array = interior.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for v in verts:
		if v.y < floor_band:
			min_floor = minf(min_floor, v.y)
			if v.x > CAVE_RADIUS * 0.82:
				mouth_edge = maxf(mouth_edge, v.y)
	var origin_y := _cave_clearing_h + 0.25 - min_floor
	cave.position = Vector3(CAVE_SITE.x, origin_y, CAVE_SITE.y)
	cave.rotation.y = yaw

	_add_cave_mesh(cave, interior)
	_add_cave_mesh(cave, shell)

	# A rock threshold ramps the mouth edge down to the clearing so walking
	# in and out is a slope, not a step.
	var mouth_world_y := origin_y + mouth_edge
	var drop := mouth_world_y - _cave_clearing_h
	var ramp_len := 3.2
	var ramp_mesh := BoxMesh.new()
	ramp_mesh.size = Vector3(ramp_len, 0.3, 5.0)
	var ramp_mat := StandardMaterial3D.new()
	ramp_mat.albedo_color = COL_ROCK
	ramp_mat.roughness = 0.97
	var ramp := StaticBody3D.new()
	var ramp_mi := MeshInstance3D.new()
	ramp_mi.mesh = ramp_mesh
	ramp_mi.set_surface_override_material(0, ramp_mat)
	ramp.add_child(ramp_mi)
	var ramp_col := CollisionShape3D.new()
	ramp_col.shape = ramp_mesh.create_convex_shape()
	ramp.add_child(ramp_col)
	ramp.position = Vector3(CAVE_RADIUS + ramp_len * 0.42, mouth_world_y - origin_y - drop * 0.5 - 0.12, 0.0)
	ramp.rotation.z = -atan2(drop, ramp_len)  # Descend going outward (+X).
	cave.add_child(ramp)

	# Dying embers by the spawn — the first light a wanderer ever sees.
	var ember_mat := StandardMaterial3D.new()
	ember_mat.albedo_color = COL_EMBER
	ember_mat.emission_enabled = true
	ember_mat.emission = COL_EMBER
	ember_mat.emission_energy_multiplier = 1.4
	var ember_mesh := SphereMesh.new()
	ember_mesh.radius = 0.22
	ember_mesh.height = 0.3
	var embers := MeshInstance3D.new()
	embers.mesh = ember_mesh
	embers.set_surface_override_material(0, ember_mat)
	var spawn_floor_local := _floor_height_near(verts, floor_band, Vector2(-2.5, 0.0))
	embers.position = Vector3(-1.2, spawn_floor_local + 0.12, 1.4)
	cave.add_child(embers)
	var glow := OmniLight3D.new()
	glow.light_color = COL_EMBER
	glow.light_energy = 1.8
	glow.omni_range = 11.0
	glow.shadow_enabled = true
	glow.position = embers.position + Vector3(0, 0.5, 0)
	cave.add_child(glow)

	_cave_spawn = cave.to_global(Vector3(-2.5, spawn_floor_local + 1.0, 0.0))

## Highest floor vertex within 0.8 m of a local (x, z) spot — where something
## can stand on the rumpled floor.
func _floor_height_near(verts: PackedVector3Array, floor_band: float, spot: Vector2) -> float:
	var best := -0.55 * CAVE_RADIUS
	for v in verts:
		if v.y < floor_band and Vector2(v.x, v.z).distance_to(spot) < 0.8:
			best = maxf(best, v.y)
	return best

func _add_cave_mesh(parent: Node3D, mesh: ArrayMesh) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	parent.add_child(mi)
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var trimesh := mesh.create_trimesh_shape() as ConcavePolygonShape3D
	# Solid from both sides — the interior winds inward, the shell outward,
	# and the wanderer must be able to stand on either.
	trimesh.backface_collision = true
	shape.shape = trimesh
	body.add_child(shape)
	parent.add_child(body)

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
		if Vector2(x, z).distance_to(CAVE_SITE) < CAVE_CLEAR_RADIUS + 6.0:
			continue  # Keep the starter cave's clearing free of ruins.
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
