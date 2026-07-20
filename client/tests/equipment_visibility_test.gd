extends Node
## Regression guard for #250: an equipped garment must actually CONTRIBUTE to
## the rendered frame.
##
## #250 was filed as "the ragged shirt does not render". It does — but the
## suite could not have told the difference, because every equipment assertion
## we had stops at "the mesh node exists, carries the kit shapes and takes the
## recipe's weights". A garment can satisfy all of that and still be invisible,
## in three independent ways:
##
##   1. GEOMETRY — it sits inside the body surface, so the skin draws over it.
##   2. COLOUR   — its albedo matches the skin it covers, so it reads as bare.
##   3. DRAW     — it is hidden, or its material resolves to zero alpha.
##
## All three are measured on the CPU, so this runs on CI's software renderer
## where a real frame capture cannot (#232). It is a FLOOR against "contributes
## nothing", not an art-quality gate: the taste call on how a garment should
## read is #1's.
##
## Geometry is measured on the vertices the renderer actually draws — morphed
## AND skinned through the skeleton's current global poses. CharacterFactory
## edits bone rests (arms lowered ~62 deg, contrapposto), so bind-pose
## coordinates are NOT what ends up on screen, and a garment can be clear of
## the body at bind pose while buried once the arms come down.
##
## Run: godot --headless --path client res://tests/equipment_visibility_test.tscn

const WANDERER := "res://recipes/wanderer.json"
const SKINS_DIR := "res://assets/characters/humanoid_kit/skins/"
## Spatial-hash cell for the nearest-body-vertex query. Comfortably larger than
## the clearances measured, so a widening neighbourhood search is complete.
const CELL := 0.04
## A garment vertex counts as CONTRIBUTING when it sits at least this far
## outside the body surface, measured along the body's own surface normal.
## Below a tenth of a millimetre the two surfaces are coincident and the
## renderer picks a winner by depth-fighting, not by intent.
const CONTRIBUTING_MM := 0.1
## Floor on the fraction of a garment's surface that must clear the body.
## Measured on the shipped kit in the DRAWN pose (2026-07-20): shirt_ragged
## 96.2%, pants_wool 98.6%, shoes_cloth 84.6%. The controls below score
## 0.00-4.11%, so the floor sits in a wide empty band between "clearly drawn"
## and "provably buried" rather than being tuned to either.
const MIN_CONTRIBUTING := 0.35
## Largest single-channel albedo difference from the skin region the garment
## actually covers. A luma-only comparison is blind to hue — recolouring a
## whole surface can leave luma untouched — so this is deliberately
## per-channel.
const MIN_CHROMA := 0.12
## A garment drawn at less than this alpha contributes no pixels worth the name.
const MIN_ALPHA := 0.2

var _failed := false


func _fail(msg: String) -> void:
	_failed = true
	printerr("FAIL: " + msg)


## Blend shapes applied, in the mesh's own space.
func _mixed(mi: MeshInstance3D) -> PackedVector3Array:
	var mesh := mi.mesh
	var base: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var mixed := PackedVector3Array(base)
	var blends := mesh.surface_get_blend_shape_arrays(0)
	var normalized: bool = mesh is ArrayMesh \
		and (mesh as ArrayMesh).blend_shape_mode == Mesh.BLEND_SHAPE_MODE_NORMALIZED
	for si in mesh.get_blend_shape_count():
		var w := mi.get_blend_shape_value(si)
		if is_zero_approx(w):
			continue
		var targets: PackedVector3Array = blends[si][Mesh.ARRAY_VERTEX]
		for v in mixed.size():
			var delta := targets[v] - base[v] if normalized else targets[v]
			mixed[v] += delta * w
	return mixed


## Per-bind deform matrices: global pose composed with the ORIGINAL inverse
## bind. Never regenerate the binds — that would cancel the rest surgery.
func _deforms(skel: Skeleton3D, mi: MeshInstance3D) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	var skin := mi.skin
	if skin == null:
		return out
	for b in skin.get_bind_count():
		var bone := skin.get_bind_bone(b)
		if bone < 0:
			bone = skel.find_bone(skin.get_bind_name(b))
		out.append(skel.get_bone_global_pose(bone) * skin.get_bind_pose(b))
	return out


