class_name CreatureFactory
## Runtime composition layer of the creature system (issue #24, final stage):
## builds a non-humanoid creature from a RECIPE — a versioned, name-keyed
## parameter dictionary — on top of a baked creature kit (the ash hound is the
## pilot archetype). This is the humanoid CharacterFactory's design language
## applied to a quadruped: one canonical skeleton per archetype, morph shape
## keys, a shared-material tint per creature, and the same forward-only laws.
##
## Recipes are the persistence format for every creature, so they obey the
## no-resets product law, exactly like character recipes:
##  - keyed by stable STRING names (morph shapes, bones, tints) — never
##    indices;
##  - forward-only: a name that ever shipped keeps working forever (the kit
##    may only ADD shapes/tints; the golden-recipe regression test enforces
##    it);
##  - versioned: `version` <= RECIPE_VERSION is accepted forever, a NEWER
##    version is rejected loudly.
##
## Bone edits follow the TRS laws proven in the character system: rests must
## stay TRS-representable — only UNIFORM subtree scales — and no engine global
## reads between rest edits. A quadruped needs no standing-pose pass: the kit
## is baked standing (its rest IS the pose), unlike the humanoid arm-hang.

const RECIPE_VERSION := 1
const KIT_SCENE_PATH := "res://assets/characters/creature_kit/ash_hound.glb"
const TINTS_REGISTRY_PATH := "res://assets/characters/creature_kit/tints.json"

## The recipe format, exhaustively: any other top-level field is REJECTED — a
## recipe carrying data this client cannot render must fail loudly, never
## render a half-truth (no-resets law). New fields ship with a version bump.
const RECIPE_FIELDS := ["version", "comment", "shapes", "bone_scale", "tint"]

## The GUARDED bone keys for bone_scale — exactly the set the golden recipe
## exercises forever. `root` scales the whole animal (size variety); `head`
## and `tail_01` scale those subtrees. Persisted recipes may only touch these;
## extending this list means extending the golden recipe in the same change.
const GUARDED_BONE_KEYS := {
	"bone_scale": ["root", "head", "tail_01"],
}

static var _tints_registry: Dictionary = {}
static var _tint_materials: Dictionary = {}


## Builds a creature instance from a recipe, or returns null after push_error
## when the recipe is invalid. The caller owns the instance.
static func build(recipe: Dictionary) -> Node3D:
	var packed: PackedScene = load(KIT_SCENE_PATH)
	if packed == null:
		push_error("CreatureFactory: kit missing: %s" % KIT_SCENE_PATH)
		return null
	var instance := packed.instantiate() as Node3D
	var skeleton := find_skeleton(instance)
	var mesh_instance := find_skinned_mesh(skeleton)
	if skeleton == null or mesh_instance == null:
		push_error("CreatureFactory: kit has no skeleton or skinned mesh")
		instance.free()
		return null

	var problem := validate(recipe, skeleton, mesh_instance)
	if problem != "":
		push_error("CreatureFactory: invalid recipe: %s" % problem)
		instance.free()
		return null

	# Bone ops first (rest edits, no engine global reads), then morphs.
	for key: String in recipe.get("bone_scale", {}):
		var bone := skeleton.find_bone(key)
		if bone >= 0:
			_apply_uniform_subtree(skeleton, bone, recipe["bone_scale"][key])
	skeleton.reset_bone_poses()
	skeleton.force_update_all_bone_transforms()

	for shape_name: String in recipe.get("shapes", {}):
		var idx := mesh_instance.find_blend_shape_by_name(shape_name)
		mesh_instance.set_blend_shape_value(idx, recipe["shapes"][shape_name])

	if recipe.has("tint"):
		mesh_instance.set_surface_override_material(0, _tint_material(String(recipe["tint"])))
		instance.set_meta("tint", recipe["tint"])
	return instance


## One shared material per tint: N hounds with the same tint are one material,
## not N. The hide is surface 0; the eyes (surface 1) keep their baked
## material, so a tint never paints the eyes.
static func _tint_material(tint_name: String) -> StandardMaterial3D:
	if tint_name in _tint_materials:
		return _tint_materials[tint_name]
	var color: Array = tints_registry()["tints"][tint_name]["color"]
	var material := StandardMaterial3D.new()
	# Registry colours are linear (baked srgb->linear); assign them straight to
	# albedo without a second gamma pass.
	material.albedo_color = Color(color[0], color[1], color[2])
	material.roughness = 0.9
	_tint_materials[tint_name] = material
	return material


