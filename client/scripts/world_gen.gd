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

## The starter cave: the system every wanderer wakes in, seamlessly part of
## the open world (no loading screens, ever) — a winding multi-chamber cave
## inside a rock massif (CaveSystemGen), mouth facing the shrine roughly a
## minute's walk away. The terrain DIPS below the system's floors in its
## footprint (a heightfield cannot have holes; the massif is the
## above-ground rock), and the anti-embed net stands down inside.
## Cosmetic ground cover strewn between the landmarks (see _scatter_foliage).
## Placement comes from [FoliageGen]; these are only HOW MUCH and HOW SPARSE.
const FOLIAGE_COUNT := 2400
const FOLIAGE_MARGIN := 6.0 ## Inset from the world edge, like the ruin scatter.
const FOLIAGE_MIN_SEP := 1.1 ## Metres between props, so scenery never stacks.
## Cleared around each ruin site's centre, so a prop never sits inside a
## structure's immediate footprint. Deliberately smaller than a colonnade's full
## reach: scrub growing AMONG distant fallen columns is wanted, not a bald ring.
const FOLIAGE_RUIN_CLEARANCE := 5.0
## Offset from WORLD_SEED so foliage has its own deterministic stream and never
## disturbs the ruin/cave/terrain draws.
const FOLIAGE_SEED_OFFSET := 7
## WHERE cover gathers (#152): a second, independent low-frequency noise field
## drives per-candidate acceptance, so scrub gathers into thickets and leaves
## genuinely bare clearings instead of uniform confetti. Wavelength ≈ 1/freq
## ≈ 45 m — a handful of distinct thickets and clearings across the 220 m
## Reach, big enough to steer by.
const FOLIAGE_DENSITY_SEED_OFFSET := 13
const FOLIAGE_DENSITY_FREQUENCY := 0.022
## The smoothstep band mapping that noise (remapped to 0..1) to density:
## below BARE_BELOW the ground is genuinely bare (density 0 — the scatter
## places NOTHING there), above FULL_ABOVE a thicket saturates.
const FOLIAGE_BARE_BELOW := 0.38
const FOLIAGE_FULL_ABOVE := 0.62
## Rise-over-run at which ground reads as fully steep for cover: scrub and
## grass thin away on grades, while the KIND mix (not just the density)
## shifts toward rubble there — debris tolerates slopes.
const FOLIAGE_STEEP_GRADE := 0.5
## Exposure by ELEVATION: cover gathers in the low ground and thins on high,
## open ground — a flat hollow and a flat ridge-top must not read the same.
## Ground at or below LOW is sheltered (full density); by HIGH it is fully
## exposed and keeps only (1 - EXPOSURE_THIN) of its cover. The terrain band
## is roughly ±7.6 m (HEIGHT_AMP + detail), so 0→6 spans the upper half.
const FOLIAGE_LOW_GROUND := 0.0
const FOLIAGE_HIGH_GROUND := 6.0
const FOLIAGE_EXPOSURE_THIN := 0.55

const CAVE_SITE := Vector2(-56.0, -20.0)
const CAVE_SEED := 42
const CAVE_FLOOR_SKIRT := 0.55 ## How far terrain dips under cave floors.

## Palette — built stone and ember. The GROUND's colours are no longer one
## palette held here: they belong to whichever region a place falls in, and
## live in [GroundRegions] (the old ash/rock/scorch triple is now its
## `ashflats` region, unchanged).
const COL_STONE := Color(0.42, 0.39, 0.35)
const COL_EMBER := Color(1.0, 0.55, 0.18)

## Returned by surface_height_at outside the terrain grid: "no ground here".
const NO_GROUND := -1.0e6

var _noise := FastNoiseLite.new()
var _detail := FastNoiseLite.new()
var _tint := FastNoiseLite.new()
var _foliage_density := FastNoiseLite.new()
var _heights := PackedFloat32Array()
## The ground regions this world was dealt, built once at generation and read
## for every terrain vertex. See [GroundRegions].
var _region_sites: Array[GroundRegions.Site] = []
var _brazier_light: OmniLight3D
var _brazier_mesh: MeshInstance3D
var _shrine_interactable: Interactable
var _time := 0.0
var _cave_spawn := Vector3.ZERO
var _cave_transform := Transform3D.IDENTITY
var _cave_inverse := Transform3D.IDENTITY
## World-space footprint circles [Vector2 xz, xz_radius, dip_target_y] — one
## per cave shape; they dip the terrain under the massif and drive the
## unstick exemption and the ruin keep-out.
var _cave_cover: Array = []
## The doorway apron [Vector2 xz, radius, grade_y]: terrain outside the mouth
## pinned to walk-out grade.
var _cave_apron: Array = []

