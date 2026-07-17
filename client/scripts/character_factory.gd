class_name CharacterFactory
## Runtime composition layer of the character system (issue #24, stages 2+3):
## builds a character from a RECIPE — a versioned, name-keyed parameter
## dictionary — on top of the baked humanoid kit, and dresses it from the
## baked equipment registry (skinned pieces on the one canonical skeleton).
##
## Recipes are the persistence format for every humanoid (players, NPCs,
## humanoid enemies), so they obey the no-resets product law:
##  - keyed by stable STRING names (blend shapes, bones, slots, pieces) —
##    never indices;
##  - forward-only: a name that ever shipped keeps working forever (the kit
##    may only ADD shapes/pieces; the golden-recipe and shipped-equipment
##    regression tests enforce it);
##  - versioned: `version` <= RECIPE_VERSION is accepted forever, a NEWER
##    version is rejected loudly (an old client must never half-apply a
##    recipe it does not fully understand).
##
## Bone edits follow the laws proven in Phase 0 stage 2 (see the test's
## pose==rest guard): rests must stay TRS-representable — only UNIFORM bone
## scales (with exact child compensation: basis x 1/g, origin / g), origin
## scaling for joint pushes, and no engine global reads between rest edits
## (Godot 4.7 desyncs its rest/pose caches).

const RECIPE_VERSION := 3
const KIT_SCENE_PATH := "res://assets/characters/humanoid_kit/humanoid_base.glb"
const EQUIPMENT_DIR := "res://assets/characters/humanoid_kit/equipment/"
const EQUIPMENT_REGISTRY_PATH := EQUIPMENT_DIR + "equipment.json"
const SKINS_DIR := "res://assets/characters/humanoid_kit/skins/"
const SKINS_REGISTRY_PATH := SKINS_DIR + "skins.json"
## Equipment mesh nodes get this name prefix so the body's skinned mesh stays
## unambiguous (find_skinned_mesh skips them).
const EQUIP_PREFIX := "Equip_"
## Blend shapes with this prefix are composition plumbing (skin tucked under a
## worn piece), never a body slider.
const HIDE_SHAPE_PREFIX := "equip_hide_"
## The standing pose: degrees the arms hang from the baked T-pose, with a
## slight elbow and wrist curl so it reads relaxed, not scarecrow (angles
## proven in Phase 0 stage 2).
const ARM_HANG_DEG := 62.0
const FOREARM_RELAX_DEG := 10.0
const HAND_RELAX_DEG := 8.0

## The recipe format, exhaustively: any other top-level field is REJECTED —
## a recipe carrying data this client cannot render must fail loudly, never
## render a half-truth (no-resets law). New fields ship with a version bump:
## `equipment` (slot -> piece name) exists from version 2, `skin` (a skins
## registry name) from version 3 — an older recipe carrying either stays
## invalid forever, exactly as the older clients ruled.
const RECIPE_FIELDS := ["version", "comment", "shapes", "bone_girth", "bone_scale", "joint_push"]
const RECIPE_FIELDS_V2 := ["equipment"]
const RECIPE_FIELDS_V3 := ["skin"]

static var _equipment_registry: Dictionary = {}
static var _skins_registry: Dictionary = {}
static var _skin_materials: Dictionary = {}
## The GUARDED bone keys per field — exactly the set the golden recipe
## exercises forever. Persisted recipes may only touch these; anything else
## would dodge the forward-compat guarantee (a future rig rename could break
## it silently). Extending this list means extending the golden recipe in the
## same change.
const GUARDED_BONE_KEYS := {
	"bone_girth": ["neck_01", "spine_03", "upperarm", "lowerarm", "thigh", "calf"],
	"bone_scale": ["head", "hand", "foot"],
	"joint_push": ["upperarm", "hand"],
}


