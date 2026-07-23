@tool
class_name CaveSystemGen
extends Node3D
## Cave systems in the WoW register (maintainer taste redirect 2026-07-17):
## winding multi-chamber underground caves that blend into the overworld —
## smooth flowing rock, not noise-crinkled foil.
##
## How: a seeded layout graph (rooms + tunnel segments, each with its own
## floor height so the system genuinely DESCENDS underground) becomes a
## smooth-min SDF; naive surface nets mesh the zero surface with shared
## vertices and SDF-gradient normals (that smoothness is most of the look);
## a mouth zone blends cave void into open air so the entrance melds with
## the hillside. Warm strata come from baked vertex bands plus the
## cave_rock.gdshader striations. Torches light the way down; boulders
## frame the mouth (the WoW cave-entrance grammar).
##
## Local space: +X runs OUT of the mouth; the mouth floor sits at local
## y = 0 (WorldGen seats that at terrain grade). Everything is
## deterministic from seed_value.
##
## PREVIEW HARNESS — `scenes/cave.tscn` (issue #124). The running game never
## loads that scene: `world_gen.gd` instantiates this generator directly into the
## overworld, so the cave is part of the world rather than a museum piece. The
## scene is kept deliberately, as the editor-only rig for looking at cave
## generation in isolation — a dark cave environment, a mouth light, a framed
## camera, and this node at `seed_value = 42`. Open it in the editor and, because
## this is a `@tool` script, edits to the constants below re-generate live, which
## is how the exterior/interior work (#149, #156) is judged by eye.
##
## It is intentionally unreferenced, exactly like `scenes/recipes.tscn` — the
## character taste gate documented in `recipe_gallery.gd`. Treat neither as dead
## code: an unreferenced scene here means "editor surface", and this comment is
## the marker that says so. Retire `cave.tscn` only when cave generation stops
## being tuned visually, and say so in the same change.

const CELL := 0.65 ## Surface-net grid resolution in metres.
const SMIN_K := 2.4 ## Chamber/tunnel blend radius.
## Vertical distance over which the exposed massif foot inherits the ground it
## meets. Wide enough to span several surface-net cells so interpolation makes
## a material transition, narrow enough that the far hull keeps its weathered
## rock outright.
const TERRAIN_CONTACT_BAND := 1.8
## COLOR.b carries the sampled world-space terrain height to the contact
## shader. The generated Reach lives well inside this signed range; keeping the
## encoded value in 0..1 makes the channel portable across ArrayMesh formats.
const TERRAIN_HEIGHT_RANGE := 32.0
const WALL_NOISE := 0.55 ## Low-frequency wall undulation amplitude.
const HULL_ROCK := 3.0 ## Massif wall thickness around the carved voids.

const COL_ROCK_LIGHT := Color(0.56, 0.42, 0.27)
const COL_ROCK_DARK := Color(0.33, 0.24, 0.16)
const COL_SEDIMENT := Color(0.52, 0.44, 0.33)
const COL_EMBER := Color(1.0, 0.55, 0.18)
const COL_FLAME_CORE := Color(1.0, 0.87, 0.48) ## Hotter inner cone.
const COL_IRON := Color(0.16, 0.15, 0.15) ## Bracket, collar.
const COL_WOOD := Color(0.2, 0.13, 0.08) ## Shaft.
const COL_PITCH := Color(0.09, 0.07, 0.06) ## Soaked head wrapping.

const TORCH_SPACING := 5.0 ## Target metres between torches along the spine.
const TORCH_MOUNT_H := 1.7 ## Bracket height above the local floor.
const TORCH_LEAN := 0.55 ## Shaft lean out of the wall, radians (~31°).
const TORCH_SHAFT := 0.72 ## Shaft length in metres.
const TORCH_MIN_WALL := 1.0 ## Nearer than this the torch would block the spine.

@export var seed_value: int = 42:
	set(v):
		seed_value = v
		if is_inside_tree():
			rebuild()

var _built: Array[Node] = []
var _torch_lights: Array[OmniLight3D] = []
var _torch_flames: Array[MeshInstance3D] = []
var _torch_phases := PackedFloat32Array()
var _time := 0.0
## The layout of the last rebuild, including "spawn_floor_actual" (the
## field-probed floor under the spawn) — WorldGen reads it to place the
## wanderer standing on real rock.
var last_layout := {}


func _ready() -> void:
	rebuild()


## The flicker phase every capture pins itself to (#321). The value is
## arbitrary — what matters is that it is a CONSTANT, so two runs photograph the
## same light. Zero is deliberately avoided: `flick` is at its positive peak
## there, which would evidence the cave at its brightest rather than at a
## representative moment.
const FLICKER_CAPTURE_TIME := 1.0


func _process(delta: float) -> void:
	_time += delta
	_apply_flicker()


## Drives torch light and flame body from `_time`. Split out of `_process` so a
## capture can pin the phase without re-implementing the curve — a second copy
## of this arithmetic would drift from the one the game actually runs, and the
## whole point is that the evidence path photographs the shipping light.
func _apply_flicker() -> void:
	for i in _torch_lights.size():
		var phase := _torch_phases[i]
		var flick := sin(_time * 5.1 + phase) + 0.44 * sin(_time * 13.7 + phase * 2.0)
		var l := _torch_lights[i]
		if is_instance_valid(l):
			l.light_energy = 2.1 + 0.5 * flick
		# The flame body breathes with its own light, so the flicker reads as
		# fire rather than as a lamp being dimmed.
		if i < _torch_flames.size() and is_instance_valid(_torch_flames[i]):
			var f := _torch_flames[i]
			f.scale = Vector3(1.0 + 0.06 * flick, 1.0 + 0.13 * flick, 1.0 + 0.06 * flick)


## Pin the torches to a fixed flicker phase and stop advancing them, so a
## captured frame is reproducible.
##
## The torches are the cave's ONLY light (`frame_capture.gd` asserts it before
## shooting), and their energy swings 1.38 → 2.82 — slightly over 2×. The
## capture settles a fixed number of FRAMES while `_time` accumulates DELTA, so
## without this the phase at the shutter depends on how fast those frames
## happened to render, and two runs of identical code photograph different
## illuminants. Measured on unchanged `main`: cave-walkout moved 16.8% → 20.8%
## of value range between consecutive runs (cave-chamber 12.5% → 14.1%), while
## every outdoor vantage was reproducible to the printed precision. That ±4pp
## floor is wider than the effects art PRs are asked to prove through this path.
##
## Hue is untouched by the flicker — dimming a single-hue light changes
## brightness, not hue — which is why only the value axis drifted.
##
## In-game behaviour is deliberately NOT changed: nothing calls this except the
## capture tool, so the torches flicker for players exactly as before.
func freeze_flicker(at_time: float = FLICKER_CAPTURE_TIME) -> void:
	_time = at_time
	set_process(false)
	_apply_flicker()