## Every cosmetic prop this world scattered, as [FoliageGen] produced them.
## Retained because a MultiMesh's instance transforms live in the RenderingServer
## and are NOT readable under `--headless` (they read back as identity, and its
## `buffer` is empty), so this placement list is the only headless-verifiable
## record of where scenery actually went — and it is the record that carries the
## laws worth pinning (determinism, keep-outs, resting on the ground).
var _foliage: Array[Dictionary] = []

func _ready() -> void:
	# Dealt before anything is baked: the terrain colour bake reads them.
	_region_sites = GroundRegions.sites(WORLD_SEED, SIZE)
	_noise.seed = WORLD_SEED
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.frequency = 0.011
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = 4
	_detail.seed = WORLD_SEED + 1
	_detail.frequency = 0.09
	_tint.seed = WORLD_SEED + 2
	_tint.frequency = 0.05
	# Single-octave simplex: smooth, blobby thickets and clearings — fractal
	# detail here would read as speckle, the exact confetti #152 removes.
	# FRACTAL_NONE is load-bearing: FastNoiseLite DEFAULTS to FBM with several
	# octaves, which would punch small holes inside the broad thickets.
	_foliage_density.seed = WORLD_SEED + FOLIAGE_DENSITY_SEED_OFFSET
	_foliage_density.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_foliage_density.frequency = FOLIAGE_DENSITY_FREQUENCY
	_foliage_density.fractal_type = FastNoiseLite.FRACTAL_NONE
	# The cave layout and cover circles must exist before ANY height_at call:
	# the terrain grid bakes the cover knoll in.
	_prepare_starter_cave()
	_build_terrain()
	_build_starter_cave()
	_scatter_ruins()
	_build_shrine()
	# LAST: foliage keeps out of every landmark, so it needs the ruin sites and
	# the shrine to already exist in the tree.
	_scatter_foliage()

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
	# The massif's ground: the heightfield cannot have holes, so the terrain
	# DIPS below every cave floor inside the system's footprint — the rock
	# massif (CaveSystemGen's hull) is the above-ground presence, and the
	# terrain meets it at a buried skirt. The dip also gives the mouth its
	# hollow: you walk slightly down into the doorway.
	for dip: Array in _cave_cover:
		var dip_d: float = (Vector2(x, z) - (dip[0] as Vector2)).length()
		var influence := 1.0 - smoothstep(0.4, 1.0, dip_d / ((dip[1] as float) + 4.0))
		if influence > 0.0:
			h = lerpf(h, minf(h, dip[2] as float), influence)
	# The doorway apron: ground OUTSIDE the mouth is pinned to mouth-floor
	# grade (raised or lowered), so stepping out of the cave is a step, not a
	# cliff, whatever the natural slope wanted to do here.
	if not _cave_apron.is_empty():
		var apron_d: float = (Vector2(x, z) - (_cave_apron[0] as Vector2)).length()
		var apron_influence := 1.0 - smoothstep(0.35, 1.0, apron_d / (_cave_apron[1] as float))
		if apron_influence > 0.0:
			h = lerpf(h, _cave_apron[2] as float, apron_influence)
	return h

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

	# The baked vertex tint is only one value per quad — far too coarse to read
	# as a surface underfoot. The shader keeps that tint as its base layer and
	# adds the grain, drift and slope-aware ash/rock the vertex density cannot
	# carry (procedural, no textures — same approach as the cave rock).
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/terrain.gdshader")
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
	# WHICH ground this is comes first; the layering within it is unchanged —
	# height blends ash -> rock, tint noise scorches the sheltered lows.
	var pal := GroundRegions.palette_for(_region_sites, at.x, at.z)
	var ash: Color = pal[&"ash"]
	var rock: Color = pal[&"rock"]
	var t := clampf(inverse_lerp(-HEIGHT_AMP, HEIGHT_AMP, at.y), 0.0, 1.0)
	var c := ash.lerp(rock, t)
	var scorch := _tint.get_noise_2d(at.x, at.z)
	if scorch > 0.35:
		var col_scorch: Color = pal[&"scorch"]
		c = c.lerp(col_scorch, clampf((scorch - 0.35) * 2.5, 0.0, 0.8))
	return c