## Builds a character instance from a recipe, or returns null after
## push_error when the recipe is invalid. The caller owns the instance.
static func build(recipe: Dictionary) -> Node3D:
	var packed: PackedScene = load(KIT_SCENE_PATH)
	if packed == null:
		push_error("CharacterFactory: kit missing: %s" % KIT_SCENE_PATH)
		return null
	var instance := packed.instantiate() as Node3D
	var skeleton := find_skeleton(instance)
	var mesh_instance := find_skinned_mesh(skeleton)
	if skeleton == null or mesh_instance == null:
		push_error("CharacterFactory: kit has no skeleton or skinned mesh")
		instance.free()
		return null

	var problem := validate(recipe, skeleton, mesh_instance)
	if problem != "":
		push_error("CharacterFactory: invalid recipe: %s" % problem)
		instance.free()
		return null

	# Bone ops first (rest edits, no engine global reads), then poses.
	for key: String in recipe.get("bone_girth", {}):
		for bone in _bones_for(skeleton, key):
			_apply_girth(skeleton, bone, recipe["bone_girth"][key])
	for key: String in recipe.get("bone_scale", {}):
		for bone in _bones_for(skeleton, key):
			_apply_uniform_subtree(skeleton, bone, recipe["bone_scale"][key])
	for key: String in recipe.get("joint_push", {}):
		for bone in _bones_for(skeleton, key):
			_scale_joint_origin(skeleton, bone, recipe["joint_push"][key])
	# Arms down from the bake's T-pose — the standing pose every body wears
	# until real animation arrives (rotation-only rest edits: TRS-safe).
	for arm in ["upperarm_l", "upperarm_r"]:
		_hang_toward_down(skeleton, skeleton.find_bone(arm), ARM_HANG_DEG)
	for forearm in ["lowerarm_l", "lowerarm_r"]:
		_hang_toward_down(skeleton, skeleton.find_bone(forearm), FOREARM_RELAX_DEG)
	for hand in ["hand_l", "hand_r"]:
		_hang_toward_down(skeleton, skeleton.find_bone(hand), HAND_RELAX_DEG)
	skeleton.reset_bone_poses()
	skeleton.force_update_all_bone_transforms()

	for shape_name: String in recipe.get("shapes", {}):
		var idx := mesh_instance.find_blend_shape_by_name(shape_name)
		mesh_instance.set_blend_shape_value(idx, recipe["shapes"][shape_name])

	for slot: String in recipe.get("equipment", {}):
		_equip_piece(skeleton, mesh_instance, String(recipe["equipment"][slot]), recipe.get("shapes", {}))

	if recipe.has("skin"):
		mesh_instance.set_surface_override_material(0, _skin_material(String(recipe["skin"])))
		instance.set_meta("skin", recipe["skin"])
	return instance


## One shared material per skin: N villagers with the same skin are one
## texture and one material, not N.
static func _skin_material(skin_name: String) -> StandardMaterial3D:
	if skin_name in _skin_materials:
		return _skin_materials[skin_name]
	var material := StandardMaterial3D.new()
	material.albedo_texture = load(SKINS_DIR + String(skins_registry()["skins"][skin_name]["texture"]))
	material.roughness = 0.75
	_skin_materials[skin_name] = material
	return material


## The baked skins registry (skins/skins.json): names are forward-only,
## exactly like blend shapes and equipment pieces.
static func skins_registry() -> Dictionary:
	if not _skins_registry.is_empty():
		return _skins_registry
	var file := FileAccess.open(SKINS_REGISTRY_PATH, FileAccess.READ)
	if file == null:
		push_error("CharacterFactory: skins registry missing: %s" % SKINS_REGISTRY_PATH)
		return { "skins": {} }
	var parsed = JSON.parse_string(file.get_as_text())
	if parsed is not Dictionary:
		push_error("CharacterFactory: skins registry is not a JSON object")
		return { "skins": {} }
	_skins_registry = parsed
	return _skins_registry


