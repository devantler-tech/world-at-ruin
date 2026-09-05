class_name KitAssembly
## The kit-reaching primitives both runtime factories are built on (issue #276).
##
## `CharacterFactory` (humanoid) and `CreatureFactory` (quadruped) compose
## different kits from different recipe vocabularies, but they reach INTO a
## baked kit the same way: gate a recipe on its version, find the one skeleton,
## find the body mesh hanging under it, scale a bone's subtree around its own
## joint, commit the rests and apply the morph weights, evaluate the current
## morph mix on the CPU, and hash the rests for a fingerprint. Each factory
## keeps its own public entry points and calls through to here, so callers are
## unaffected and there is ONE implementation to fix — a change to the character
## path reaches the creature path by construction.
##
## Static-only: there is nothing here to instantiate.


## The first `Skeleton3D` at or below `node`, depth-first; null when the subtree
## holds none (and null for a null `node`, so a caller can chain a failed load
## straight in). A baked kit's skeleton sits at an import-defined depth that
## differs per kit, which is why every caller searches rather than assuming a
## node path.
static func find_skeleton(node: Node) -> Skeleton3D:
	if node == null or node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := find_skeleton(child)
		if found != null:
			return found
	return null


## The BODY mesh under `skeleton`: its first skinned `MeshInstance3D` child
## whose name does not start with `exclude_prefix`.
##
## The humanoid kit parents equipment meshes onto the same skeleton as the body,
## so it must skip them by name or a garment answers as the body. The creature
## kit has no such meshes and passes no prefix — an EMPTY `exclude_prefix`
## therefore means "exclude nothing", which is deliberate: every string starts
## with "", so applying the test unconditionally would reject every mesh.
static func find_skinned_mesh(skeleton: Skeleton3D, exclude_prefix: String = "") -> MeshInstance3D:
	if skeleton == null:
		return null
	for child in skeleton.get_children():
		if child is not MeshInstance3D:
			continue
		var mesh := child as MeshInstance3D
		if mesh.skin == null:
			continue
		if exclude_prefix != "" and String(mesh.name).begins_with(exclude_prefix):
			continue
		return mesh
	return null


## Uniform subtree scale: the bone and everything below it grow around the
## bone's own joint (a hand grows its fingers, a head its face).
##
## UNIFORM ONLY, and that is a product law rather than a simplification: rests
## must stay TRS-representable, and a non-uniform basis introduces shear that
## `reset_bone_poses()` silently drops while the skin goes on deforming as if it
## were still there. The origin is carried through untouched — moving a joint
## along its offset is a different operation.
static func scale_bone_subtree(skeleton: Skeleton3D, bone: int, factor: float) -> void:
	var rest := skeleton.get_bone_rest(bone)
	skeleton.set_bone_rest(bone, Transform3D(rest.basis * Basis.from_scale(Vector3.ONE * factor), rest.origin))


## CPU-evaluated vertex mix for surface 0 of a skinned kit mesh.
##
## Headless CI has no GPU, so both factory fingerprints reproduce the current
## blend-shape result from the imported arrays. Relative mode stores deltas;
## normalized mode stores absolute targets and therefore subtracts the base
## before applying the weight.
static func mixed_vertices(mesh_instance: MeshInstance3D) -> PackedVector3Array:
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
		for vertex_index in mixed.size():
			var delta := targets[vertex_index] - base[vertex_index] if normalized else targets[vertex_index]
			mixed[vertex_index] += delta * weight
	return mixed


## The version gate every recipe passes before any other field is read: "" when
## `recipe` carries an integer `version` from 1 up to `newest`, else the reason a
## caller reports. A newer version is refused outright rather than rendered in
## part, so a client never shows a body that is not what its recipe says, and
## both factories refuse it with the same words.
static func recipe_version_problem(recipe: Dictionary, newest: int) -> String:
	var version = recipe.get("version")
	if not (version is int or (version is float and version == floorf(version))):
		return "recipe has no integer version"
	if int(version) < 1:
		return "recipe version %d is not positive" % int(version)
	if int(version) > newest:
		return "recipe version %d is newer than this client understands (%d)" % [int(version), newest]
	return ""


## Commits every rest edit, then applies the recipe's morph weights — in that
## order, because rest edits and engine global reads must not interleave, and
## the morph pass is the first thing a factory does once the rests are final.
static func commit_rests_and_apply_shapes(
	skeleton: Skeleton3D, mesh_instance: MeshInstance3D, shapes: Dictionary
) -> void:
	skeleton.reset_bone_poses()
	skeleton.force_update_all_bone_transforms()
	for shape_name: String in shapes:
		var idx := mesh_instance.find_blend_shape_by_name(shape_name)
		mesh_instance.set_blend_shape_value(idx, shapes[shape_name])


## A SHA-256 context primed with every bone's global rest, in bone order, after
## the transforms are brought up to date — the prefix both factory fingerprints
## share before each adds its own meshes and identity. Byte order is part of the
## fingerprint contract: the golden fixtures pin it.
static func rest_hash_context(skeleton: Skeleton3D) -> HashingContext:
	skeleton.force_update_all_bone_transforms()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for i in skeleton.get_bone_count():
		ctx.update(var_to_bytes(skeleton.get_bone_global_rest(i)))
	return ctx