## The name of the region a place stands on. The frame-capture tool writes it
## beside every surface frame, so the evidence says WHICH ground it photographed
## rather than leaving a reviewer to derive it.
func region_name_at(x: float, z: float) -> StringName:
	var at := GroundRegions.region_for(_region_sites, x, z)
	var region: Dictionary = GroundRegions.REGIONS[at[&"region"]]
	return region[&"name"]

## Where a new wanderer wakes: on the main chamber's floor, deep in the
## system, torches leading up toward the mouth.
func cave_spawn_point() -> Vector3:
	return _cave_spawn

## The starter system's local→world transform (tests trace the spine with it).
func cave_to_world() -> Transform3D:
	return _cave_transform

func _prepare_starter_cave() -> void:
	# Mouth (+X in cave space) faces the shrine at the origin.
	var mouth_dir := (Vector2.ZERO - CAVE_SITE).normalized()
	var yaw := atan2(-mouth_dir.y, mouth_dir.x)
	var lay := CaveSystemGen.layout(CAVE_SEED)
	# Seat the system so the mouth FLOOR (local y = 0) meets the natural
	# ground at the mouth's world position: you step out onto the Reach.
	var basis := Basis(Vector3.UP, yaw)
	var mouth_local: Vector3 = lay["mouth"]
	var mouth_flat := basis * Vector3(mouth_local.x, 0.0, mouth_local.z)
	var origin_y := _raw_height(CAVE_SITE.x + mouth_flat.x, CAVE_SITE.y + mouth_flat.z)
	_cave_transform = Transform3D(basis, Vector3(CAVE_SITE.x, origin_y, CAVE_SITE.y))
	_cave_inverse = _cave_transform.affine_inverse()

	# Footprint circles: [xz, hull footprint radius, terrain dip target] —
	# one per room and tunnel sample; terrain dips below that shape's floor.
	_cave_cover.clear()
	for room: Dictionary in lay["rooms"]:
		var w: Vector3 = _cave_transform * (room["center"] as Vector3)
		var dip_y: float = origin_y + (room["floor"] as float) - CAVE_FLOOR_SKIRT
		_cave_cover.append([Vector2(w.x, w.z), (room["r"] as float) + CaveSystemGen.HULL_ROCK, dip_y])
	for t: Dictionary in lay["tunnels"]:
		for u: float in [0.0, 0.5, 1.0]:
			var point: Vector3 = (t["a"] as Vector3).lerp(t["b"] as Vector3, u)
			var w: Vector3 = _cave_transform * point
			var dip_y: float = origin_y + lerpf(t["floor_a"] as float, t["floor_b"] as float, u) - CAVE_FLOOR_SKIRT
			_cave_cover.append([Vector2(w.x, w.z), (t["r"] as float) + CaveSystemGen.HULL_ROCK, dip_y])

	var apron_local: Vector3 = (lay["mouth"] as Vector3) + Vector3(6.5, 0.0, 0.0)
	var apron_world: Vector3 = _cave_transform * apron_local
	_cave_apron = [Vector2(apron_world.x, apron_world.z), 9.0, origin_y - 0.45]

	# Provisional spawn; _build_starter_cave refines it with the field-probed
	# actual floor once the system is meshed.
	var spawn_local: Vector3 = lay["spawn"]
	spawn_local.y = (lay["spawn_floor"] as float) + 1.2
	_cave_spawn = _cave_transform * spawn_local

func _build_starter_cave() -> void:
	var cave := CaveSystemGen.new()
	cave.name = "StarterCave"
	cave.seed_value = CAVE_SEED
	cave.transform = _cave_transform
	add_child(cave)
	# The generator carves against LOCAL terrain heights so the mouth zone
	# blends the cave into the real hillside.
	var to_world := _cave_transform
	cave.rebuild(func(lx: float, lz: float) -> float:
		var w := to_world * Vector3(lx, 0.0, lz)
		return height_at(w.x, w.z) - to_world.origin.y)
	# The wanderer wakes STANDING: the field-probed floor, not the nominal one.
	var lay: Dictionary = cave.last_layout
	var spawn_local: Vector3 = lay["spawn"]
	spawn_local.y = (lay.get("spawn_floor_actual", lay["spawn_floor"]) as float) + 1.15
	_cave_spawn = _cave_transform * spawn_local