## Attaches one baked equipment piece to the kit skeleton: its skinned mesh
## (bind-by-name onto the shared bones) plus the recipe's shape weights, so
## the garment follows the body's morphs; the piece's equip_hide_* shape
## tucks the covered skin inward. Validation has already vouched for the
## piece name.
static func _equip_piece(skeleton: Skeleton3D, body_mesh: MeshInstance3D, piece_name: String, shapes: Dictionary) -> void:
	var piece: Dictionary = equipment_registry()["pieces"][piece_name]
	var packed: PackedScene = load(EQUIPMENT_DIR + String(piece["scene"]))
	if packed == null:
		push_error("CharacterFactory: equipment scene missing: %s" % piece["scene"])
		return
	var scene := packed.instantiate() as Node3D
	var piece_mesh := find_skinned_mesh(find_skeleton(scene))
	if piece_mesh == null:
		push_error("CharacterFactory: no skinned mesh in equipment scene %s" % piece["scene"])
		scene.free()
		return
	piece_mesh.get_parent().remove_child(piece_mesh)
	piece_mesh.owner = null
	piece_mesh.name = EQUIP_PREFIX + piece_name
	skeleton.add_child(piece_mesh)
	scene.free()
	for shape_name: String in shapes:
		var idx := piece_mesh.find_blend_shape_by_name(shape_name)
		if idx >= 0:
			piece_mesh.set_blend_shape_value(idx, shapes[shape_name])
	if piece.has("hide_shape"):
		var hide_idx := body_mesh.find_blend_shape_by_name(String(piece["hide_shape"]))
		if hide_idx >= 0:
			body_mesh.set_blend_shape_value(hide_idx, 1.0)


## The baked equipment registry (equipment/equipment.json): slots and pieces
## are stable forward-only names, exactly like blend shapes. Cached — the
## registry only changes with the committed kit.
static func equipment_registry() -> Dictionary:
	if not _equipment_registry.is_empty():
		return _equipment_registry
	var file := FileAccess.open(EQUIPMENT_REGISTRY_PATH, FileAccess.READ)
	if file == null:
		push_error("CharacterFactory: equipment registry missing: %s" % EQUIPMENT_REGISTRY_PATH)
		return { "slots": [], "pieces": {} }
	var parsed = JSON.parse_string(file.get_as_text())
	if parsed is not Dictionary:
		push_error("CharacterFactory: equipment registry is not a JSON object")
		return { "slots": [], "pieces": {} }
	_equipment_registry = parsed
	return _equipment_registry


## Drives one blend shape across the body AND every equipped piece that
## carries it — the character creator's live sliders go through here.
static func set_shape_weight(instance: Node3D, shape_name: String, value: float) -> void:
	var skeleton := find_skeleton(instance)
	if skeleton == null:
		return
	for child in skeleton.get_children():
		if child is not MeshInstance3D:
			continue
		var idx := (child as MeshInstance3D).find_blend_shape_by_name(shape_name)
		if idx >= 0:
			(child as MeshInstance3D).set_blend_shape_value(idx, value)


## The weapon socket on a hand bone ("hand_l"/"hand_r"): a BoneAttachment3D
## that follows the bone — weapons and tools parent under it. Created on
## first use, stable and reusable after.
static func weapon_socket(instance: Node3D, hand_bone: String) -> BoneAttachment3D:
	var skeleton := find_skeleton(instance)
	if skeleton == null or skeleton.find_bone(hand_bone) < 0:
		push_error("CharacterFactory: no bone '%s' for a weapon socket" % hand_bone)
		return null
	var socket_name := "Socket_" + hand_bone
	var existing := skeleton.get_node_or_null(NodePath(socket_name))
	if existing is BoneAttachment3D:
		return existing
	var socket := BoneAttachment3D.new()
	socket.name = socket_name
	skeleton.add_child(socket)
	socket.bone_name = hand_bone
	return socket


