extends Node
## Regression test for generated prop ART (issue #146, quality-bar epic #123).
##
## The neighbouring foliage tests pin PLACEMENT: `foliage_scatter_test` holds
## [FoliageGen] against synthetic params, `foliage_render_test` holds the props
## [WorldGen] actually scatters. Neither looks at what a prop is MADE of, which
## is precisely what the quality bar judges — so this file pins the contracts
## that make the art both correct and non-placeholder.
##
## What it holds:
##  1. DETERMINISM — same recipe, same mesh and same texture, every boot. The
##     art is generated at runtime from seeded RNG and noise, so a leaked
##     global-RNG call or a clock would show up as drift between two builds.
##  2. ORIGIN-CENTRED — every prop mesh straddles its own origin vertically.
##     [WorldGen] lifts each prop by a fraction of its mesh AABB height to seat
##     it on the ground; a base-anchored mesh would silently make every prop of
##     that kind hover. This is the one real coupling between art and placement.
##  3. A REAL SILHOUETTE — the vegetation masks are genuinely cut out: partly
##     transparent and partly opaque. A fully-opaque mask would render the card
##     as a solid rectangle, which is WORSE than the sphere it replaced, and
##     every other assertion here would still pass. This is the guard that stops
##     the change quietly regressing into placeholder art.
##  4. MATERIAL DEPTH — the stone albedos carry real tonal range rather than one
##     flat colour, which is the quality bar's second "tell".
##  5. OUTWARD NORMALS — debris normals point away from the piece, so a chunk
##     cannot ship inside-out. This repo has already lost time to inverted
##     winding (the terrain was briefly backface-only).
##  6. WIRED — every kind yields a mesh and a shader material, vegetation sways
##     and debris does not.

## Vertical centring tolerance, as a fraction of the mesh's own height. The
## debris kinds are jittered clusters, so their centre of mass is not exactly
## zero; anything within this band still lifts correctly.
const CENTRE_TOLERANCE := 0.30

## A mask that is opaque nearly everywhere is a solid card wearing a cutout's
## name; one that is almost entirely transparent is an invisible prop.
const ALPHA_COVER_MIN := 0.04
const ALPHA_COVER_MAX := 0.80

## Minimum spread between the darkest and lightest pixel of a generated stone
## albedo. Below this it is, for practical purposes, a flat colour.
const STONE_TONAL_RANGE_MIN := 0.10


func _ready() -> void:
	var kinds := range(FoliageGen.KIND_COUNT)

	# 1. DETERMINISM — two independent builds, with the process-global RNG
	# perturbed differently before each, must agree exactly.
	for kind: int in kinds:
		seed(0x51ed270b)
		var mesh_a := FoliageArt.mesh_for(kind)
		seed(0x2f8a13c4)
		var mesh_b := FoliageArt.mesh_for(kind)
		var fa := _mesh_fingerprint(mesh_a)
		var fb := _mesh_fingerprint(mesh_b)
		if fa != fb:
			_fail("kind %d mesh differs between builds (%s vs %s) — prop art is not deterministic" % [kind, fa, fb])
			return

	seed(0x51ed270b)
	var leaf_a := FoliageArt.leaf_texture(FoliageArt.SEED_SHRUB, 46)
	seed(0x2f8a13c4)
	var leaf_b := FoliageArt.leaf_texture(FoliageArt.SEED_SHRUB, 46)
	if _image_fingerprint(leaf_a) != _image_fingerprint(leaf_b):
		_fail("the leaf mask differs between builds — generated textures are not deterministic")
		return

	# 2. ORIGIN-CENTRED — the contract WorldGen's ground lift depends on.
	for kind: int in kinds:
		var aabb := FoliageArt.mesh_for(kind).get_aabb()
		if aabb.size.y <= 0.0:
			_fail("kind %d has no vertical extent — it cannot be lifted onto the ground" % kind)
			return
		var centre_offset := absf(aabb.position.y + aabb.size.y * 0.5)
		if centre_offset > aabb.size.y * CENTRE_TOLERANCE:
			_fail("kind %d is not centred on its origin (centre %.3f m off, height %.3f m) — WorldGen's AABB lift would make it hover or sink" %
				[kind, centre_offset, aabb.size.y])
			return

	# 3. A REAL SILHOUETTE — the vegetation masks must actually be cut out.
	var masks := {
		"leaf": FoliageArt.leaf_texture(FoliageArt.SEED_SHRUB, 46),
		"blade": FoliageArt.blade_texture(FoliageArt.SEED_GRASS, 22),
	}
	for label: String in masks:
		var cover := _opaque_fraction(masks[label] as ImageTexture)
		if cover < ALPHA_COVER_MIN:
			_fail("the %s mask is %.1f%% opaque — the prop would be almost invisible" % [label, cover * 100.0])
			return
		if cover > ALPHA_COVER_MAX:
			_fail("the %s mask is %.1f%% opaque — that is a solid card, not a cutout silhouette" % [label, cover * 100.0])
			return

	# 4. MATERIAL DEPTH — a generated stone albedo is a surface, not a colour.
	var stones := {
		"bone": FoliageArt.stone_texture(FoliageArt.SEED_BONE, Color(0.53, 0.51, 0.45), Color(0.86, 0.84, 0.76), 7.0),
		"rubble": FoliageArt.stone_texture(FoliageArt.SEED_RUBBLE, Color(0.24, 0.23, 0.22), Color(0.52, 0.50, 0.47), 5.0),
	}
	for label: String in stones:
		var spread := _tonal_range(stones[label] as ImageTexture)
		if spread < STONE_TONAL_RANGE_MIN:
			_fail("the %s albedo spans only %.3f in tone — that reads as a flat single colour" % [label, spread])
			return

	# 5. OUTWARD NORMALS — no inside-out debris.
	for kind: int in [FoliageGen.Kind.BONE_PILE, FoliageGen.Kind.RUBBLE]:
		var mesh := FoliageArt.mesh_for(kind)
		var volume := _normal_signed_volume(mesh)
		if volume <= 0.0:
			_fail("kind %d encloses a signed volume of %.5f m³ — its normals point inward, so the debris would light inside-out" % [kind, volume])
			return
		# A sanity ceiling: the pieces are a loose cluster, so the volume they
		# enclose must sit well inside their shared bounding box.
		var bounds := mesh.get_aabb().size
		var box := bounds.x * bounds.y * bounds.z
		if volume > box:
			_fail("kind %d encloses %.5f m³ inside a %.5f m³ bounding box — the normals are inconsistent" % [kind, volume, box])
			return

	# 6. WIRED — every kind resolves to a shader material, and only vegetation moves.
	var swaying := 0
	for kind: int in kinds:
		var mat := FoliageArt.material_for(kind)
		if mat.shader == null:
			_fail("kind %d has no shader" % kind)
			return
		if mat.get_shader_parameter("albedo_tex") == null:
			_fail("kind %d has no albedo texture — it would render untextured" % kind)
			return
		var wind := float(mat.get_shader_parameter("wind_strength"))
		var vegetation := kind == FoliageGen.Kind.ASH_SHRUB or kind == FoliageGen.Kind.DEAD_GRASS
		if vegetation and wind <= 0.0:
			_fail("kind %d is vegetation but does not sway" % kind)
			return
		if not vegetation and wind != 0.0:
			_fail("kind %d is debris but sways — stone should not move in the wind" % kind)
			return
		if wind > 0.0:
			swaying += 1
	if swaying == 0:
		_fail("nothing in the world sways — the wind assertion above is vacuous")
		return

	print("TEST PASS — foliage art (%d kinds): deterministic, origin-centred, genuine cutout silhouettes, tonally varied stone, outward-facing debris normals, %d swaying kinds" %
		[FoliageGen.KIND_COUNT, swaying])
	get_tree().quit(0)