## True inside the starter system's footprint: the anti-embed net stands
## down here (being under the heightfield is the POINT of a cave).
func cave_protects(x: float, z: float) -> bool:
	for cover: Array in _cave_cover:
		if (Vector2(x, z) - (cover[0] as Vector2)).length() < (cover[1] as float) + 3.0:
			return true
	return false

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
		if cave_protects(x, z):
			continue  # Keep the starter cave's ground free of ruins.
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
	# Derived from the piece's own position, NOT drawn from the placement
	# stream — even a single draw would advance it, so changing how a break is
	# shaped would still shift every ruin placed afterwards.
	var detail := RandomNumberGenerator.new()
	detail.seed = _detail_seed(wx, wz, 1)
	var mesh := _broken_column_mesh(detail, r, r * 0.9, h)
	var fallen := rng.randf() < 0.3
	var body := _solid(mesh, stone)
	if fallen:
		# The node origin must stay the piece CENTRE: the keep-out guard measures
		# global_position +/- a radius, so a base-anchored origin would let a
		# fallen column reach into the shrine clearing unnoticed. Shift the mesh
		# and its collider INSIDE the body instead of moving the body.
		_offset_children(body, Vector3(0.0, -h * 0.5, 0.0))
		body.position = Vector3(off.x, ground + r, off.z)
		body.rotation = Vector3(PI / 2.0, rng.randf_range(0.0, TAU), 0)
	else:
		# The mesh is built from its base at y=0, so it is seated on the ground
		# rather than centred on it like the old CylinderMesh.
		body.position = Vector3(off.x, ground - 0.15, off.z)
		body.rotation = Vector3(rng.randf_range(-0.08, 0.08), 0, rng.randf_range(-0.08, 0.08))
	parent.add_child(body)

func _add_wall(rng: RandomNumberGenerator, parent: Node3D, off: Vector3, stone: StandardMaterial3D) -> void:
	var wx := parent.position.x + off.x
	var wz := parent.position.z + off.z
	var ground := height_at(wx, wz)
	var wall_size := Vector3(rng.randf_range(2.0, 5.0), rng.randf_range(1.0, 3.2), 0.45)
	var wall_detail := RandomNumberGenerator.new()
	wall_detail.seed = _detail_seed(wx, wz, 2)
	var mesh := _broken_wall_mesh(wall_detail, wall_size.x, wall_size.y, wall_size.z)
	# CONCAVE on purpose: a wall with collapsed steps and missing courses has
	# gaps, and one convex hull would fill them with invisible collision — the
	# player would be stopped by a hole they can see straight through.
	var body := _solid(mesh, stone, true)
	# Built from its base at y=0, so seat it on the ground.
	body.position = Vector3(off.x, ground - 0.3, off.z)
	body.rotation.y = rng.randf_range(0.0, TAU)
	parent.add_child(body)

func _add_rubble(rng: RandomNumberGenerator, parent: Node3D, off: Vector3, stone: StandardMaterial3D) -> void:
	var wx := parent.position.x + off.x
	var wz := parent.position.z + off.z
	var ground := height_at(wx, wz)
	var s := rng.randf_range(0.3, 0.9)
	var chunk := Vector3(s, s * rng.randf_range(0.5, 1.0), s * rng.randf_range(0.6, 1.2))
	var rubble_detail := RandomNumberGenerator.new()
	rubble_detail.seed = _detail_seed(wx, wz, 3)
	var mesh := _rubble_chunk_mesh(rubble_detail, chunk)
	var body := _solid(mesh, stone)
	body.position = Vector3(off.x, ground + chunk.y * 0.25, off.z)
	body.rotation = Vector3(rng.randf_range(-0.3, 0.3), rng.randf_range(0.0, TAU), rng.randf_range(-0.3, 0.3))
	parent.add_child(body)