## THE geometry the renderer draws: blend shapes applied, then linear-blend
## skinned through the skeleton's current global poses. Returns positions and
## the matching surface normals (skinned by the same basis).
func drawn(skel: Skeleton3D, mi: MeshInstance3D) -> Array:
	var mixed := _mixed(mi)
	var arrays := mi.mesh.surface_get_arrays(0)
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var deform := _deforms(skel, mi)
	if deform.is_empty() or bones.is_empty() or weights.is_empty():
		return [mixed, normals]
	var influences := bones.size() / mixed.size()
	var out_pos := PackedVector3Array()
	var out_nrm := PackedVector3Array()
	for v in mixed.size():
		var p := Vector3.ZERO
		var n := Vector3.ZERO
		for k in influences:
			var w := weights[v * influences + k]
			if w <= 0.0:
				continue
			var m := deform[bones[v * influences + k]]
			p += m * mixed[v] * w
			if v < normals.size():
				n += (m.basis * normals[v]) * w
		out_pos.append(p)
		out_nrm.append(n.normalized() if n.length() > 1e-6 else Vector3.UP)
	return [out_pos, out_nrm]


func _cell_of(p: Vector3) -> Vector3i:
	return Vector3i(int(floor(p.x / CELL)), int(floor(p.y / CELL)), int(floor(p.z / CELL)))


func _hash(verts: PackedVector3Array) -> Dictionary:
	var grid := {}
	for i in verts.size():
		var key := _cell_of(verts[i])
		if not grid.has(key):
			grid[key] = PackedInt32Array()
		grid[key].append(i)
	return grid


func _nearest(grid: Dictionary, verts: PackedVector3Array, p: Vector3) -> int:
	var centre := _cell_of(p)
	for r in range(1, 6):
		var best := -1
		var best_d := INF
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				for dz in range(-r, r + 1):
					var key := centre + Vector3i(dx, dy, dz)
					if not grid.has(key):
						continue
					for i: int in grid[key]:
						var d := verts[i].distance_squared_to(p)
						if d < best_d:
							best_d = d
							best = i
		if best >= 0:
			return best
	return -1


