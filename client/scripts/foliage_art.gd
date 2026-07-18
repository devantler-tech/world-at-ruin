class_name FoliageArt
extends RefCounted
## How a cosmetic ground prop LOOKS. [FoliageGen] answers where a prop sits and
## which kind it is; this library answers what the player actually sees there.
##
## Split out of [WorldGen] deliberately. Prop art here is generated "as code" —
## every mesh, texture and material is built from a seeded, deterministic recipe
## with no imported assets — so it is worth its own testable surface rather than
## a pair of `match` blocks buried in the world builder.
##
## What this replaced, and why (#146, part of the quality-bar epic #123): ground
## cover used to be a `SphereMesh` shrub, a `PrismMesh` tuft and two `BoxMesh`
## debris kinds, each with a single flat `albedo_color`. Against the quality
## bar's four tells that is engine-primitives-as-art, flat materials, and no
## second-order life. The answers here, in order of how much they change the
## frame:
##   * SILHOUETTE — vegetation is crossed alpha-cutout cards carrying generated
##     leaf and blade masks, so a shrub reads as foliage against the sky rather
##     than as a ball. Debris is an irregular jittered cluster, not a box.
##   * MATERIAL DEPTH — every kind gets a generated albedo texture with real
##     tonal variation (noise mottling for stone, baked ambient darkening toward
##     the base for vegetation), plus a per-instance tint band applied in the
##     shader, so a field of props is no longer one flat hue.
##   * LIFE — vegetation sways, anchored at the base.
##
## NOTHING HERE TOUCHES PLACEMENT. Swapping a mesh cannot move a prop, so the
## committed foliage scatter golden (a fingerprint of [FoliageGen.scatter], a
## pure library) and the world golden (which walks node transforms and
## [MeshInstance3D] AABBs — foliage batches are [MultiMeshInstance3D]) are both
## unaffected. The one coupling that does exist is deliberate: [WorldGen] lifts
## each prop by a fraction of its mesh AABB height, so every mesh here is
## modelled CENTRED ON ITS OWN ORIGIN, exactly as the primitives were.

const SHADER: Shader = preload("res://shaders/foliage.gdshader")

## Texture edge in pixels. Small on purpose: these are ground props seen at a
## distance, and mipmaps matter far more than resolution for keeping a field of
## cutouts from shimmering.
const TEX_SIZE := 128

## Per-kind RNG seeds. Fixed constants, never a clock or the global RNG, so the
## generated art is byte-identical every boot.
const SEED_SHRUB := 91_001
const SEED_GRASS := 91_002
const SEED_BONE := 91_003
const SEED_RUBBLE := 91_004


## The prop mesh for `kind`, centred on its origin (see the class docstring).
static func mesh_for(kind: int) -> Mesh:
	match kind:
		FoliageGen.Kind.ASH_SHRUB:
			return crossed_cards(0.80, 0.75, 3)
		FoliageGen.Kind.DEAD_GRASS:
			return crossed_cards(0.55, 0.50, 2)
		FoliageGen.Kind.BONE_PILE:
			return bone_cluster(SEED_BONE)
		_:
			return rubble_cluster(SEED_RUBBLE)


## The material for `kind`. All four share [constant SHADER] and differ only in
## uniforms — vegetation sways and lifts its normals skyward, debris does not.
static func material_for(kind: int) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	match kind:
		FoliageGen.Kind.ASH_SHRUB:
			mat.set_shader_parameter("albedo_tex", leaf_texture(SEED_SHRUB, 84))
			mat.set_shader_parameter("tint_low", Color(0.82, 0.79, 0.70))
			mat.set_shader_parameter("tint_high", Color(1.06, 1.02, 0.88))
			mat.set_shader_parameter("wind_strength", 0.055)
			mat.set_shader_parameter("wind_speed", 1.35)
			mat.set_shader_parameter("normal_lift", 0.22)
			mat.set_shader_parameter("backlight_tint", Color(0.30, 0.22, 0.13))
			mat.set_shader_parameter("roughness_value", 0.92)
		FoliageGen.Kind.DEAD_GRASS:
			mat.set_shader_parameter("albedo_tex", blade_texture(SEED_GRASS, 30))
			mat.set_shader_parameter("tint_low", Color(0.84, 0.80, 0.66))
			mat.set_shader_parameter("tint_high", Color(1.10, 1.05, 0.82))
			mat.set_shader_parameter("wind_strength", 0.075)
			mat.set_shader_parameter("wind_speed", 1.9)
			mat.set_shader_parameter("normal_lift", 0.18)
			mat.set_shader_parameter("backlight_tint", Color(0.34, 0.26, 0.14))
			mat.set_shader_parameter("roughness_value", 0.95)
		FoliageGen.Kind.BONE_PILE:
			mat.set_shader_parameter("albedo_tex",
				stone_texture(SEED_BONE, Color(0.53, 0.51, 0.45), Color(0.86, 0.84, 0.76), 7.0))
			mat.set_shader_parameter("tint_low", Color(0.86, 0.86, 0.84))
			mat.set_shader_parameter("tint_high", Color(1.08, 1.06, 1.00))
			mat.set_shader_parameter("wind_strength", 0.0)
			mat.set_shader_parameter("normal_lift", 0.0)
			mat.set_shader_parameter("roughness_value", 0.78)
		_:
			mat.set_shader_parameter("albedo_tex",
				stone_texture(SEED_RUBBLE, Color(0.24, 0.23, 0.22), Color(0.52, 0.50, 0.47), 5.0))
			mat.set_shader_parameter("tint_low", Color(0.80, 0.80, 0.80))
			mat.set_shader_parameter("tint_high", Color(1.14, 1.10, 1.04))
			mat.set_shader_parameter("wind_strength", 0.0)
			mat.set_shader_parameter("normal_lift", 0.0)
			mat.set_shader_parameter("roughness_value", 0.88)
	return mat