## A quantised fingerprint of every vertex and normal in a mesh. Millimetre /
## 1e-4 quantised, matching the world golden's convention, so it is robust to
## platform float noise while catching any real drift.
func _mesh_fingerprint(mesh: Mesh) -> String:
	var acc := PackedInt32Array()
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for v: Vector3 in verts:
			acc.append(roundi(v.x * 1000.0))
			acc.append(roundi(v.y * 1000.0))
			acc.append(roundi(v.z * 1000.0))
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for n: Vector3 in normals:
			acc.append(roundi(n.x * 10000.0))
			acc.append(roundi(n.y * 10000.0))
			acc.append(roundi(n.z * 10000.0))
	return "%x" % hash(acc)


func _image_fingerprint(tex: ImageTexture) -> String:
	return "%x" % hash(tex.get_image().get_data())


## The fraction of pixels the shader's 0.5 alpha scissor would KEEP — i.e. the
## prop's actual silhouette area on the card.
func _opaque_fraction(tex: ImageTexture) -> float:
	var img := tex.get_image()
	var opaque := 0
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a >= 0.5:
				opaque += 1
	return float(opaque) / float(img.get_width() * img.get_height())


## The luminance spread of a texture: how far its lightest pixel is from its
## darkest. A single flat colour scores 0.
func _tonal_range(tex: ImageTexture) -> float:
	var img := tex.get_image()
	var lo := 1.0
	var hi := 0.0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			var luma := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			lo = minf(lo, luma)
			hi = maxf(hi, luma)
	return hi - lo


## The volume enclosed by a mesh, computed from its STORED normals via the
## divergence theorem: ∑ (n · centroid) · area / 3.
##
## This is the right test for a cluster of separate closed pieces. Asking
## whether each normal points away from the whole mesh's centre would be wrong —
## the inward-facing side of an outlying chunk legitimately points back toward
## it — but every closed piece contributes its own positive volume when its
## normals face outward, and a negative total is exactly what an inside-out
## mesh produces.
func _normal_signed_volume(mesh: Mesh) -> float:
	var total := 0.0
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var tris := verts.size() / 3
		for t in tris:
			var a := verts[t * 3]
			var b := verts[t * 3 + 1]
			var c := verts[t * 3 + 2]
			var area := (b - a).cross(c - a).length() * 0.5
			total += normals[t * 3].dot((a + b + c) / 3.0) * area / 3.0
	return total


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