## Closest point to `p` on triangle (a,b,c) — Ericson, Real-Time Collision
## Detection, via barycentric region tests. Needed because point-to-nearest-
## VERTEX is NOT point-to-surface: on a coincident surface with different
## tessellation it reports up to 27% of points as clear of the body (measured
## here before this was fixed), which is the same order as the floor itself.
func closest_on_triangle(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab := b - a
	var ac := c - a
	var ap := p - a
	var d1 := ab.dot(ap)
	var d2 := ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return a
	var bp := p - b
	var d3 := ab.dot(bp)
	var d4 := ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return b
	var vc := d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		return a + ab * (d1 / (d1 - d3))
	var cp := p - c
	var d5 := ab.dot(cp)
	var d6 := ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return c
	var vb := d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		return a + ac * (d2 / (d2 - d6))
	var va := d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	var denom := 1.0 / (va + vb + vc)
	return a + ab * (vb * denom) + ac * (vc * denom)


## THE MEASUREMENT, isolated so the controls below can feed it ablated inputs:
## what fraction of this garment's surface sits outside the body, and can
## therefore be drawn at all?
##
## Distance is measured to the nearest body TRIANGLE (found via the nearest
## body vertex, then its incident faces) and signed along that triangle's
## normal — not to the nearest vertex, and not along a radial axis. Radial
## would be meaningless on limbs and feet; vertex-only leaves a tessellation
## artifact large enough to swamp the floor.
func contributing_fraction(garment: PackedVector3Array, surface: Dictionary) -> float:
	var body: PackedVector3Array = surface["verts"]
	var normals: PackedVector3Array = surface["normals"]
	var grid: Dictionary = surface["grid"]
	var incident: Dictionary = surface["incident"]
	var idx: PackedInt32Array = surface["index"]
	var outside := 0
	var total := 0
	for gi in garment.size():
		var gp := garment[gi]
		var bi := _nearest(grid, body, gp)
		if bi < 0 or not incident.has(bi) or bi >= normals.size():
			continue
		var best := INF
		var signed := 0.0
		for t: int in incident[bi]:
			var q := closest_on_triangle(gp, body[idx[t * 3]], body[idx[t * 3 + 1]],
				body[idx[t * 3 + 2]])
			var d := gp.distance_to(q)
			if d < best:
				best = d
				# Signed against the SHADING normal, not the geometric face
				# normal: Godot's fronts are clockwise, so (b-a)x(c-a) points
				# inward on this kit and would invert every verdict.
				signed = (gp - q).dot(normals[bi])
		if best == INF:
			continue
		if signed > CONTRIBUTING_MM * 0.001:
			outside += 1
		total += 1
	return 0.0 if total == 0 else float(outside) / float(total)


## Body surface bundle: vertices, index buffer, spatial hash, and vertex ->
## incident triangle map, so a nearest-vertex hit can be refined to a
## nearest-face distance.
func build_surface(verts: PackedVector3Array, normals: PackedVector3Array,
		idx: PackedInt32Array) -> Dictionary:
	var incident := {}
	for t in range(0, idx.size() / 3):
		for k in 3:
			var v := idx[t * 3 + k]
			if not incident.has(v):
				incident[v] = PackedInt32Array()
			incident[v].append(t)
	return {
		"verts": verts, "normals": normals, "index": idx,
		"grid": _hash(verts), "incident": incident,
	}


## Largest single-channel separation between a garment albedo and the skin.
func chroma_separation(garment: Color, skin: Color) -> float:
	return maxf(maxf(absf(garment.r - skin.r), absf(garment.g - skin.g)),
		absf(garment.b - skin.b))


## The mean colour of the skin region THIS piece covers, read through the body
## UVs of the vertices its equip_hide_* shape moves. Comparing against the mean
## of the whole atlas would fold in unrelated body regions, and a garment that
## matches the torso it covers while differing from the atlas average would
## slip through reading as bare.
func covered_skin_colour(body_mesh: MeshInstance3D, hide_name: String, img: Image) -> Color:
	var idx := body_mesh.find_blend_shape_by_name(hide_name)
	if idx < 0:
		return Color(0, 0, 0, 0)
	var mesh := body_mesh.mesh
	var arrays := mesh.surface_get_arrays(0)
	var base: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var targets: PackedVector3Array = mesh.surface_get_blend_shape_arrays(0)[idx][Mesh.ARRAY_VERTEX]
	var normalized: bool = mesh is ArrayMesh \
		and (mesh as ArrayMesh).blend_shape_mode == Mesh.BLEND_SHAPE_MODE_NORMALIZED
	var covered := PackedInt32Array()
	for v in base.size():
		var d := (targets[v] - base[v]) if normalized else targets[v]
		if d.length() > 1e-6:
			covered.append(v)
	return _mean_texels(body_mesh, covered, img)


## The same question for a piece with NO equip_hide_* shape (pants_wool has
## none): which body vertices does this garment sit over? Answered
## geometrically, so the colour floor is never silently skipped — a piece whose
## colour is simply not checked is exactly the vacuum #250 exposed.
func covered_by_proximity(body_mesh: MeshInstance3D, body: PackedVector3Array,
		garment: PackedVector3Array, img: Image) -> Color:
	var grid := _hash(garment)
	var covered := PackedInt32Array()
	for v in body.size():
		var gi := _nearest(grid, garment, body[v])
		if gi >= 0 and body[v].distance_to(garment[gi]) < 0.03:
			covered.append(v)
	return _mean_texels(body_mesh, covered, img)


## Mean skin colour over a set of body vertices, read through their UVs.
func _mean_texels(body_mesh: MeshInstance3D, verts: PackedInt32Array, img: Image) -> Color:
	var arrays := body_mesh.mesh.surface_get_arrays(0)
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var base: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if uvs.size() < base.size():
		return Color(0, 0, 0, 0)
	var acc := Vector3.ZERO
	var n := 0
	for v: int in verts:
		var uv := uvs[v]
		var x: int = clampi(int(uv.x * img.get_width()), 0, img.get_width() - 1)
		var y: int = clampi(int(uv.y * img.get_height()), 0, img.get_height() - 1)
		var c := img.get_pixel(x, y)
		if c.a < 0.5:
			continue
		acc += Vector3(c.r, c.g, c.b)
		n += 1
	if n == 0:
		return Color(0, 0, 0, 0)
	return Color(acc.x / n, acc.y / n, acc.z / n, 1.0)


## What the piece is actually drawn at: hidden, or a material/texture that
## resolves to (near) zero alpha, contributes no pixels while keeping perfectly
## respectable RGB.
func effective_alpha(mi: MeshInstance3D) -> float:
	if not mi.visible:
		return 0.0
	var material := mi.get_active_material(0) as StandardMaterial3D
	if material == null:
		return 0.0
	var alpha := material.albedo_color.a
	var tex := material.albedo_texture
	if tex != null:
		var img := tex.get_image()
		if img != null:
			if img.is_compressed():
				img.decompress()
			var peak := 0.0
			for y in range(0, img.get_height(), 8):
				for x in range(0, img.get_width(), 8):
					peak = maxf(peak, img.get_pixel(x, y).a)
			alpha *= peak
	return alpha


func _skin_image(path: String) -> Image:
	var tex: Texture2D = load(path)
	if tex == null:
		return null
	var img := tex.get_image()
	if img != null and img.is_compressed():
		img.decompress()
	return img


func _ready() -> void:
	var recipe: Dictionary = CharacterFactory.load_recipe(WANDERER)
	if recipe == null or not recipe.has("equipment"):
		_fail("the wanderer preset is unreadable or lost its equipment")
		_done()
		return
	var instance := CharacterFactory.build(recipe)
	if instance == null:
		_fail("the wanderer preset no longer builds")
		_done()
		return
	var skeleton := CharacterFactory.find_skeleton(instance)
	var body_mesh := CharacterFactory.find_skinned_mesh(skeleton)
	if body_mesh == null:
		_fail("no body mesh on the built wanderer")
		_done()
		return
	var body_drawn := drawn(skeleton, body_mesh)
	var body: PackedVector3Array = body_drawn[0]
	var body_normals: PackedVector3Array = body_drawn[1]
	var body_index: PackedInt32Array = body_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	var surface := build_surface(body, body_normals, body_index)

	var skins: Dictionary = CharacterFactory.skins_registry()["skins"]
	var skin_name := String(recipe.get("skin", ""))
	if skin_name not in skins:
		_fail("the wanderer's skin '%s' is not in the skins registry" % skin_name)
		_done()
		return
	var skin_img := _skin_image(SKINS_DIR + String(skins[skin_name]["texture"]))
	if skin_img == null:
		_fail("skin texture for '%s' is unreadable — the colour floor cannot be measured" % skin_name)
		_done()
		return

	var registry: Dictionary = CharacterFactory.equipment_registry()
	var checked := 0
	var worn := CharacterFactory.pieces_to_wear(recipe["equipment"])
	for piece_name in worn:
		var mi := skeleton.get_node_or_null(
			NodePath(CharacterFactory.EQUIP_PREFIX + piece_name)) as MeshInstance3D
		if mi == null:
			_fail("worn piece '%s' built no mesh on the skeleton" % piece_name)
			continue
		var garment: PackedVector3Array = drawn(skeleton, mi)[0]
		if garment.is_empty():
			_fail("worn piece '%s' has no vertices" % piece_name)
			continue

		# 1. GEOMETRY.
		var fraction := contributing_fraction(garment, surface)
		if fraction < MIN_CONTRIBUTING:
			_fail(("piece '%s' CONTRIBUTES NOTHING: only %.1f%% of its drawn surface sits "
				+ "outside the body (floor %.0f%%) — it is buried in the skin and cannot render")
				% [piece_name, fraction * 100.0, MIN_CONTRIBUTING * 100.0])

		# 2. DRAW.
		var alpha := effective_alpha(mi)
		if alpha < MIN_ALPHA:
			_fail(("piece '%s' DRAWS NOTHING: effective alpha %.3f (floor %.2f) — hidden, or "
				+ "its material resolves to transparent") % [piece_name, alpha, MIN_ALPHA])

		# 3. COLOUR, against the skin region this piece actually covers.
		var material := mi.get_active_material(0) as StandardMaterial3D
		if material == null:
			_fail("piece '%s' has no StandardMaterial3D — nothing defines its colour" % piece_name)
			continue
		var piece: Dictionary = registry["pieces"][piece_name]
		var covered := Color(0, 0, 0, 0)
		var basis_used := "hide_shape"
		if piece.has("hide_shape"):
			covered = covered_skin_colour(body_mesh, String(piece["hide_shape"]), skin_img)
		if covered.a == 0.0:
			basis_used = "proximity"
			covered = covered_by_proximity(body_mesh, body, garment, skin_img)
		if covered.a == 0.0:
			_fail("piece '%s': the skin region it covers resolved no texels — the colour "
				% piece_name + "floor cannot be measured, so it is NOT silently skipped")
			checked += 1
			continue
		var separation := chroma_separation(material.albedo_color, covered)
		if separation < MIN_CHROMA:
			_fail(("piece '%s' READS AS BARE: its albedo is within %.3f of the skin "
				+ "region it covers on every channel (floor %.3f)")
				% [piece_name, separation, MIN_CHROMA])
		print("  %-13s contributing=%5.1f%%  alpha=%.2f  chroma_vs_covered_skin=%.3f (%s)" \
			% [piece_name, fraction * 100.0, alpha, separation, basis_used])
		checked += 1

	if checked == 0:
		_fail("NON-VACUITY: the wanderer wore no garments, so nothing was measured")

	# CONTROL A (geometry): the body's own surface, offered as a garment, is
	# coincident with itself — the definition of contributing nothing.
	var coincident := contributing_fraction(body, surface)
	_expect_below("coincident geometry", coincident, MIN_CONTRIBUTING)

	# CONTROL B (geometry, the tessellation case): triangle midpoints lie ON the
	# body surface but are NOT body vertices, so this is a coincident surface
	# with DIFFERENT tessellation — exactly the case where nearest-vertex is not
	# nearest-surface. It bounds that approximation error with a measurement
	# instead of an assumption.
	var midpoints := PackedVector3Array()
	for t in range(0, body_index.size() / 3):
		var a := body[body_index[t * 3]]
		var b := body[body_index[t * 3 + 1]]
		var c := body[body_index[t * 3 + 2]]
		midpoints.append((a + b + c) / 3.0)
	var retess := contributing_fraction(midpoints, surface)
	_expect_below("retessellated coincident", retess, MIN_CONTRIBUTING)

	# CONTROL C (geometry): a real garment pulled inside the skin. Ablates ONLY
	# the clearance — vertex count, morphs and skinning stay intact.
	if not worn.is_empty():
		var sample := skeleton.get_node_or_null(
			NodePath(CharacterFactory.EQUIP_PREFIX + worn[0])) as MeshInstance3D
		if sample != null:
			# Seat a real garment just UNDER the body surface — the "buried in
			# the skin" failure mode. Any depth at all is invisible, so the
			# inset is deliberately small.
			#
			# 🔑 A DEEP inset is not a stronger control, it is a BROKEN one: at
			# 50mm the displaced points TUNNEL THROUGH thin geometry (fingers,
			# forearms and ears are well under 100mm thick) and emerge outside
			# the far surface, which the guard then correctly reports as
			# contributing — measured 36.2%, i.e. the control failed for a
			# reason that had nothing to do with the check it ablates.
			var sunk: PackedVector3Array = drawn(skeleton, sample)[0]
			for i in sunk.size():
				var bi := _nearest(surface["grid"], body, sunk[i])
				if bi >= 0:
					sunk[i] = body[bi] - body_normals[bi] * 0.005
			_expect_below("sunk 5mm", contributing_fraction(sunk, surface), MIN_CONTRIBUTING)

	# CONTROL D (colour): a garment painted the colour of the skin it covers.
	_expect_below("skin-coloured", chroma_separation(Color(0.5, 0.4, 0.3), Color(0.5, 0.4, 0.3)),
		MIN_CHROMA)

	# CONTROL E (colour): a garment differing from skin only in HUE, at matched
	# luma, must still PASS. This is what pins the metric as per-channel rather
	# than luma — the check that would hand every recolour a confident zero.
	var skin_ref := Color(0.83, 0.55, 0.38)
	var hue_swapped := Color(skin_ref.b, skin_ref.r, skin_ref.g)
	var hue_sep := chroma_separation(hue_swapped, skin_ref)
	if hue_sep < MIN_CHROMA:
		_fail(("CONTROL FAILED: a hue-swapped garment separated by only %.3f — the colour "
			+ "metric is blind to hue") % hue_sep)
	else:
		print("  control(hue-swapped)          chroma=%.3f — correctly ABOVE the floor" % hue_sep)

	instance.free()
	_done()


func _expect_below(label: String, value: float, floor_value: float) -> void:
	if value >= floor_value:
		_fail(("CONTROL FAILED: '%s' scored %.4f, at or above the %.4f floor — the check it "
			+ "ablates is not load-bearing") % [label, value, floor_value])
	else:
		print("  control(%-24s) %.4f — correctly below the %.2f floor" % [label, value, floor_value])


func _done() -> void:
	if _failed:
		printerr("TEST FAIL")
	else:
		print("TEST PASS")
	get_tree().quit()
