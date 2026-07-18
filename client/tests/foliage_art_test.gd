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

	# 6. SEAMLESS DEBRIS UVS — vertices sharing a position within a chunk must
	# share a UV. Emitting a fixed UV triplet per triangle (the first version of
	# this code) makes the two triangles of one face disagree along their shared
	# diagonal, so the texture restarts and the chunk shows triangular patches.
	for kind: int in [FoliageGen.Kind.BONE_PILE, FoliageGen.Kind.RUBBLE]:
		var clashes := _uv_discontinuities(FoliageArt.mesh_for(kind))
		if clashes > 0:
			_fail("kind %d has %d vertex positions carrying more than one UV — the debris texture would seam along shared edges" % [kind, clashes])
			return

	# 7. BLED CUTOUT MASKS — the transparent margin around the artwork must carry
	# the artwork's colour, not black. Mipmapping averages RGB across the alpha
	# edge, so an unbled mask fringes black on distant props even though its
	# silhouette is correct.
	for label: String in masks:
		var fringe := _darkest_transparent_neighbour(masks[label] as ImageTexture)
		if fringe < 0.0:
			_fail("the %s mask has no transparent pixel bordering the artwork — this check is vacuous" % label)
			return
		if fringe < 0.02:
			_fail("the %s mask borders the artwork with near-black transparent pixels (luma %.3f) — mipmapping would fringe distant props black" % [label, fringe])
			return
		# The bleed must reach BEYOND the first ring. Lower mip levels average
		# over a wide footprint, so a one-pixel dilation still leaves them
		# pulling in untouched black. A version of the bleed that read its
		# neighbours' ALPHA could never propagate past pass one — bled pixels
		# keep alpha 0 — and the border check above passed straight through it.
		var depth := _bleed_depth(masks[label] as ImageTexture)
		if depth < 3:
			_fail("the %s mask's colour bleed reaches only %d pixel(s) past the silhouette — deeper mip levels would still average against black" % [label, depth])
			return

	# 8. WIRED — every kind resolves to the right shader, and only vegetation moves.
	var swaying := 0
	for kind: int in kinds:
		var mat := FoliageArt.material_for(kind)
		if mat.shader == null:
			_fail("kind %d has no shader" % kind)
			return
		if mat.get_shader_parameter("albedo_tex") == null:
			_fail("kind %d has no albedo texture — it would render untextured" % kind)
			return
		if FoliageArt.is_debris(kind):
			if mat.shader != FoliageArt.DEBRIS_SHADER:
				_fail("kind %d is solid debris but is not on the opaque debris shader" % kind)
				return
			continue
		if mat.shader != FoliageArt.SHADER:
			_fail("kind %d is vegetation but is not on the cutout foliage shader" % kind)
			return
		if float(mat.get_shader_parameter("wind_strength")) <= 0.0:
			_fail("kind %d is vegetation but does not sway" % kind)
			return
		swaying += 1
	if swaying == 0:
		_fail("nothing in the world sways — the wind assertion above is vacuous")
		return

	print("TEST PASS — foliage art (%d kinds): deterministic, origin-centred, genuine cutout silhouettes, tonally varied stone, outward-facing debris normals, seam-free debris UVs, colour-bled cutout margins, %d swaying kinds on the cutout shader and the rest opaque" %
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


## Counts vertices that sit at the same position on what is physically the same
## face, yet carry different UVs. That is the diagonal seam: the two triangles
## of one quad disagreeing about the texture at the vertices they share.
##
## "Same face" is judged by NEAR-coplanarity, and the threshold was calibrated
## against the actual defect rather than guessed:
##   * keying on position ALONE is wrong in one direction — a box map is
##     SUPPOSED to give a shared corner different UVs on its different faces
##     (that version flagged 110 correct corners as defects);
##   * keying on an EXACT normal match is wrong in the other — corner jitter
##     leaves the two triangles of a quad slightly non-coplanar, so that version
##     caught only 1 seam of roughly 30;
##   * at 30° it reported 6 residual pairs on correct code, which turned out to
##     be genuinely DIFFERENT faces 11-30° apart, where a texture change across
##     the edge is expected and invisible in isotropic mottling.
## At ~11° the guard is clean on correct code and still reports 19 seams when
## the per-triangle UV triplet is restored.
const COPLANAR_COS := 0.98  # ~11 degrees

func _uv_discontinuities(mesh: Mesh) -> int:
	var by_position := {}
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		for i in verts.size():
			var v := verts[i]
			var key := "%d,%d,%d" % [
				roundi(v.x * 1000.0), roundi(v.y * 1000.0), roundi(v.z * 1000.0)]
			if not by_position.has(key):
				by_position[key] = []
			(by_position[key] as Array).append([normals[i], uvs[i]])

	var clashes := 0
	for key: String in by_position:
		var entries: Array = by_position[key]
		for i in entries.size():
			for j in range(i + 1, entries.size()):
				var na: Vector3 = entries[i][0]
				var nb: Vector3 = entries[j][0]
				if na.dot(nb) < COPLANAR_COS:
					continue
				var ua: Vector2 = entries[i][1]
				var ub: Vector2 = entries[j][1]
				if ua.distance_to(ub) > 0.001:
					clashes += 1
	return clashes


## The dimmest luminance among fully-transparent pixels that touch an opaque
## one — i.e. the colour mipmapping will blend across the silhouette edge.
## Returns -1.0 when no such pixel exists, so the caller can reject a vacuous
## pass rather than read "no dark fringe" from "nothing to check".
func _darkest_transparent_neighbour(tex: ImageTexture) -> float:
	var img := tex.get_image()
	var worst := -1.0
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.0:
				continue
			var touches := false
			for dy: int in [-1, 0, 1]:
				for dx: int in [-1, 0, 1]:
					var nx := x + dx
					var ny := y + dy
					if nx < 0 or ny < 0 or nx >= img.get_width() or ny >= img.get_height():
						continue
					if img.get_pixel(nx, ny).a > 0.0:
						touches = true
			if not touches:
				continue
			var c := img.get_pixel(x, y)
			var luma := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			if worst < 0.0 or luma < worst:
				worst = luma
	return worst


## How many pixel rings of transparent margin carry bled colour, measured as a
## breadth-first distance from the opaque silhouette. A transparent pixel counts
## as reached when its RGB is not black.
func _bleed_depth(tex: ImageTexture) -> int:
	var img := tex.get_image()
	var w := img.get_width()
	var h := img.get_height()
	var dist := []
	dist.resize(w * h)
	var frontier: Array[Vector2i] = []
	for y in h:
		for x in w:
			if img.get_pixel(x, y).a > 0.0:
				dist[y * w + x] = 0
				frontier.append(Vector2i(x, y))
			else:
				dist[y * w + x] = -1

	var deepest := 0
	while not frontier.is_empty():
		var next: Array[Vector2i] = []
		for p: Vector2i in frontier:
			for dy: int in [-1, 0, 1]:
				for dx: int in [-1, 0, 1]:
					var nx := p.x + dx
					var ny := p.y + dy
					if nx < 0 or ny < 0 or nx >= w or ny >= h:
						continue
					if dist[ny * w + nx] != -1:
						continue
					var c := img.get_pixel(nx, ny)
					# Untouched margin is pure transparent black; a bled pixel
					# carries the artwork's colour at alpha 0.
					if c.r <= 0.0 and c.g <= 0.0 and c.b <= 0.0:
						continue
					var d: int = dist[p.y * w + p.x] + 1
					dist[ny * w + nx] = d
					deepest = maxi(deepest, d)
					next.append(Vector2i(nx, ny))
		frontier = next
	return deepest


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