## A deterministic per-piece seed from world position, so mesh detail never
## consumes the placement stream (changing a break must not move the ruins).
func _detail_seed(wx: float, wz: float, salt: int) -> int:
	return WORLD_SEED * 1000003 + roundi(wx * 100.0) * 9176 + roundi(wz * 100.0) * 31 + salt


## Shifts a body's mesh/collision children, so the body origin can stay the
## conceptual centre while the geometry sits elsewhere.
func _offset_children(body: StaticBody3D, delta: Vector3) -> void:
	for child in body.get_children():
		if child is Node3D:
			(child as Node3D).position += delta


## A column with a SHEARED, JAGGED top rather than a flat cap. A clean cylinder
## reads as a pillar prop; stone that snapped reads as a ruin — and at the
## distance these are usually seen, the outline is all the eye gets, so the
## break matters more than any surface treatment could.
##
## Built as a radial ring whose per-segment top height falls away along one
## shear direction (the way a column gives out on one side) with per-segment
## jag on top of it, so no two breaks repeat.
func _broken_column_mesh(rng: RandomNumberGenerator, r_bottom: float, r_top: float, h: float) -> ArrayMesh:
	var segs := 12
	var shear_dir := rng.randf_range(0.0, TAU)
	var shear := rng.randf_range(0.10, 0.40) * h
	var jag := rng.randf_range(0.03, 0.14) * h
	var tops := PackedFloat32Array()
	for i in segs:
		var a := TAU * i / float(segs)
		# 0 on the standing side, 1 on the side that gave way.
		var lean := 0.5 - 0.5 * cos(a - shear_dir)
		tops.append(maxf(h * 0.25, h - shear * lean - rng.randf_range(0.0, jag)))

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ring_bottom: Array[Vector3] = []
	var ring_top: Array[Vector3] = []
	for i in segs:
		var a := TAU * i / float(segs)
		ring_bottom.append(Vector3(cos(a) * r_bottom, 0.0, sin(a) * r_bottom))
		ring_top.append(Vector3(cos(a) * r_top, tops[i], sin(a) * r_top))

	for i in segs:
		var j := (i + 1) % segs
		# Sides, wound CLOCKWISE so they face outward (see _add_tri).
		st.add_vertex(ring_bottom[i]); st.add_vertex(ring_top[j]); st.add_vertex(ring_top[i])
		st.add_vertex(ring_bottom[i]); st.add_vertex(ring_bottom[j]); st.add_vertex(ring_top[j])
		# Base cap, wound the other way so it faces down.
		st.add_vertex(Vector3.ZERO); st.add_vertex(ring_bottom[i]); st.add_vertex(ring_bottom[j])

	# The broken face itself: a fan to the mean break height, so the top is a
	# ragged surface rather than a lid.
	var mean_top := 0.0
	for t in tops:
		mean_top += t
	mean_top /= float(segs)
	var apex := Vector3(0.0, mean_top, 0.0)
	for i in segs:
		var j := (i + 1) % segs
		st.add_vertex(apex); st.add_vertex(ring_top[j]); st.add_vertex(ring_top[i])

	st.generate_normals()
	return st.commit()


## A wall fragment whose top edge has COLLAPSED — stepped and eroded, with the
## occasional missing tooth — instead of the clean rectangle a BoxMesh gives.
func _broken_wall_mesh(rng: RandomNumberGenerator, w: float, h: float, d: float) -> ArrayMesh:
	var cols := maxi(3, int(w / 0.55))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# The wall falls away toward one end, so it reads as a structure that
	# collapsed rather than a fence that was trimmed.
	var fall_from_left := rng.randf() < 0.5
	var step := w / float(cols)
	for c in cols:
		var t := float(c) / float(cols - 1)
		var along := t if fall_from_left else 1.0 - t
		var col_h := h * (1.0 - 0.55 * along) - rng.randf_range(0.0, h * 0.18)
		col_h = maxf(col_h, h * 0.18)
		# An occasional gap where the courses have fallen out entirely.
		if c > 0 and c < cols - 1 and rng.randf() < 0.12:
			continue
		var x0 := -w / 2.0 + c * step
		var x1 := x0 + step
		_add_box(st, Vector3(x0, 0.0, -d / 2.0), Vector3(x1, col_h, d / 2.0))
	st.generate_normals()
	return st.commit()