## Full validation against the kit: "" when the recipe is applicable, else a
## human-readable reason. Rejecting future versions outright is deliberate —
## silently skipping unknown fields would render a character that is not what
## its recipe says (a forward-compat lie).
static func validate(recipe: Dictionary, skeleton: Skeleton3D, mesh_instance: MeshInstance3D) -> String:
	var version = recipe.get("version")
	if not (version is int or (version is float and version == floorf(version))):
		return "recipe has no integer version"
	if int(version) < 1:
		return "recipe version %d is not positive" % int(version)
	if int(version) > RECIPE_VERSION:
		return "recipe version %d is newer than this client understands (%d)" % [int(version), RECIPE_VERSION]
	for field: String in recipe:
		if field in RECIPE_FIELDS:
			continue
		if field in RECIPE_FIELDS_V2 and int(version) >= 2:
			continue
		if field in RECIPE_FIELDS_V3 and int(version) >= 3:
			continue
		return "unknown recipe field '%s' — this client cannot render it, refusing a half-truth" % field
	for shape_name: String in recipe.get("shapes", {}):
		if mesh_instance.find_blend_shape_by_name(shape_name) < 0:
			return "unknown blend shape '%s' — shipped kit shapes may never be removed" % shape_name
		if shape_name.begins_with(HIDE_SHAPE_PREFIX):
			return "shape '%s' is composition plumbing, not a recipe shape" % shape_name
	for field: String in GUARDED_BONE_KEYS:
		for key: String in recipe.get(field, {}):
			if key not in (GUARDED_BONE_KEYS[field] as Array):
				return "bone key '%s' in %s is outside the guarded set — only golden-guarded keys may persist" % [key, field]
			if _bones_for(skeleton, key).is_empty():
				return "unknown bone '%s' in %s" % [key, field]
	if recipe.has("equipment"):
		if recipe["equipment"] is not Dictionary:
			return "equipment must be a dictionary of slot -> piece name"
		var registry := equipment_registry()
		for slot: String in recipe["equipment"]:
			if slot not in (registry["slots"] as Array):
				return "unknown equipment slot '%s' — shipped slots may never be removed" % slot
			var piece_name := String(recipe["equipment"][slot])
			if piece_name not in (registry["pieces"] as Dictionary):
				return "unknown equipment piece '%s' — shipped pieces may never be removed" % piece_name
			if String(registry["pieces"][piece_name]["slot"]) != slot:
				return "piece '%s' does not go in slot '%s'" % [piece_name, slot]
	if recipe.has("skin"):
		if recipe["skin"] is not String:
			return "skin must be a skins-registry name"
		if String(recipe["skin"]) not in (skins_registry()["skins"] as Dictionary):
			return "unknown skin '%s' — shipped skins may never be removed" % recipe["skin"]
	return ""


## Loads a recipe JSON from disk; null on parse failure (with an error).
static func load_recipe(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("CharacterFactory: cannot open recipe %s" % path)
		return null
	var parsed = JSON.parse_string(file.get_as_text())
	if parsed is not Dictionary:
		push_error("CharacterFactory: recipe %s is not a JSON object" % path)
		return null
	return parsed


## Order-stable fingerprint of a built character: skeleton global rests plus
## the CPU-evaluated morph mix of EVERY skinned mesh under the skeleton (body
## and equipped pieces, name-sorted). Headless CI has no GPU, so the mix
## (base + sum of w * delta) is reproduced from the imported blend-shape
## arrays; NORMALIZED mode stores absolute targets.
static func fingerprint(instance: Node3D) -> String:
	var skeleton := find_skeleton(instance)
	if skeleton == null or find_skinned_mesh(skeleton) == null:
		return "no-skeleton-or-mesh"
	skeleton.force_update_all_bone_transforms()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for i in skeleton.get_bone_count():
		ctx.update(var_to_bytes(skeleton.get_bone_global_rest(i)))
	var names := PackedStringArray()
	var meshes := {}
	for child in skeleton.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).skin != null:
			names.append(String(child.name))
			meshes[String(child.name)] = child
	names.sort()
	var total_verts := 0
	for mesh_name in names:
		ctx.update(mesh_name.to_utf8_buffer())
		var mixed := _mixed_vertices(meshes[mesh_name])
		total_verts += mixed.size()
		ctx.update(mixed.to_byte_array())
	# The skin changes no geometry but IS the character's identity too.
	ctx.update(String(instance.get_meta("skin", "")).to_utf8_buffer())
	return "bones=%d meshes=%d verts=%d sha256=%s" % [
		skeleton.get_bone_count(), names.size(), total_verts, ctx.finish().hex_encode()]


static func _mixed_vertices(mesh_instance: MeshInstance3D) -> PackedVector3Array:
	var mesh := mesh_instance.mesh
	var base: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var mixed := PackedVector3Array(base)
	var blends := mesh.surface_get_blend_shape_arrays(0)
	var normalized: bool = mesh is ArrayMesh \
		and (mesh as ArrayMesh).blend_shape_mode == Mesh.BLEND_SHAPE_MODE_NORMALIZED
	for shape_index in mesh.get_blend_shape_count():
		var weight := mesh_instance.get_blend_shape_value(shape_index)
		if is_zero_approx(weight):
			continue
		var targets: PackedVector3Array = blends[shape_index][Mesh.ARRAY_VERTEX]
		for v in mixed.size():
			var delta := targets[v] - base[v] if normalized else targets[v]
			mixed[v] += delta * weight
	return mixed