## Crossed alpha-cutout cards: the standard way vegetation gets a real
## silhouette without real geometry. `planes` quads share a centre, each rotated
## evenly about Y, so the prop reads as foliage from every approach angle rather
## than flipping to an edge-on sliver.
##
## Centred vertically (y spans ±`height`/2) to keep [WorldGen]'s AABB-based
## ground lift correct. UV v runs 1 at the base to 0 at the tip, which is what
## the shader's wind weighting and the baked ambient darkening both key on.
static func crossed_cards(width: float, height: float, planes: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var half_w := width * 0.5
	var half_h := height * 0.5
	var count := maxi(planes, 1)
	for plane in count:
		var yaw := PI * float(plane) / float(count)
		var right := Vector3(cos(yaw), 0.0, sin(yaw)) * half_w
		var facing := Vector3(-sin(yaw), 0.0, cos(yaw))
		var base := verts.size()
		verts.push_back(-right + Vector3.DOWN * half_h)
		verts.push_back(right + Vector3.DOWN * half_h)
		verts.push_back(right + Vector3.UP * half_h)
		verts.push_back(-right + Vector3.UP * half_h)
		uvs.push_back(Vector2(0.0, 1.0))
		uvs.push_back(Vector2(1.0, 1.0))
		uvs.push_back(Vector2(1.0, 0.0))
		uvs.push_back(Vector2(0.0, 0.0))
		for _n in 4:
			normals.push_back(facing)
		for offset: int in [0, 1, 2, 0, 2, 3]:
			indices.push_back(base + offset)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## A scatter of angular stone chunks — the replacement for a single axis-aligned
## `BoxMesh`. Several jittered, independently rotated pieces give the broken
## silhouette that reads as rubble rather than as a crate.
static func rubble_cluster(rng_seed: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var builder := MeshBuilder.new()
	for _i in 4:
		var yaw := rng.randf_range(0.0, TAU)
		var tilt := rng.randf_range(-0.35, 0.35)
		var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, tilt)
		var centre := Vector3(
			rng.randf_range(-0.14, 0.14), rng.randf_range(-0.05, 0.05), rng.randf_range(-0.14, 0.14))
		var size := Vector3(
			rng.randf_range(0.14, 0.26), rng.randf_range(0.09, 0.17), rng.randf_range(0.13, 0.24))
		builder.push_chunk(centre, size, basis, 0.22, rng)
	return builder.commit()


## A heap of long, thin, flat-lying pieces — bones, not a box. Same jittered
## chunk primitive as rubble, shaped and laid out differently.
static func bone_cluster(rng_seed: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var builder := MeshBuilder.new()
	for _i in 5:
		var yaw := rng.randf_range(0.0, TAU)
		var tilt := rng.randf_range(-0.18, 0.18)
		var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.FORWARD, tilt)
		var centre := Vector3(
			rng.randf_range(-0.13, 0.13), rng.randf_range(-0.04, 0.06), rng.randf_range(-0.11, 0.11))
		var size := Vector3(
			rng.randf_range(0.28, 0.46), rng.randf_range(0.045, 0.075), rng.randf_range(0.05, 0.085))
		# Bones are smooth, so jitter them far less than stone.
		builder.push_chunk(centre, size, basis, 0.08, rng)
	return builder.commit()


## A leaf-cluster cutout mask: overlapping elliptical leaves on a transparent
## card. Leaves nearer the base are darkened, a baked stand-in for the ambient
## occlusion a real canopy has and the main reason the card reads as a volume
## rather than as a decal.
static func leaf_texture(rng_seed: int, leaves: int) -> ImageTexture:
	var img := Image.create_empty(TEX_SIZE, TEX_SIZE, true, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	# Ash-bleached scrub, NOT dark green. The first render of this pass had the
	# leaves far too dark: against pale ash ground a field of props read as black
	# specks on white paper. Desolate scrub sits close to the ground in value,
	# separated by hue and texture rather than by a huge tonal gap.
	var deep := Color(0.34, 0.32, 0.25)
	var pale := Color(0.68, 0.64, 0.49)
	for _i in maxi(leaves, 1):
		var cx := rng.randf_range(0.16, 0.84)
		var cy := rng.randf_range(0.08, 0.88)
		# Small and many, so the card reads as fine scrub. Large ellipses made it
		# look like a succulent.
		var ra := rng.randf_range(0.040, 0.078)
		var rb := rng.randf_range(0.015, 0.031)
		var angle := rng.randf_range(0.0, PI)
		# cy is 0 at the tip and 1 at the base, so this brightens upward. The
		# floor keeps even the shaded interior off black.
		var lit := clampf(0.38 + (1.0 - cy) * 0.62, 0.0, 1.0) * rng.randf_range(0.78, 1.0)
		_stamp_ellipse(img, cx, cy, ra, rb, angle, deep.lerp(pale, lit))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## A tuft of tapered blades rising from the base of the card, each leaning and
## thinning toward its tip. Same base-darkening as the leaf mask.
static func blade_texture(rng_seed: int, blades: int) -> ImageTexture:
	var img := Image.create_empty(TEX_SIZE, TEX_SIZE, true, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	# Same value correction as the leaf mask: dead grass is straw, not charcoal.
	var deep := Color(0.40, 0.36, 0.25)
	var pale := Color(0.76, 0.70, 0.48)
	for _i in maxi(blades, 1):
		var root := rng.randf_range(0.14, 0.86)
		var lean := rng.randf_range(-0.20, 0.20)
		var tip_v := rng.randf_range(0.10, 0.52)
		var half_w := rng.randf_range(0.010, 0.026)
		var bright := rng.randf_range(0.55, 1.0)
		_stamp_blade(img, root, lean, tip_v, half_w, deep, pale, bright)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## An opaque mottled stone/bone albedo. Two octaves of noise: a coarse one for
## patchy weathering, a fine one for grain — the difference between a surface
## and a colour.
static func stone_texture(rng_seed: int, dark: Color, light: Color, frequency: float) -> ImageTexture:
	var img := Image.create_empty(TEX_SIZE, TEX_SIZE, true, Image.FORMAT_RGBA8)
	var coarse := FastNoiseLite.new()
	coarse.seed = rng_seed
	coarse.noise_type = FastNoiseLite.TYPE_SIMPLEX
	coarse.frequency = frequency / float(TEX_SIZE)
	var fine := FastNoiseLite.new()
	fine.seed = rng_seed + 1
	fine.noise_type = FastNoiseLite.TYPE_SIMPLEX
	fine.frequency = (frequency * 6.0) / float(TEX_SIZE)
	for y in TEX_SIZE:
		for x in TEX_SIZE:
			var n := coarse.get_noise_2d(float(x), float(y)) * 0.72
			n += fine.get_noise_2d(float(x), float(y)) * 0.28
			img.set_pixel(x, y, dark.lerp(light, clampf(n * 0.5 + 0.5, 0.0, 1.0)))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## Paints one rotated ellipse into `img`, in UV space. Alpha feathers over the
## outer rim so a mipmapped cutout does not crawl with aliasing at distance; the
## shader scissors at 0.5, so the feather never shows as a soft edge up close.
static func _stamp_ellipse(img: Image, cx: float, cy: float, ra: float, rb: float,
		angle: float, col: Color) -> void:
	var reach := maxf(ra, rb)
	var x0 := maxi(int((cx - reach) * TEX_SIZE) - 1, 0)
	var x1 := mini(int((cx + reach) * TEX_SIZE) + 1, TEX_SIZE - 1)
	var y0 := maxi(int((cy - reach) * TEX_SIZE) - 1, 0)
	var y1 := mini(int((cy + reach) * TEX_SIZE) + 1, TEX_SIZE - 1)
	var ca := cos(angle)
	var sa := sin(angle)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var dx := (float(x) + 0.5) / float(TEX_SIZE) - cx
			var dy := (float(y) + 0.5) / float(TEX_SIZE) - cy
			var u := (dx * ca + dy * sa) / ra
			var v := (-dx * sa + dy * ca) / rb
			var d := sqrt(u * u + v * v)
			if d > 1.0:
				continue
			var alpha := 1.0 - smoothstep(0.82, 1.0, d)
			# Leaves overlap; keep whichever is more opaque so a later leaf can
			# never punch a transparent hole through an earlier one.
			if img.get_pixel(x, y).a >= alpha:
				continue
			img.set_pixel(x, y, Color(col.r, col.g, col.b, alpha))


## Paints one tapered blade rising from the base (v = 1) to `tip_v`, leaning by
## `lean` and thinning to nothing at the tip.
static func _stamp_blade(img: Image, root: float, lean: float, tip_v: float,
		half_w: float, deep: Color, pale: Color, bright: float) -> void:
	var y_start := maxi(int(tip_v * TEX_SIZE), 0)
	var span := maxf(1.0 - tip_v, 0.001)
	for y in range(y_start, TEX_SIZE):
		var v := (float(y) + 0.5) / float(TEX_SIZE)
		# 0 at the base, 1 at the tip.
		var f := clampf((1.0 - v) / span, 0.0, 1.0)
		var cx := root + lean * f * f
		var hw := half_w * (1.0 - f * 0.92)
		var col := deep.lerp(pale, f * bright)
		var x0 := maxi(int((cx - hw) * TEX_SIZE), 0)
		var x1 := mini(int((cx + hw) * TEX_SIZE), TEX_SIZE - 1)
		for x in range(x0, x1 + 1):
			img.set_pixel(x, y, Color(col.r, col.g, col.b, 1.0))


## Accumulates flat-shaded triangles for the debris kinds.
##
## Normals are derived per triangle and then forced to point AWAY from the
## piece centre, rather than relying on vertex winding order. That is
## deliberate: this repo has already lost time to inverted winding (the terrain
## was briefly backface-only), and an outward-by-construction normal cannot
## reproduce it.
class MeshBuilder extends RefCounted:
	## The six faces of a cube as indices into the 8 corners, which are built in
	## x-major, then y, then z order (so index = x*4 + y*2 + z).
	const FACES: Array = [
		[4, 5, 7, 6], [0, 2, 3, 1], [2, 6, 7, 3],
		[0, 1, 5, 4], [1, 3, 7, 5], [0, 4, 6, 2],
	]

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()

	## One box with every corner independently displaced by up to `jitter` of the
	## box size — an angular chunk rather than a crate.
	func push_chunk(centre: Vector3, size: Vector3, basis: Basis, jitter: float,
			rng: RandomNumberGenerator) -> void:
		var corners: Array[Vector3] = []
		for xi in 2:
			for yi in 2:
				for zi in 2:
					var local := Vector3(
						(float(xi) - 0.5) * size.x,
						(float(yi) - 0.5) * size.y,
						(float(zi) - 0.5) * size.z)
					local += Vector3(
						rng.randf_range(-1.0, 1.0) * size.x,
						rng.randf_range(-1.0, 1.0) * size.y,
						rng.randf_range(-1.0, 1.0) * size.z) * jitter
					corners.append(centre + basis * local)
		for face: Array in FACES:
			var a: Vector3 = corners[int(face[0])]
			var b: Vector3 = corners[int(face[1])]
			var c: Vector3 = corners[int(face[2])]
			var d: Vector3 = corners[int(face[3])]
			_push_tri(a, b, c, centre)
			_push_tri(a, c, d, centre)

	func _push_tri(a: Vector3, b: Vector3, c: Vector3, centre: Vector3) -> void:
		var n := (b - a).cross(c - a)
		if n.length_squared() <= 0.0:
			return
		n = n.normalized()
		if n.dot((a + b + c) / 3.0 - centre) < 0.0:
			n = -n
		verts.push_back(a)
		verts.push_back(b)
		verts.push_back(c)
		for _i in 3:
			normals.push_back(n)
		# Planar UVs are enough: the debris texture is isotropic mottling, and
		# these kinds do not sway, so nothing keys on UV orientation.
		uvs.push_back(Vector2(0.0, 0.0))
		uvs.push_back(Vector2(1.0, 0.0))
		uvs.push_back(Vector2(1.0, 1.0))

	func commit() -> ArrayMesh:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		return mesh