## An irregular rubble chunk: a box whose corners are pulled about, so broken
## masonry does not read as a crate.
func _rubble_chunk_mesh(rng: RandomNumberGenerator, size: Vector3) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var jitter := func() -> Vector3:
		return Vector3(
			rng.randf_range(-0.22, 0.22) * size.x,
			rng.randf_range(-0.22, 0.22) * size.y,
			rng.randf_range(-0.22, 0.22) * size.z)
	var lo := -size / 2.0
	var hi := size / 2.0
	var corners: Array[Vector3] = [
		Vector3(lo.x, lo.y, lo.z) + jitter.call(), Vector3(hi.x, lo.y, lo.z) + jitter.call(),
		Vector3(hi.x, lo.y, hi.z) + jitter.call(), Vector3(lo.x, lo.y, hi.z) + jitter.call(),
		Vector3(lo.x, hi.y, lo.z) + jitter.call(), Vector3(hi.x, hi.y, lo.z) + jitter.call(),
		Vector3(hi.x, hi.y, hi.z) + jitter.call(), Vector3(lo.x, hi.y, hi.z) + jitter.call(),
	]
	var faces := [
		[0, 1, 2, 3], [7, 6, 5, 4], [4, 5, 1, 0],
		[6, 7, 3, 2], [5, 6, 2, 1], [7, 4, 0, 3],
	]
	# Godot front faces wind CLOCKWISE (see _add_tri): emit each triangle
	# reversed, or the chunk is inside-out — pass-through for raycasts and
	# half-solid for bodies, the v0.1.x sink/bump bug class.
	for f: Array in faces:
		st.add_vertex(corners[f[0]]); st.add_vertex(corners[f[2]]); st.add_vertex(corners[f[1]])
		st.add_vertex(corners[f[0]]); st.add_vertex(corners[f[3]]); st.add_vertex(corners[f[2]])
	st.generate_normals()
	return st.commit()


## Appends an axis-aligned box spanning `lo`..`hi` to `st`.
func _add_box(st: SurfaceTool, lo: Vector3, hi: Vector3) -> void:
	var c: Array[Vector3] = [
		Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z),
		Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z),
		Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z),
		Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z),
	]
	var faces := [
		[0, 1, 2, 3], [7, 6, 5, 4], [4, 5, 1, 0],
		[6, 7, 3, 2], [5, 6, 2, 1], [7, 4, 0, 3],
	]
	# Clockwise, per _add_tri's convention.
	for f: Array in faces:
		st.add_vertex(c[f[0]]); st.add_vertex(c[f[2]]); st.add_vertex(c[f[1]])
		st.add_vertex(c[f[0]]); st.add_vertex(c[f[3]]); st.add_vertex(c[f[2]])


## A mesh with a matching static collision body, so ruins are climbable cover
## rather than ghosts.
func _solid(mesh: Mesh, mat: Material, concave: bool = false) -> StaticBody3D:
	var body := StaticBody3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.set_surface_override_material(0, mat)
	body.add_child(mi)
	var shape := CollisionShape3D.new()
	# A convex hull is right for solid masonry; anything with real gaps needs a
	# trimesh or the holes become invisible walls.
	shape.shape = mesh.create_trimesh_shape() if concave else mesh.create_convex_shape()
	body.add_child(shape)
	return body

## Strew cosmetic ground cover between the landmarks, so the Ashfall Reach reads
## as a ruined, strewn place rather than bare terrain between monuments.
## Placement is delegated WHOLE to [FoliageGen]: deterministic from a fixed seed,
## keep-out aware, and horizontal-only by construction (a prop carries a look and
## nothing else), so the same world grows the same scrub every boot exactly as it
## raises the same ruins.
##
## Rendered as ONE MultiMesh per kind, with NO collision: hundreds of props cost
## a handful of draw calls, and a wanderer walks through scrub instead of being
## snagged on it. It also keeps foliage clear of the ruin structural scan — a
## MultiMeshInstance3D is not a scriptless Node3D.
func _scatter_foliage() -> void:
	var placements := FoliageGen.scatter({
		"seed": WORLD_SEED + FOLIAGE_SEED_OFFSET,
		"count": FOLIAGE_COUNT,
		"half_extent": SIZE / 2.0,
		"margin": FOLIAGE_MARGIN,
		"min_sep": FOLIAGE_MIN_SEP,
		"keep_outs": _foliage_keep_outs(),
		"height_sampler": surface_height_at,
		"density_field": _foliage_density_at,
		"kind_weights_field": _foliage_kind_weights_at,
	})
	var by_kind: Array = []
	for _slot in FoliageGen.KIND_COUNT:
		by_kind.append([])
	for placement: Dictionary in placements:
		var kind: int = placement["kind"]
		if FoliageGen.is_valid_kind(kind):
			(by_kind[kind] as Array).append(placement)
	for kind in FoliageGen.KIND_COUNT:
		var batch := by_kind[kind] as Array
		_build_foliage_batch(kind, batch)
		# Record what was actually rendered, in the same batch/instance order the
		# MultiMeshes were filled, so the placement list mirrors the world.
		for placement: Dictionary in batch:
			_foliage.append(placement)


