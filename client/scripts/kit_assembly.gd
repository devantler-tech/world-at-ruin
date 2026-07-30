class_name KitAssembly
## The kit-reaching primitives both runtime factories are built on (issue #276).
##
## `CharacterFactory` (humanoid) and `CreatureFactory` (quadruped) compose
## different kits from different recipe vocabularies, but they reach INTO a
## baked kit the same way: find the one skeleton, find the body mesh hanging
## under it, scale a bone's subtree around its own joint, and evaluate the
## current morph mix on the CPU. Those four operations were copied between the
## two factories, so a fix applied to the character path did not reach the
## creature path — the drift this file exists to end. Each factory keeps its
## own public entry points and calls through to here, so callers are unaffected
## and there is one implementation to fix.
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