## The baked tint registry (tints.json): names are forward-only, exactly like
## the character kit's blend shapes and skins. Cached — the registry only
## changes with the committed kit.
static func tints_registry() -> Dictionary:
	if not _tints_registry.is_empty():
		return _tints_registry
	var file := FileAccess.open(TINTS_REGISTRY_PATH, FileAccess.READ)
	if file == null:
		push_error("CreatureFactory: tints registry missing: %s" % TINTS_REGISTRY_PATH)
		return { "tints": {} }
	var parsed = JSON.parse_string(file.get_as_text())
	if parsed is not Dictionary:
		push_error("CreatureFactory: tints registry is not a JSON object")
		return { "tints": {} }
	_tints_registry = parsed
	return _tints_registry


## Full validation against the kit: "" when the recipe is applicable, else a
## human-readable reason. Rejecting future versions and unknown fields outright
## is deliberate — silently skipping them would render a creature that is not
## what its recipe says (a forward-compat lie).
static func validate(recipe: Dictionary, skeleton: Skeleton3D, mesh_instance: MeshInstance3D) -> String:
	var version = recipe.get("version")
	if not (version is int or (version is float and version == floorf(version))):
		return "recipe has no integer version"
	if int(version) < 1:
		return "recipe version %d is not positive" % int(version)
	if int(version) > RECIPE_VERSION:
		return "recipe version %d is newer than this client understands (%d)" % [int(version), RECIPE_VERSION]
	for field: String in recipe:
		if field not in RECIPE_FIELDS:
			return "unknown recipe field '%s' — this client cannot render it, refusing a half-truth" % field
	if recipe.has("shapes"):
		if recipe["shapes"] is not Dictionary:
			return "shapes must be a dictionary of shape name -> weight"
		for shape_name: String in recipe["shapes"]:
			if mesh_instance.find_blend_shape_by_name(shape_name) < 0:
				return "unknown morph shape '%s' — shipped kit shapes may never be removed" % shape_name
	if recipe.has("bone_scale"):
		if recipe["bone_scale"] is not Dictionary:
			return "bone_scale must be a dictionary of bone name -> factor"
		for key: String in recipe["bone_scale"]:
			if key not in (GUARDED_BONE_KEYS["bone_scale"] as Array):
				return "bone key '%s' is outside the guarded set — only golden-guarded keys may persist" % key
			if skeleton.find_bone(key) < 0:
				return "unknown bone '%s'" % key
	if recipe.has("tint"):
		if recipe["tint"] is not String:
			return "tint must be a tints-registry name"
		if String(recipe["tint"]) not in (tints_registry()["tints"] as Dictionary):
			return "unknown tint '%s' — shipped tints may never be removed" % recipe["tint"]
	return ""


## Loads a recipe JSON from disk; null on parse failure (with an error).
static func load_recipe(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("CreatureFactory: cannot open recipe %s" % path)
		return null
	var parsed = JSON.parse_string(file.get_as_text())
	if parsed is not Dictionary:
		push_error("CreatureFactory: recipe %s is not a JSON object" % path)
		return null
	return parsed


## Order-stable fingerprint of a built creature: skeleton global rests plus the
## CPU-evaluated morph mix of the hide mesh, plus the tint identity. Headless
## CI has no GPU, so the mix (base + Σ w·delta) is reproduced from the imported
## blend-shape arrays; NORMALIZED mode (how glTF imports) stores absolute
## targets. Mirrors CharacterFactory.fingerprint.
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
	var mixed := _mixed_vertices(mesh_instance)
	ctx.update(mixed.to_byte_array())
	ctx.update(String(instance.get_meta("tint", "")).to_utf8_buffer())
	return "bones=%d verts=%d sha256=%s" % [
		skeleton.get_bone_count(), mixed.size(), ctx.finish().hex_encode()]


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


static func find_skinned_mesh(skeleton: Skeleton3D) -> MeshInstance3D:
	if skeleton == null:
		return null
	for child in skeleton.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).skin != null:
			return child
	return null


## Uniform subtree scale: the bone and everything below it grow around the
## bone's own joint. Uniform-only keeps every rest TRS-representable (poses are
## TRS; shear in a rest is silently dropped at reset_bone_poses and the skin
## lies) — the law proven in the character system.
static func _apply_uniform_subtree(skeleton: Skeleton3D, bone: int, factor: float) -> void:
	var rest := skeleton.get_bone_rest(bone)
	skeleton.set_bone_rest(bone, Transform3D(rest.basis * Basis.from_scale(Vector3.ONE * factor), rest.origin))