## Every cosmetic prop in this world, in render order — a copy, so a caller can
## never disturb the generated world. Each entry is a [FoliageGen] placement
## (`kind`, `pos`, `yaw`, `scale`), with `pos.y` the height the prop was lifted
## to so it rests on the surface.
func foliage_placements() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for placement: Dictionary in _foliage:
		out.append(placement.duplicate(true))
	return out


## Local ground-cover density in [0, 1] (#152): the low-frequency field carves
## thickets where it is high and genuinely bare clearings where its smoothstep
## band bottoms out; ELEVATION thins the high, open ground so growth gathers
## in the sheltered hollows; and steep ground thins further. Deterministic
## (an own seeded FastNoiseLite over world coordinates, plus the baked height
## grid) and pure of the scene tree, so "the same world every boot" holds for
## the composition too.
func _foliage_density_at(x: float, z: float) -> float:
	var h := surface_height_at(x, z)
	if h <= NO_GROUND:
		return 0.0
	var n01 := _foliage_density.get_noise_2d(x, z) * 0.5 + 0.5
	var d := smoothstep(FOLIAGE_BARE_BELOW, FOLIAGE_FULL_ABOVE, n01)
	var exposure := smoothstep(FOLIAGE_LOW_GROUND, FOLIAGE_HIGH_GROUND, h)
	d *= 1.0 - FOLIAGE_EXPOSURE_THIN * exposure
	return d * (1.0 - 0.65 * _foliage_slope01(x, z))


## Terrain grade at (x, z) mapped to [0, 1]: 0 on the flat, 1 at or past
## FOLIAGE_STEEP_GRADE rise-over-run. Finite-differenced from the same baked
## surface the props stand on. A NO_GROUND neighbour (off the grid) reads as
## fully steep, so cover thins to nothing at the world's edges instead of
## crowding them.
func _foliage_slope01(x: float, z: float) -> float:
	var step := 1.0
	var hx0 := surface_height_at(x - step, z)
	var hx1 := surface_height_at(x + step, z)
	var hz0 := surface_height_at(x, z - step)
	var hz1 := surface_height_at(x, z + step)
	if hx0 <= NO_GROUND or hx1 <= NO_GROUND or hz0 <= NO_GROUND or hz1 <= NO_GROUND:
		return 1.0
	var gx := (hx1 - hx0) / (2.0 * step)
	var gz := (hz1 - hz0) / (2.0 * step)
	return clampf(sqrt(gx * gx + gz * gz) / FOLIAGE_STEEP_GRADE, 0.0, 1.0)


## Per-location kind weights (#152): scrub and grass favour flat sheltered
## ground; bone and rubble tolerate slopes, and debris gathers where its own
## pattern is high — where something HAPPENED — rather than evenly across the
## plain. The debris pattern reuses the density noise on a far-offset domain:
## an independent field with zero extra state. Always length-KIND_COUNT with a
## positive total, so the weighted draw never degenerates.
func _foliage_kind_weights_at(x: float, z: float) -> Array:
	var s := _foliage_slope01(x, z)
	var debris01 := _foliage_density.get_noise_2d(x + 512.0, z - 512.0) * 0.5 + 0.5
	return [
		(1.0 - 0.75 * s) * (0.6 + 0.8 * (1.0 - debris01)), # ASH_SHRUB — flats, clear of debris fields
		1.0 - 0.55 * s,                                    # DEAD_GRASS — broad, thinning on grades
		0.2 + 0.9 * debris01,                              # BONE_PILE — where something happened
		0.25 + 0.75 * s + 0.5 * debris01,                  # RUBBLE — slopes and debris fields
	]