## The starter-system layout: entrance room, a bending descending tunnel, a
## main chamber (the waking place) and a dead-end stub that promises deeper
## dark. Rooms are [center, radius, floor_y]; the path is the walkable spine.
static func layout(p_seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = p_seed
	var wobble := func(r: float) -> float: return rng.randf_range(-r, r)
	var mouth := Vector3(14.0, 0.6, 0.0)
	var rooms := [
		{ "center": Vector3(8.0 + wobble.call(0.8), -0.4, wobble.call(1.2)), "r": 4.0, "floor": -1.2 },
		{ "center": Vector3(0.5 + wobble.call(0.8), -2.2, -5.5 + wobble.call(1.0)), "r": 3.3, "floor": -3.4 },
		{ "center": Vector3(-8.5 + wobble.call(1.0), -4.6, -1.0 + wobble.call(1.2)), "r": 5.6, "floor": -6.0 },
		{ "center": Vector3(-12.5, -5.4, -8.0 + wobble.call(1.0)), "r": 2.9, "floor": -6.6 },
	]
	# The walkable spine: mouth → entrance → bend → main chamber (→ stub).
	var path: Array[Vector3] = [
		mouth,
		rooms[0]["center"], rooms[1]["center"], rooms[2]["center"], rooms[3]["center"],
	]
	var floors: PackedFloat32Array = [0.0, rooms[0]["floor"], rooms[1]["floor"], rooms[2]["floor"], rooms[3]["floor"]]
	var tunnels := []
	for i in path.size() - 1:
		tunnels.append({
			"a": path[i], "b": path[i + 1],
			"r": 2.5 if i == 0 else 2.15,
			"floor_a": floors[i], "floor_b": floors[i + 1],
		})
	# The mouth bore: carves void but adds NO hull, so it pierces the massif
	# face — that breach IS the doorway.
	tunnels.append({
		"a": mouth, "b": mouth + Vector3(6.0, -0.3, 0.0),
		"r": 2.6, "floor_a": 0.0, "floor_b": -0.45, "bore": true,
	})
	return {
		"mouth": mouth,
		"rooms": rooms,
		"tunnels": tunnels,
		"path": path,
		"floors": floors,
		# The wanderer wakes at the back of the main chamber, facing out.
		"spawn": rooms[2]["center"] + Vector3(-1.5, 0, 0.8),
		"spawn_floor": rooms[2]["floor"],
	}


## Signed density at a local point: negative = void (cave interior, or the
## open air outside the rock massif), positive = rock. The system is a
## self-contained MASSIF — a smooth rocky hull grown around the rooms and
## tunnels — with the caves carved inside it and a bore breaking the hull
## face as the mouth. The overworld terrain never enters the SDF: WorldGen
## depresses the heightfield below the massif instead, so the two meshes
## meet at a buried skirt (a heightfield cannot have holes; the massif IS
## the above-ground rock).
static func density(p: Vector3, lay: Dictionary, noise: FastNoiseLite) -> float:
	var parts := _field_parts(p, lay)
	# Rock = inside the hull and not inside a cave; undulate the walls at low
	# frequency only — high-frequency displacement is exactly the
	# crumpled-foil look this rewrite retires.
	var d := minf(-(parts[0] as float), parts[1] as float)
	return d + noise.get_noise_3dv(p * 2.2) * WALL_NOISE


## The two signed fields the massif is composed from, before wall noise:
## `[hull, caves]`. `hull` < 0 inside the grown rock shell; `caves` < 0 inside
## a carved room/tunnel void. Split from `density` so the mesher's shading can
## ask WHICH void a surface point faces (open sky vs cave interior) with the
## same arithmetic that shaped the rock. Returned as an untyped Array on
## purpose: a Vector2 would truncate both fields to 32-bit floats and move
## every vertex the goldens pin.
static func _field_parts(p: Vector3, lay: Dictionary) -> Array:
	var caves := 1.0e6
	var hull := 1.0e6
	for room: Dictionary in lay["rooms"]:
		var to_c: float = p.distance_to(room["center"])
		var s: float = to_c - room["r"]
		s = maxf(s, room["floor"] - p.y)  # Solid below this room's floor.
		caves = _smin(caves, s, SMIN_K)
		hull = _smin(hull, to_c - (room["r"] + HULL_ROCK), SMIN_K * 1.6)
	for t: Dictionary in lay["tunnels"]:
		var a: Vector3 = t["a"]
		var ab: Vector3 = t["b"] - a
		var u := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
		var to_seg: float = p.distance_to(a + ab * u)
		var s: float = to_seg - t["r"]
		s = maxf(s, lerpf(t["floor_a"], t["floor_b"], u) - p.y)
		caves = _smin(caves, s, SMIN_K)
		if not t.get("bore", false):
			hull = _smin(hull, to_seg - ((t["r"] as float) + HULL_ROCK), SMIN_K * 1.6)
	return [hull, caves]


## How exposed to open sky a surface point is: 1.0 on the massif's outer hull,
## 0.0 on a carved interior wall, blending across ~3 m where the mouth bore
## pierces the shell (the doorway genuinely is both). The margin between the
## two fields decides: on the outer surface `hull` sits near 0 while `caves`
## is at least the shell thickness; on a cave wall `caves` sits near 0 while
## `hull` is that far negative. Wall noise shifts WHERE the surface lies, not
## which field claims it, so the classification is stable under undulation.
static func exposure(p: Vector3, lay: Dictionary) -> float:
	var parts := _field_parts(p, lay)
	return smoothstep(-1.5, 1.5, (parts[0] as float) + (parts[1] as float))


static func _smin(a: float, b: float, k: float) -> float:
	var h := clampf(0.5 + 0.5 * (b - a) / k, 0.0, 1.0)
	return lerpf(b, a, h) - k * h * (1.0 - h)


## The wall-undulation noise for a seed. ONE definition, shared by the mesher
## and by every field probe — a probe that built its own noise could disagree
## with the meshed rock and anchor fixtures into thin air.
static func make_noise(p_seed: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = p_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	noise.frequency = 0.055
	return noise


## Distance from a point in the void to the first rock surface along
## [param dir], or -1.0 if the ray reaches [param max_dist] still in void (or
## started inside rock). Coarse march to the first sign change, then bisection.
##
## Anything MOUNTED on a cave wall must find the wall this way. A nominal
## tunnel radius is not where the rock is: smooth-min blending and WALL_NOISE
## move the meshed surface, and the spine runs through room centres where the
## wall is a whole room-radius away.
static func wall_distance(from: Vector3, dir: Vector3, lay: Dictionary, noise: FastNoiseLite,
		max_dist: float = 9.0) -> float:
	if density(from, lay, noise) >= 0.0:
		return -1.0
	var ray := dir.normalized()
	var step := 0.12
	var prev := 0.0
	var t := step
	while t <= max_dist:
		if density(from + ray * t, lay, noise) >= 0.0:
			var lo := prev
			var hi := t
			for _i in 12:
				var mid := 0.5 * (lo + hi)
				if density(from + ray * mid, lay, noise) >= 0.0:
					hi = mid
				else:
					lo = mid
			return 0.5 * (lo + hi)
		prev = t
		t += step
	return -1.0


## A basis whose local +Y runs along [param dir]. Godot's primitives (cylinder,
## cone, torus) are all +Y-aligned, so this is how a torch part gets aimed.
static func _aim(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var ref := Vector3.UP if absf(y.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var x := ref.cross(y).normalized()
	return Basis(x, y, x.cross(y))


## Meshes the system with naive surface nets and bakes strata/sediment vertex
## colors. When both samplers are supplied, a second, render-only mesh carries
## the exposed terrain-contact weight in COLOR.a and exact local ground
## RGB/roughness in the two full-float UV channels. Keeping that transition
## separate means the rock mesh and its collision stay byte-for-byte unchanged;
## WorldGen still shapes the ground around the massif, and the samplers add
## material data only.
static func build_geometry(p_seed: int, terrain_h: Callable = Callable(),
		terrain_material: Callable = Callable()) -> Dictionary:
	var lay := layout(p_seed)
	var noise := make_noise(p_seed)

	var sampled := _sample_field(lay, noise)
	var field: PackedFloat32Array = sampled["field"]
	var lo: Vector3 = sampled["lo"]
	var nx: int = sampled["nx"]
	var ny: int = sampled["ny"]
	var nz: int = sampled["nz"]

	# The ACTUAL floor under the spawn: smin blending and wall noise carve
	# deeper than the room's nominal floor — probe the field column so the
	# wanderer wakes standing, not falling.
	var spawn: Vector3 = lay["spawn"]
	var six := clampi(int((spawn.x - lo.x) / CELL), 0, nx - 1)
	var siz := clampi(int((spawn.z - lo.z) / CELL), 0, nz - 1)
	var actual_floor: float = lay["spawn_floor"]
	var start_iy := clampi(int((spawn.y + 2.0 - lo.y) / CELL), 1, ny - 1)
	for iy in range(start_iy, 0, -1):
		var above: float = field[(six * ny + iy) * nz + siz]
		var below: float = field[(six * ny + iy - 1) * nz + siz]
		if above < 0.0 and below >= 0.0:
			actual_floor = lo.y + (iy - 1 + below / (below - above)) * CELL
			break
	lay["spawn_floor_actual"] = actual_floor

	# Surface nets: one vertex per sign-changing cell, at the mean of its
	# edge crossings; quads across every sign-changing grid edge.
	var cell_vert := {}
	var verts := PackedVector3Array()
	var cx := nx - 1
	var cy := ny - 1
	var cz := nz - 1
	for ix in cx:
		for iy in cy:
			for iz in cz:
				var corners: Array[float] = []
				var inside := 0
				for c in 8:
					var v: float = field[((ix + (c & 1)) * ny + (iy + ((c >> 1) & 1))) * nz + (iz + ((c >> 2) & 1))]
					corners.append(v)
					if v < 0.0:
						inside += 1
				if inside == 0 or inside == 8:
					continue
				var sum := Vector3.ZERO
				var count := 0
				for e: Array in _CELL_EDGES:
					var va: float = corners[e[0]]
					var vb: float = corners[e[1]]
					if (va < 0.0) == (vb < 0.0):
						continue
					var t := va / (va - vb)
					sum += _corner_offset(e[0]).lerp(_corner_offset(e[1]), t)
					count += 1
				cell_vert[Vector3i(ix, iy, iz)] = verts.size()
				verts.append(lo + (Vector3(ix, iy, iz) + sum / count) * CELL)

	var indices := PackedInt32Array()
	for ix in nx:
		for iy in ny:
			for iz in nz:
				# For each axis: the grid edge from this corner; the four
				# cells around it share a quad when the edge changes sign.
				var v0: float = field[(ix * ny + iy) * nz + iz]
				if ix < cx and iy > 0 and iz > 0 and iy <= cy and iz <= cz:
					var v1: float = field[((ix + 1) * ny + iy) * nz + iz]
					if (v0 < 0.0) != (v1 < 0.0):
						_emit_quad(indices, cell_vert,
							[Vector3i(ix, iy - 1, iz - 1), Vector3i(ix, iy, iz - 1), Vector3i(ix, iy, iz), Vector3i(ix, iy - 1, iz)],
							v0 < 0.0)
				if iy < cy and ix > 0 and iz > 0 and ix <= cx and iz <= cz:
					var v1: float = field[(ix * ny + iy + 1) * nz + iz]
					if (v0 < 0.0) != (v1 < 0.0):
						_emit_quad(indices, cell_vert,
							[Vector3i(ix - 1, iy, iz - 1), Vector3i(ix, iy, iz - 1), Vector3i(ix, iy, iz), Vector3i(ix - 1, iy, iz)],
							v0 >= 0.0)
				if iz < cz and ix > 0 and iy > 0 and ix <= cx and iy <= cy:
					var v1: float = field[(ix * ny + iy) * nz + iz + 1]
					if (v0 < 0.0) != (v1 < 0.0):
						_emit_quad(indices, cell_vert,
							[Vector3i(ix - 1, iy - 1, iz), Vector3i(ix, iy - 1, iz), Vector3i(ix, iy, iz), Vector3i(ix - 1, iy, iz)],
							v0 < 0.0)

	# Normals from the SDF gradient — smooth by construction.
	var normals := PackedVector3Array()
	normals.resize(verts.size())
	var eps := CELL * 0.6
	for i in verts.size():
		var p := verts[i]
		var g := Vector3(
			density(p + Vector3(eps, 0, 0), lay, noise) - density(p - Vector3(eps, 0, 0), lay, noise),
			density(p + Vector3(0, eps, 0), lay, noise) - density(p - Vector3(0, eps, 0), lay, noise),
			density(p + Vector3(0, 0, eps), lay, noise) - density(p - Vector3(0, 0, eps), lay, noise))
		normals[i] = -g.normalized()  # Toward the void: the visible side.

	# Baked shading: warm strata base, sediment floors, depth dimming. Alpha
	# carries the sky-exposure mask (see `exposure`): the shader weathers the
	# exterior by that weight, so interior walls — alpha 0 — keep today's look
	# exactly. Colors are not part of any determinism golden (both fingerprints
	# hash vertex POSITIONS), so the mask is free to ride here.
	var colors := PackedColorArray()
	colors.resize(verts.size())
	for i in verts.size():
		var p := verts[i]
		var band := noise.get_noise_2d(p.y * 3.1, 17.3) * 0.5 + 0.5
		var c := COL_ROCK_LIGHT.lerp(COL_ROCK_DARK, band)
		if normals[i].y > 0.5:
			c = c.lerp(COL_SEDIMENT, (normals[i].y - 0.5) * 1.6)
		var depth := clampf(-p.y / 8.0, 0.0, 0.55)
		c = c.darkened(depth * 0.4)
		c.a = exposure(p, lay)
		colors[i] = c

	# Local ground material at the cave/terrain intersection. This becomes a
	# render-only overlay below rather than changing the cave mesh's established
	# vertex format or the collision shape built from it.
	var ground_contact := PackedColorArray()
	ground_contact.resize(verts.size())
	var ground_material_uv := PackedVector2Array()
	ground_material_uv.resize(verts.size())
	var ground_material_uv2 := PackedVector2Array()
	ground_material_uv2.resize(verts.size())
	var contact_enabled := terrain_h.is_valid() and terrain_material.is_valid()
	for i in verts.size():
		var p := verts[i]
		var local_ground := Color.BLACK
		var local_roughness := 1.0
		var local_normal := Vector3.UP
		var local_ground_y := 0.0
		var contact := 0.0
		if contact_enabled:
			var ground_sample: Dictionary = terrain_material.call(p.x, p.z)
			local_ground = ground_sample[&"color"]
			local_roughness = ground_sample[&"roughness"]
			local_normal = ground_sample.get(&"normal", Vector3.UP) as Vector3
			local_ground_y = ground_sample.get(&"height", 0.0) as float
			var ground_y: float = terrain_h.call(p.x, p.z)
			var distance := absf(p.y - ground_y)
			contact = (1.0 - smoothstep(0.0, TERRAIN_CONTACT_BAND, distance)) * colors[i].a
		ground_contact[i] = Color(
			local_normal.x * 0.5 + 0.5,
			local_normal.z * 0.5 + 0.5,
			clampf(local_ground_y / (TERRAIN_HEIGHT_RANGE * 2.0) + 0.5, 0.0, 1.0),
			contact)
		ground_material_uv[i] = Vector2(local_ground.r, local_ground.g)
		ground_material_uv2[i] = Vector2(local_ground.b, local_roughness)

	# Do not send the duplicate full cave hull through the terrain shader.
	# Retain a source triangle only when at least one corner can receive contact;
	# interpolation needs the complete boundary triangle, but an all-zero
	# triangle can never contribute a pixel. Geometry and collision still use
	# the original complete index stream below.
	var contact_indices := PackedInt32Array()
	if contact_enabled:
		# COLOR is RGBA8 in ArrayMesh. A weight below one channel quantum
		# reaches the shader as zero and must not keep an otherwise empty
		# triangle alive.
		var visible_contact := 1.0 / 255.0
		for tri in range(0, indices.size(), 3):
			var i0 := indices[tri]
			var i1 := indices[tri + 1]
			var i2 := indices[tri + 2]
			if ground_contact[i0].a >= visible_contact \
					or ground_contact[i1].a >= visible_contact \
					or ground_contact[i2].a >= visible_contact:
				contact_indices.append(i0)
				contact_indices.append(i1)
				contact_indices.append(i2)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var contact_mesh: ArrayMesh = null
	if not contact_indices.is_empty():
		var contact_arrays := []
		contact_arrays.resize(Mesh.ARRAY_MAX)
		contact_arrays[Mesh.ARRAY_VERTEX] = verts
		contact_arrays[Mesh.ARRAY_NORMAL] = normals
		contact_arrays[Mesh.ARRAY_COLOR] = ground_contact
		contact_arrays[Mesh.ARRAY_TEX_UV] = ground_material_uv
		contact_arrays[Mesh.ARRAY_TEX_UV2] = ground_material_uv2
		contact_arrays[Mesh.ARRAY_INDEX] = contact_indices
		contact_mesh = ArrayMesh.new()
		contact_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, contact_arrays)
	return { "mesh": mesh, "terrain_contact_mesh": contact_mesh, "layout": lay }


const _CELL_EDGES: Array = [
	[0, 1], [2, 3], [4, 5], [6, 7],
	[0, 2], [1, 3], [4, 6], [5, 7],
	[0, 4], [1, 5], [2, 6], [3, 7],
]


static func _corner_offset(c: int) -> Vector3:
	return Vector3(c & 1, (c >> 1) & 1, (c >> 2) & 1)


static func _emit_quad(indices: PackedInt32Array, cell_vert: Dictionary, cells: Array, flip: bool) -> void:
	for cell: Vector3i in cells:
		if not cell_vert.has(cell):
			return
	var q: Array[int] = []
	for cell: Vector3i in cells:
		q.append(cell_vert[cell])
	if flip:
		indices.append_array(PackedInt32Array([q[0], q[1], q[2], q[0], q[2], q[3]]))
	else:
		indices.append_array(PackedInt32Array([q[0], q[2], q[1], q[0], q[3], q[2]]))


## Order-stable fingerprint for the determinism test.
static func fingerprint(mesh: ArrayMesh) -> String:
	var arrays := mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	return "verts=%d hash=%d" % [v.size(), hash(v.to_byte_array())]


## Samples the corner density field over the massif's bounds, returning the
## packed field plus its origin and dimensions, so the mesher and the
## connectivity audit share one sampling rather than two drifting copies.
##
## `pad` grows the sampled box outward. The mesher passes 0 (its bounds decide
## the mesh, so they must never move); the connectivity audit pads so the box
## certainly extends past the massif into genuine open air — that is what lets
## "escaped to the boundary" mean "walked out of the cave" without trusting any
## hand-picked exterior probe point.
static func _sample_field(lay: Dictionary, noise: FastNoiseLite, pad: float = 0.0) -> Dictionary:
	var lo := Vector3(1e6, 1e6, 1e6)
	var hi := Vector3(-1e6, -1e6, -1e6)
	for room: Dictionary in lay["rooms"]:
		lo = lo.min(room["center"] - Vector3.ONE * (room["r"] + HULL_ROCK + 2.5))
		hi = hi.max(room["center"] + Vector3.ONE * (room["r"] + HULL_ROCK + 2.5))
	lo = lo.min(lay["mouth"] + Vector3(-2.0, -6.0, -8.0))
	hi = hi.max(lay["mouth"] + Vector3(9.0, 6.0, 8.0))
	lo -= Vector3.ONE * pad
	hi += Vector3.ONE * pad

	var nx := int(ceilf((hi.x - lo.x) / CELL)) + 1
	var ny := int(ceilf((hi.y - lo.y) / CELL)) + 1
	var nz := int(ceilf((hi.z - lo.z) / CELL)) + 1

	# Corner density field.
	var field := PackedFloat32Array()
	field.resize(nx * ny * nz)
	for ix in nx:
		for iy in ny:
			for iz in nz:
				field[(ix * ny + iy) * nz + iz] = density(lo + Vector3(ix, iy, iz) * CELL, lay, noise)
	return { "field": field, "lo": lo, "nx": nx, "ny": ny, "nz": nz }


const _NEIGHBOURS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]
const _WAKE_ROOM := 2 ## rooms[2] is the main chamber the wanderer wakes in.
const AUDIT_PAD := 4.0 ## Audit-only sampling margin, so the box reaches open air.

## --- The wanderer's body, as the connectivity audit models it ---
## Mirrors the capsule in player.gd. A connectivity guard that does not model
## the body it is clearing space for is only guessing, so these are pinned
## against player.gd by cave_connectivity_test.
const BODY_RADIUS := 0.4 ## Capsule radius, metres (player.gd).
const BODY_HEIGHT := 1.8 ## Capsule total height, metres (player.gd).
## Cell counts derived from the body above at CELL resolution. GDScript cannot
## compute these in a const expression, so they are written out and the test
## re-derives them — if CELL or the capsule ever changes, that check fails
## rather than the audit silently clearing the wrong volume.
const BODY_CELLS := 3 ## ceil(BODY_HEIGHT / CELL) — 1.95 m of headroom.
const LATERAL_CELLS := 1 ## ceil(BODY_RADIUS / CELL) — 0.65 m of side clearance.
const STEP_CELLS := 1 ## Rise the wanderer can step up or down, in cells.

## Sideways clearance offsets, applied at every level of the body's column.
const _LATERAL: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

## How a walking body moves between cells: a lateral step on the level, or the
## same step while rising or dropping one cell. Never straight up or down —
## the wanderer walks and steps, it does not climb shafts or fly.
const _WALK_STEPS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
	Vector3i(1, 1, 0), Vector3i(-1, 1, 0),
	Vector3i(0, 1, 1), Vector3i(0, 1, -1),
	Vector3i(1, -1, 0), Vector3i(-1, -1, 0),
	Vector3i(0, -1, 1), Vector3i(0, -1, -1),
]


## Flat field index of a corner cell — multiplication only, no integer division
## (this repo treats an integer-division warning as an error).
static func _fi(c: Vector3i, ny: int, nz: int) -> int:
	return (c.x * ny + c.y) * nz + c.z


## Is this cell void? Out of range counts as void: the audit pads its sampled box
## past the massif, so anything outside it is open air by construction.
static func _void_at(field: PackedFloat32Array, nx: int, ny: int, nz: int, c: Vector3i) -> bool:
	if c.x < 0 or c.x >= nx or c.y < 0 or c.y >= ny or c.z < 0 or c.z >= nz:
		return true
	return field[_fi(c, ny, nz)] < 0.0


## Does the player's BODY fit here, standing upright? [param c] is the FOOT
## cell. The capsule is 0.4 m in radius and 1.8 m tall (player.gd), so the whole
## column of BODY_CELLS cells from the feet up must be void, and every one of
## those levels must also be void one cell out sideways.
##
## This is a volume test, not a floor test: it says the body would not be inside
## rock here, and nothing about whether anything holds it up. That is what
## [method standing] adds. Together they are what turn the old one-cell erosion —
## which rejected sub-cell pinholes but happily routed the wanderer through a
## crawlspace or across thin air — into a body the audit can actually walk.
##
## WHAT THIS IS AND IS NOT. It is a discrete model of the capsule on a 0.65 m
## grid, not a continuous sweep, and it is deliberately CONSERVATIVE: a route it
## clears is one the player can take, but it may refuse a route they could
## actually squeeze through. Three places that shows:
##   - sideways clearance is counted in whole cells, so it asks for 1.95 m of
##     width where the body needs 0.8 m;
##   - support is the single cell under the feet, so a floor that crosses a cell
##     diagonally can read as unsupported and the walk refuses a real footing;
##   - the walk moves on axes and single steps, so it does not model diagonal
##     movement, jumping, or falling any distance.
## Erring toward refusing a real route is the safe direction here: the guard
## exists to catch a cave the player cannot cross, and a false alarm is a
## reviewed test failure while a miss is a player sealed in forever.
static func body_fits(field: PackedFloat32Array, nx: int, ny: int, nz: int, c: Vector3i) -> bool:
	if c.x < 0 or c.x >= nx or c.y < 0 or c.y >= ny or c.z < 0 or c.z >= nz:
		return false
	# BODY_CELLS + 1 samples, not BODY_CELLS. The field stores densities at grid
	# CORNERS, so sampling levels 0..BODY_CELLS-1 only reaches (BODY_CELLS-1) ×
	# CELL = 1.30 m up — the wanderer's head is at 1.8 m and would go unchecked.
	# The boundary sample at BODY_CELLS is what covers it.
	for dy in range(0, BODY_CELLS + 1):
		var level := c + Vector3i(0, dy, 0)
		if not _void_at(field, nx, ny, nz, level):
			return false
		# Sideways clearance is measured over the body's TRUNK, not at the feet.
		# A tunnel is round: 0.65 m out from where a wanderer's boots rest, the
		# floor has already curved up into wall. Demanding side clearance at foot
		# level therefore rejects the middle of a perfectly walkable tunnel — the
		# cell is the contact surface, and the space the body needs is above it.
		# A slit too narrow to squeeze through is still caught, because a gap
		# that pinches the trunk pinches it at trunk height too.
		if dy == 0:
			continue
		for step: Vector3i in _LATERAL:
			if not _void_at(field, nx, ny, nz, level + step):
				return false
	return true


## Can the wanderer STAND here — the body fits AND there is rock directly under
## its feet to carry it? Open space below fails: a route through mid-air is not
## a route a walking body can take, and treating it as one is exactly how a
## connectivity audit certifies a cave the player cannot actually cross.
##
## Unsampled space below the box counts as no floor, not as rock — the audit
## only vouches for what it measured.
## Support is the cell DIRECTLY beneath the feet, and nothing looser. Allowing
## rock to be found a cell or two further down sounds like harmless tolerance
## for a floor that crosses cells diagonally, but it is the thin-air false
## positive this guard exists to catch: with an empty cell under the feet the
## wanderer falls, and the floor they land on is a cell the audit can judge on
## its own terms. A body one cell above the rock is not standing on it.
##
## Nothing is lost by being strict. Where the real floor is a cell lower, that
## lower cell is itself a standing cell, and the walk reaches it through the
## ordinary step-down move.
static func standing(field: PackedFloat32Array, nx: int, ny: int, nz: int, c: Vector3i) -> bool:
	if not body_fits(field, nx, ny, nz, c):
		return false
	return not _void_at(field, nx, ny, nz, c - Vector3i(0, 1, 0))


## Flood-fills free space the BODY fits through, 6-connected from `start`.
## Used for open air outside the massif, where there is no sampled floor to
## stand on — for anywhere the wanderer must WALK, use [method flood_walkable].
static func flood_passable(field: PackedFloat32Array, nx: int, ny: int, nz: int, start: Vector3i) -> PackedByteArray:
	return _flood(field, nx, ny, nz, start, _NEIGHBOURS, false)


## Flood-fills the cells the wanderer can WALK between: standing cells joined by
## a lateral step, or a step up/down of one cell (STEP_CELLS × CELL of rise,
## which the character controller climbs). This is the traversal proof — a
## region here is somewhere a body on its feet can actually get to.
static func flood_walkable(field: PackedFloat32Array, nx: int, ny: int, nz: int, start: Vector3i) -> PackedByteArray:
	return _flood(field, nx, ny, nz, start, _WALK_STEPS, true)


static func _flood(field: PackedFloat32Array, nx: int, ny: int, nz: int, start: Vector3i,
		steps: Array[Vector3i], grounded: bool) -> PackedByteArray:
	var seen := PackedByteArray()
	seen.resize(field.size())
	seen.fill(0)
	if not _ok(field, nx, ny, nz, start, grounded):
		return seen
	var stack: Array[Vector3i] = [start]
	seen[_fi(start, ny, nz)] = 1
	while not stack.is_empty():
		var c := stack.pop_back() as Vector3i
		for step: Vector3i in steps:
			var j := c + step
			if j.x < 0 or j.x >= nx or j.y < 0 or j.y >= ny or j.z < 0 or j.z >= nz:
				continue
			var n := _fi(j, ny, nz)
			if seen[n] != 0 or not _ok(field, nx, ny, nz, j, grounded):
				continue
			# Rising a cell is a JUMP — the controller has no mantle logic, only
			# a 7.2 m/s hop (player.gd), which clears 1.32 m and so easily clears
			# one cell. What it needs is somewhere to put the body while rising:
			# under a ceiling at bare standing height the wanderer would strike
			# their head and never reach the ledge. Falling needs no such room.
			if grounded and step.y > 0 and not body_fits(field, nx, ny, nz, c + Vector3i(0, 1, 0)):
				continue
			seen[n] = 1
			stack.append(j)
	return seen


static func _ok(field: PackedFloat32Array, nx: int, ny: int, nz: int, c: Vector3i, grounded: bool) -> bool:
	return standing(field, nx, ny, nz, c) if grounded else body_fits(field, nx, ny, nz, c)


## The corner cell a world point actually falls in — no projection onto a nearby
## void cell. An audited point that lands in rock must FAIL the audit, never
## silently borrow the verdict of a neighbouring cavity.
static func cell_of(point: Vector3, lo: Vector3, nx: int, ny: int, nz: int) -> Vector3i:
	return Vector3i(
		clampi(int(round((point.x - lo.x) / CELL)), 0, nx - 1),
		clampi(int(round((point.y - lo.y) / CELL)), 0, ny - 1),
		clampi(int(round((point.z - lo.z) / CELL)), 0, nz - 1))


## Is this exact point reachable? Two conditions, both required:
##  1. the point's OWN density is void — sampled at the point, not at a corner,
##     because `cell_of` rounds and would otherwise let a point sitting in rock
##     within CELL/2 of a reachable corner borrow that corner's verdict (the
##     thin-wall case this guard exists to catch);
##  2. the cell it falls in was reached by the clearance-eroded flood.

## Connectivity audit of the carved cave: floods the space a body can move
## through, starting from the waking chamber, and reports whether the spawn and
## every room centre are reachable and whether the flood ESCAPES the padded box
## (i.e. reaches open air — the way out). This is the no-resets law in code: a
## seed or layout change that sealed a player into an unreachable pocket flips
## one of these false, and CI catches it before a player ever could.
static func reachability(p_seed: int) -> Dictionary:
	var lay := layout(p_seed)
	var noise := make_noise(p_seed)
	var sampled := _sample_field(lay, noise, AUDIT_PAD)
	var field: PackedFloat32Array = sampled["field"]
	var lo: Vector3 = sampled["lo"]
	var nx: int = sampled["nx"]
	var ny: int = sampled["ny"]
	var nz: int = sampled["nz"]
	var rooms: Array = lay["rooms"]

	# Audited points are authored at chamber CENTRES — mid-air, a body-height or
	# more above the floor. The wanderer stands on the floor, so every audited
	# point drops to the ground under it before being judged; asking whether a
	# point hanging in space is walkable would fail every seed for the wrong
	# reason.
	var wake := (rooms[_WAKE_ROOM] as Dictionary)["center"] as Vector3
	var start := ground_cell(field, nx, ny, nz, cell_of(wake, lo, nx, ny, nz))
	var seen := flood_walkable(field, nx, ny, nz, start)

	var reached := 0
	for i in seen.size():
		reached += seen[i]

	var rooms_reachable: Array[bool] = []
	for room: Dictionary in rooms:
		rooms_reachable.append(
			walk_reached(room["center"] as Vector3, lay, noise, seen, field, lo, nx, ny, nz))
	return {
		"reached": reached,
		"total": field.size(),
		"start_passable": standing(field, nx, ny, nz, start),
		"spawn_reachable": walk_reached(
			lay["spawn"] as Vector3, lay, noise, seen, field, lo, nx, ny, nz),
		"mouth_open": _walks_out(field, nx, ny, nz, seen),
		"rooms_reachable": rooms_reachable,
		# The sampled field and its walkable mask, so a test can probe specific
		# points against the same audit rather than re-deriving one that might
		# not agree with it.
		"seen": seen,
		"field": field,
		"lo": lo,
		"nx": nx,
		"ny": ny,
		"nz": nz,
	}


## The cell a body dropped at [param c] comes to rest in: the first cell at or
## below it that the wanderer can stand in. Falls back to [param c] so callers
## always get a cell to judge (an unstandable one simply floods nothing).
static func ground_cell(field: PackedFloat32Array, nx: int, ny: int, nz: int, c: Vector3i,
		span: int = 8) -> Vector3i:
	# The descent stops at rock. Scanning past a slab would let a sealed pocket
	# be certified by the walkable corridor beneath it — the point would "fall"
	# through solid stone to a floor it has no way of reaching.
	for dy in range(0, span + 1):
		var below := c - Vector3i(0, dy, 0)
		if below.y < 0 or not _void_at(field, nx, ny, nz, below):
			break
		if standing(field, nx, ny, nz, below):
			return below
	# Authored a touch under the floor (rounding, or a sloped chamber base):
	# look up a little too before giving up — through open space only, for the
	# same reason.
	for dy in range(1, span + 1):
		var above := c + Vector3i(0, dy, 0)
		if above.y >= ny or not _void_at(field, nx, ny, nz, above):
			break
		if standing(field, nx, ny, nz, above):
			return above
	return c


## Can the wanderer walk to [param point] — dropped to the ground beneath it, is
## that cell in the walkable region?
##
## The point is first judged at its OWN position in the SDF. `cell_of` rounds to
## the nearest corner, so a point buried in rock within half a cell of a
## reachable floor column would otherwise round onto that column and be
## certified reachable — borrowing space it is separated from by a wall. An
## audited point inside rock must fail, whatever is next to it.
static func walk_reached(point: Vector3, lay: Dictionary, noise: FastNoiseLite,
		seen: PackedByteArray, field: PackedFloat32Array,
		lo: Vector3, nx: int, ny: int, nz: int) -> bool:
	if density(point, lay, noise) >= 0.0:
		return false
	var c := ground_cell(field, nx, ny, nz, cell_of(point, lo, nx, ny, nz))
	return seen[_fi(c, ny, nz)] == 1


## Is there a way OUT — can the wanderer walk to somewhere daylight is straight
## ahead? The walkable flood cannot itself leave the massif: outside it there is
## no sampled floor to stand on, because the audit models the mountain and not
## the world's terrain, which takes over at the mouth. So a walk-out has to be
## judged at the threshold, not by the flood escaping the box, which no grounded
## flood ever could.
##
## The test is a LINE OF SIGHT out: from some cell the wanderer can walk to, a
## horizontal ray at body height leaves the box without meeting rock. That is
## the mouth — a passage you can walk at and emerge from.
##
## Flooding all boundary-connected air and asking whether a walked cell touches
## it does NOT work, and the difference matters: air inside the cave is itself
## connected to the outside through the mouth, so that flood marks the whole
## interior as open air and every walked cell trivially satisfies it. It would
## report a way out for a cave whose only breach is a shaft nobody can climb.
static func _walks_out(field: PackedFloat32Array, nx: int, ny: int, nz: int,
		seen: PackedByteArray) -> bool:
	for ix in nx:
		for iy in ny:
			for iz in nz:
				if seen[(ix * ny + iy) * nz + iz] == 0:
					continue
				if _sees_daylight(field, nx, ny, nz, Vector3i(ix, iy, iz)):
					return true
	return false


## Does a horizontal ray from this cell reach the edge of the box without
## meeting rock, over the whole height of the body? Checked on all four axes —
## the mouth faces whichever way the layout put it.
static func _sees_daylight(field: PackedFloat32Array, nx: int, ny: int, nz: int, c: Vector3i) -> bool:
	for dir: Vector3i in _LATERAL:
		var at := c
		var clear := true
		while true:
			at += dir
			if at.x < 0 or at.x >= nx or at.z < 0 or at.z >= nz:
				break # Walked off the edge of the box: daylight.
			if not _has_rock_below(field, nx, ny, nz, at):
				break # Past the mountain — the world's terrain carries on here.
			# Still inside the massif, so the wanderer has to WALK it: a
			# body-sized hole is not an exit if there is no floor under it.
			if not standing(field, nx, ny, nz, at):
				clear = false
				break
		if clear:
			return true
	return false


## Is there any rock beneath this column inside the sampled box? While there is,
## we are still in the mountain and the audit is answerable for the floor. Once
## there is none, we have passed the massif and the overworld heightfield — which
## this field deliberately does not model — takes over.
static func _has_rock_below(field: PackedFloat32Array, nx: int, ny: int, nz: int, c: Vector3i) -> bool:
	for y in range(c.y - 1, -1, -1):
		if not _void_at(field, nx, ny, nz, Vector3i(c.x, y, c.z)):
			return true
	return false


## In-scene build: mesh + collision + torches + mouth boulders. The terrain
## callable maps LOCAL (x, z) to LOCAL floor height of the surrounding world
## (identity 0.0 height for the standalone taste scene).
func rebuild(terrain_h: Callable = func(_x: float, _z: float) -> float: return 0.0,
		terrain_material: Callable = Callable()) -> void:
	for node in _built:
		node.queue_free()
	_built.clear()
	_torch_lights.clear()
	_torch_flames.clear()
	_torch_phases = PackedFloat32Array()

	var built := CaveSystemGen.build_geometry(seed_value, terrain_h, terrain_material)
	var mesh: ArrayMesh = built["mesh"]
	var lay: Dictionary = built["layout"]
	last_layout = lay

	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/cave_rock.gdshader")
	mesh.surface_set_material(0, mat)

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	add_child(mi)
	_built.append(mi)
	var contact_mesh: ArrayMesh = built[&"terrain_contact_mesh"]
	if contact_mesh != null:
		var contact_mat := ShaderMaterial.new()
		contact_mat.shader = load("res://shaders/cave_terrain_contact.gdshader")
		contact_mat.set_shader_parameter(
			"plates_enabled", OS.get_environment("WAR_GROUND_PLATES") == "1")
		contact_mat.render_priority = 1
		contact_mesh.surface_set_material(0, contact_mat)
		var contact_mi := MeshInstance3D.new()
		contact_mi.name = "TerrainContact"
		contact_mi.mesh = contact_mesh
		add_child(contact_mi)
		_built.append(contact_mi)
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var trimesh := mesh.create_trimesh_shape() as ConcavePolygonShape3D
	trimesh.backface_collision = true
	shape.shape = trimesh
	body.add_child(shape)
	add_child(body)
	_built.append(body)

	_place_torches(lay)
	_place_boulders(lay, terrain_h)


## Torches along the spine, each BRACKETED TO THE ROCK — the light that pulls a
## wanderer through the dark (and the WoW cave signature).
##
## Every torch finds its own wall by probing the density field outward from the
## spine at mounting height. The old fixed 1.5 m sideways offset is exactly
## what left them hanging in mid-air: tunnels are r≈2.15–2.6 m before wall
## noise, and the spine's waypoints ARE room centres, where the nearest rock is
## a room radius (up to 5.6 m) away — so a 1.5 m offset put the torch in open
## space nearly everywhere, and in the middle of a chamber at worst.
## A torch that finds no wall within reach is skipped rather than floated.
func _place_torches(lay: Dictionary) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 3
	var noise := CaveSystemGen.make_noise(seed_value)
	var path: Array = lay["path"]
	var floors: PackedFloat32Array = lay["floors"]
	var mats := {
		"iron": _flat(COL_IRON, 0.55),
		"wood": _flat(COL_WOOD, 0.9),
		"pitch": _flat(COL_PITCH, 1.0),
		"flame": _glow(COL_EMBER, 2.4),
		"core": _glow(COL_FLAME_CORE, 4.0),
	}
	var side := 1.0
	for i in path.size() - 1:
		var a: Vector3 = path[i]
		var b: Vector3 = path[i + 1]
		var steps := maxi(1, roundi((b - a).length() / TORCH_SPACING))
		for s in steps:
			var u := (s + 0.5) / steps
			var at := a.lerp(b, u)
			var floor_y := lerpf(floors[i], floors[i + 1], u)
			var wall_dir := (b - a).cross(Vector3.UP).normalized() * side
			side = -side
			# Probe from the spine at mounting height out to the rock.
			var from := Vector3(at.x, floor_y + TORCH_MOUNT_H, at.z)
			var dist := CaveSystemGen.wall_distance(from, wall_dir, lay, noise)
			if dist < TORCH_MIN_WALL:
				continue
			# Seat the backplate a hair inside the void so it beds into the
			# wall instead of z-fighting the meshed surface.
			var torch := _make_torch(from + wall_dir * (dist - 0.04), -wall_dir, mats)
			add_child(torch)
			_built.append(torch)
			_torch_phases.append(rng.randf_range(0.0, TAU))


## One wall torch, built at [param mount] on the rock with [param into] facing
## the open cave: an iron backplate and arm biting the wall, a collar, a shaft
## leaning up and out of it, a pitch-soaked wrapped head, and a two-cone flame.
##
## The old torch was a bare vertical cylinder with a sphere sitting at its top —
## a lollipop, with nothing tying it to anything. The bracket is what makes it
## read as MOUNTED, and the lean plus the tapered flame are what make it read as
## a TORCH. The flame is aimed at world up, not along the shaft: fire rises
## whatever angle it burns on.
func _make_torch(mount: Vector3, into: Vector3, mats: Dictionary) -> Node3D:
	var torch := Node3D.new()
	torch.position = mount
	var lean := (Vector3.UP * cos(TORCH_LEAN) + into * sin(TORCH_LEAN)).normalized()
	var base := into * 0.07 + Vector3.DOWN * 0.10
	var collar_at := base + lean * 0.30
	var head_at := base + lean * TORCH_SHAFT
	var tip := head_at + lean * 0.06

	# Backplate flat against the rock, and the arm out to the collar.
	_part(torch, _cyl(0.12, 0.12, 0.07), mats["iron"], into * 0.035, into)
	var arm := collar_at - into * 0.07
	_part(torch, _cyl(0.022, 0.022, arm.length()), mats["iron"],
		into * 0.07 + arm * 0.5, arm)
	var collar := TorusMesh.new()
	collar.inner_radius = 0.045
	collar.outer_radius = 0.078
	_part(torch, collar, mats["iron"], collar_at, lean)

	# Shaft, then the soaked wrapping flaring at the head.
	_part(torch, _cyl(0.034, 0.055, TORCH_SHAFT), mats["wood"],
		base + lean * (TORCH_SHAFT * 0.5), lean)
	_part(torch, _cyl(0.070, 0.058, 0.17), mats["pitch"], head_at, lean)

	# Flame: an outer cone with a hotter core inside, both rising vertically.
	# Their bases sit BELOW the head's top so they socket into the wrapping —
	# a vertical cone meeting an angled head leaves a visible notch otherwise,
	# and a flame that hovers off its own torch is the bug in miniature.
	# The outer cone's base is WIDER than the head's flare, so its skirt covers
	# the wrapping instead of letting a dark wedge poke through the flame.
	var flame := _part(torch, _cyl(0.0, 0.098, 0.40), mats["flame"],
		tip + Vector3.UP * 0.145, Vector3.UP)
	_part(torch, _cyl(0.0, 0.048, 0.26), mats["core"], tip + Vector3.UP * 0.075, Vector3.UP)
	_torch_flames.append(flame)

	var light := OmniLight3D.new()
	light.light_color = COL_EMBER
	light.omni_range = 9.0
	light.light_energy = 2.1
	light.shadow_enabled = true
	light.position = tip + Vector3.UP * 0.16
	torch.add_child(light)
	_torch_lights.append(light)
	return torch


func _part(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3, aim: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.set_surface_override_material(0, mat)
	mi.transform = Transform3D(CaveSystemGen._aim(aim), pos)
	parent.add_child(mi)
	return mi


static func _cyl(top: float, bottom: float, height: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = top
	m.bottom_radius = bottom
	m.height = height
	return m


static func _flat(color: Color, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	return m


static func _glow(color: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m


## Big leaning slabs framing the mouth — the WoW cave-entrance grammar; they
## sit ON the ground flanking the bore and hide the cave↔terrain seam.
func _place_boulders(lay: Dictionary, terrain_h: Callable) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 7
	var mouth: Vector3 = lay["mouth"]
	var rock := StandardMaterial3D.new()
	rock.albedo_color = Color(0.41, 0.36, 0.3)
	rock.roughness = 0.95
	# The PORTAL: the massif's own arch is the lintel; two jamb slabs lean at
	# the doorway's shoulders, flanking boulders scatter outward — a stone
	# doorway in a hillside, the reference grammar.
	var jamb_left := _slab(rng, rock, Vector3(2.0, 4.6, 1.6))
	var jamb_right := _slab(rng, rock, Vector3(2.0, 4.4, 1.6))
	var ground_l: float = terrain_h.call(mouth.x + 1.4, 3.3)
	var ground_r: float = terrain_h.call(mouth.x + 1.4, -3.3)
	jamb_left.position = Vector3(mouth.x + 1.4, ground_l + 1.7, 3.3)
	jamb_left.rotation = Vector3(0.06, rng.randf_range(-0.3, 0.3), 0.12)
	jamb_right.position = Vector3(mouth.x + 1.4, ground_r + 1.6, -3.3)
	jamb_right.rotation = Vector3(-0.05, rng.randf_range(-0.3, 0.3), -0.1)
	# Flanking boulders, never in the walk-out corridor (z ≈ 0).
	var spots: Array[Vector3] = [
		Vector3(mouth.x + 3.4, 0.0, 4.4), Vector3(mouth.x + 5.4, 0.0, 3.4),
		Vector3(mouth.x + 3.4, 0.0, -4.4), Vector3(mouth.x + 5.4, 0.0, -3.4),
		Vector3(mouth.x - 0.8, 0.0, 4.8), Vector3(mouth.x - 0.8, 0.0, -4.8),
	]
	for spot in spots:
		var size := Vector3(rng.randf_range(1.3, 2.2), rng.randf_range(1.8, 3.2), rng.randf_range(1.1, 1.9))
		var at := spot + Vector3(rng.randf_range(-0.4, 0.4), 0.0, rng.randf_range(-0.3, 0.3))
		var ground: float = terrain_h.call(at.x, at.z)
		var boulder := _slab(rng, rock, size)
		# A third buried, leaning like a fallen slab.
		boulder.position = Vector3(at.x, ground + size.y * 0.32, at.z)
		boulder.rotation = Vector3(rng.randf_range(-0.28, 0.1), rng.randf_range(0.0, TAU), rng.randf_range(-0.25, 0.25))


func _slab(rng: RandomNumberGenerator, rock: StandardMaterial3D, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.set_surface_override_material(0, rock)
	body.add_child(mi)
	var col := CollisionShape3D.new()
	col.shape = box.create_convex_shape()
	body.add_child(col)
	add_child(body)
	_built.append(body)
	return body