static func find_skeleton(node: Node) -> Skeleton3D:
	if node == null or node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := find_skeleton(child)
		if found != null:
			return found
	return null


## The BODY mesh — equipment meshes (Equip_ prefix) are deliberately skipped.
static func find_skinned_mesh(skeleton: Skeleton3D) -> MeshInstance3D:
	if skeleton == null:
		return null
	for child in skeleton.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).skin != null \
				and not String(child.name).begins_with(EQUIP_PREFIX):
			return child
	return null


## A recipe bone key is an exact bone name or a bare name with _l/_r variants.
static func _bones_for(skeleton: Skeleton3D, key: String) -> PackedInt32Array:
	var out := PackedInt32Array()
	var exact := skeleton.find_bone(key)
	if exact >= 0:
		out.append(exact)
		return out
	for suffix in ["_l", "_r"]:
		var i := skeleton.find_bone(key + suffix)
		if i >= 0:
			out.append(i)
	return out


## Uniform girth around one bone; immediate children exactly compensated
## (basis x 1/g, origin / g) so joints stay put and descendants keep size.
## Uniform-only keeps every rest TRS-representable (poses are TRS; shear in a
## rest is silently dropped at reset_bone_poses and the skin lies).
static func _apply_girth(skeleton: Skeleton3D, bone: int, girth: float) -> void:
	var rest := skeleton.get_bone_rest(bone)
	skeleton.set_bone_rest(bone, Transform3D(rest.basis * Basis.from_scale(Vector3.ONE * girth), rest.origin))
	for child in skeleton.get_bone_children(bone):
		var child_rest := skeleton.get_bone_rest(child)
		skeleton.set_bone_rest(child, Transform3D(
			child_rest.basis * Basis.from_scale(Vector3.ONE / girth), child_rest.origin / girth))


## Uniform subtree scale: the bone and everything below it grow around the
## bone's own joint (a hand grows its fingers, a head its face).
static func _apply_uniform_subtree(skeleton: Skeleton3D, bone: int, factor: float) -> void:
	var rest := skeleton.get_bone_rest(bone)
	skeleton.set_bone_rest(bone, Transform3D(rest.basis * Basis.from_scale(Vector3.ONE * factor), rest.origin))


## Moves a joint along its offset from the parent joint: pushing upperarm out
## widens the shoulders; pushing hand out lengthens the forearm.
static func _scale_joint_origin(skeleton: Skeleton3D, bone: int, factor: float) -> void:
	var rest := skeleton.get_bone_rest(bone)
	skeleton.set_bone_rest(bone, Transform3D(rest.basis, rest.origin * factor))


## Rotates a bone's rest so its +Y (the bone direction) swings toward world
##-Y by `deg` — a world-space rotation conjugated into bone space. Pure
## rotation: no shear can enter the rest (the TRS law). The global rest is
## composed manually — reading engine globals mid-edit desyncs the caches
## (Godot 4.7, proven in Phase 0 stage 2).
static func _hang_toward_down(skeleton: Skeleton3D, bone: int, deg: float) -> void:
	if bone < 0:
		push_error("CharacterFactory: arm bone not found")
		return
	var global_rest := _composed_global_rest(skeleton, bone)
	var dir := global_rest.basis.y.normalized()
	var axis := dir.cross(Vector3.DOWN)
	if axis.length_squared() < 0.000001:
		return
	var world_rot := Basis(axis.normalized(), deg_to_rad(deg))
	var local_rot := global_rest.basis.inverse() * (world_rot * global_rest.basis)
	var rest := skeleton.get_bone_rest(bone)
	skeleton.set_bone_rest(bone, Transform3D(rest.basis * local_rot, rest.origin))


static func _composed_global_rest(skeleton: Skeleton3D, bone: int) -> Transform3D:
	var out := skeleton.get_bone_rest(bone)
	var parent := skeleton.get_bone_parent(bone)
	while parent >= 0:
		out = skeleton.get_bone_rest(parent) * out
		parent = skeleton.get_bone_parent(parent)
	return out