## Every circle foliage must stay out of: the shrine clearing, each ruin site's
## immediate footprint, and the starter cave's cover discs padded EXACTLY as
## [method cave_protects] pads them — so scenery never buries a landmark, and
## never grows over the cave mouth.
func _foliage_keep_outs() -> Array:
	var circles: Array = [[Vector2.ZERO, SHRINE_CLEAR_RADIUS + 2.0]]
	for child in get_children():
		# Ruin sites are the scriptless native Node3Ds (Godot uniquifies their
		# duplicate names by CLASS), so match structurally — the same rule the
		# world regression test uses to find them.
		if child.get_class() != "Node3D" or child.get_script() != null:
			continue
		if str(child.name) == "WardensShrine":
			continue
		var site := child as Node3D
		circles.append([Vector2(site.position.x, site.position.z), FOLIAGE_RUIN_CLEARANCE])
	for cover: Array in _cave_cover:
		circles.append([cover[0] as Vector2, (cover[1] as float) + 3.0])
	return circles


## One MultiMesh holding every prop of `kind`, instanced at its placement.
func _build_foliage_batch(kind: int, items: Array) -> void:
	if items.is_empty():
		return
	var mesh := _foliage_mesh(kind)
	# Props are modelled centred on their own origin, so lift each one to rest ON
	# the sampled ground — slightly sunk, so nothing appears to hover.
	var lift := mesh.get_aabb().size.y * 0.4
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = items.size()
	for i in items.size():
		var placement: Dictionary = items[i]
		var pos: Vector3 = placement["pos"]
		var prop_scale := float(placement["scale"])
		var basis := Basis(Vector3.UP, float(placement["yaw"])).scaled(Vector3.ONE * prop_scale)
		var rendered := Vector3(pos.x, pos.y + lift * prop_scale, pos.z)
		mm.set_instance_transform(i, Transform3D(basis, rendered))
		# Keep the record in step with what was actually rendered — the MultiMesh
		# itself cannot be read back headlessly (see _foliage).
		placement["pos"] = rendered
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Foliage_%d" % kind
	mmi.multimesh = mm
	mmi.material_override = _foliage_material(kind)
	add_child(mmi)


## The look of each cosmetic kind, delegated WHOLE to [FoliageArt] — the same
## split this file already makes for placement, where [FoliageGen] owns where a
## prop goes and this file only assembles the result.
##
## These used to be engine primitives in flat single colours (a sphere shrub, a
## box rubble pile), which the quality bar names as placeholder art (#146,
## #123). They are now generated cutout cards and jittered debris clusters.
## Prop meshes stay centred on their own origin, so the AABB-based ground lift
## in [method _build_foliage_batch] is unchanged.
func _foliage_mesh(kind: int) -> Mesh:
	return FoliageArt.mesh_for(kind)


## The generated material for a cosmetic kind: a cutout albedo texture, a
## per-instance tint band and (for vegetation) wind. See [FoliageArt].
func _foliage_material(kind: int) -> Material:
	return FoliageArt.material_for(kind)


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

	# The shrine is the wanderer's first respawn point: attune it and the Reach
	# returns you here when you fall. A wide, lenient reach — it is a landmark
	# you stand at, not a fiddly prop you must line up on. main.gd wires the
	# effect so the world stays free of Player knowledge.
	_shrine_interactable = Interactable.new()
	_shrine_interactable.name = "ShrineInteract"
	_shrine_interactable.prompt = "Attune to the Wardens' Shrine"
	_shrine_interactable.interact_range = 6.0
	_shrine_interactable.facing_min = -0.35
	_shrine_interactable.position = Vector3(0, ground + 1.0, 0)
	shrine.add_child(_shrine_interactable)


## The shrine's interaction handle — main.gd connects `interacted` to attunement.
func shrine_interactable() -> Interactable:
	return _shrine_interactable


## A standable spot at the foot of the shrine to wake at once attuned; respawn
## faces the flame (Player.face_toward(ZERO)), so you come to looking at it.
func shrine_respawn_point() -> Vector3:
	return Vector3(0, height_at(0, 5.0) + 0.1, 5.0)
