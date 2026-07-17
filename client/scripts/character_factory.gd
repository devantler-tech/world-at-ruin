class_name CharacterFactory
## Runtime composition layer of the character system (issue #24, stage 2):
## builds a character from a RECIPE — a versioned, name-keyed parameter
## dictionary — on top of the baked humanoid kit.
##
## Recipes are the persistence format for every humanoid (players, NPCs,
## humanoid enemies), so they obey the no-resets product law:
##  - keyed by stable STRING names (blend shapes, bones) — never indices;
##  - forward-only: a name that ever shipped keeps working forever (the kit
##    may only ADD shapes; the golden-recipe regression test enforces it);
##  - versioned: `version` <= RECIPE_VERSION is accepted forever, a NEWER
##    version is rejected loudly (an old client must never half-apply a
##    recipe it does not fully understand).
##
## Bone edits follow the laws proven in Phase 0 stage 2 (see the test's
## pose==rest guard): rests must stay TRS-representable — only UNIFORM bone
## scales (with exact child compensation: basis x 1/g, origin / g), origin
## scaling for joint pushes, and no engine global reads between rest edits
## (Godot 4.7 desyncs its rest/pose caches).

const RECIPE_VERSION := 1
const KIT_SCENE_PATH := "res://assets/characters/humanoid_kit/humanoid_base.glb"


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
	skeleton.reset_bone_poses()
	skeleton.force_update_all_bone_transforms()

	for shape_name: String in recipe.get("shapes", {}):
		var idx := mesh_instance.find_blend_shape_by_name(shape_name)
		mesh_instance.set_blend_shape_value(idx, recipe["shapes"][shape_name])
	return instance


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
	for shape_name: String in recipe.get("shapes", {}):
		if mesh_instance.find_blend_shape_by_name(shape_name) < 0:
			return "unknown blend shape '%s' — shipped kit shapes may never be removed" % shape_name
	for field in ["bone_girth", "bone_scale", "joint_push"]:
		for key: String in recipe.get(field, {}):
			if _bones_for(skeleton, key).is_empty():
				return "unknown bone '%s' in %s" % [key, field]
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
## the CPU-evaluated morph mix under the instance's current weights. Headless
## CI has no GPU, so the mix (base + sum of w * delta) is reproduced from the
## imported blend-shape arrays; NORMALIZED mode stores absolute targets.
static func fingerprint(instance: Node3D) -> String:
	var skeleton := find_skeleton(instance)
	var mesh_instance := find_skinned_mesh(skeleton)
	if skeleton == null or mesh_instance == null:
		return "no-skeleton-or-mesh"
	skeleton.force_update_all_bone_transforms()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for i in skeleton.get_bone_count():
		ctx.update(var_to_bytes(skeleton.get_bone_global_rest(i)))
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
	ctx.update(mixed.to_byte_array())
	return "bones=%d verts=%d sha256=%s" % [
		skeleton.get_bone_count(), mixed.size(), ctx.finish().hex_encode()]


static func find_skeleton(node: Node) -> Skeleton3D:
	if node == null or node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := find_skeleton(child)
		if found != null:
			return found
	return null


static func find_skinned_mesh(skeleton: Skeleton3D) -> MeshInstance3D:
	if skeleton == null:
		return null
	for child in skeleton.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).skin != null:
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
