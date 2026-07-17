@tool
class_name CharacterGen
extends Node3D
## Phase 0 art pipeline, stage 2: the first character — a committed CC0 rigged
## base mesh (Quaternius Superhero Male, see assets/characters/superhero_male/
## PROVENANCE.md) whose proportions are parametrized in code by editing the
## skeleton's REST poses (maintainer direction on issue #20: try this before
## spending the Blender/Python exception).
##
## @tool means this runs live in the editor viewport: open scenes/character.tscn
## and switch `preset` in the inspector to watch the body change — that is the
## taste gate. The same script runs headless in CI (the determinism regression
## test) and will dress NPCs/players at runtime later.
##
## Why rest-pose editing (not pose scaling): poses are the animation target —
## any keyed channel is overwritten on the first animation tick. Rest edits are
## the durable substrate: humanoid clips key rotations (plus hips position), so
## edited translations and scales survive everywhere else. The inverse bind
## matrices are left untouched — skinning deforms the mesh relative to the
## ORIGINAL binds, which is exactly the mechanism that makes rest edits show.
##
## THE ONE HARD CONSTRAINT: rests must stay TRS-representable (rotation ·
## uniform-ish scale, never shear). Rests are full matrices but bone POSES —
## what skinning actually consumes — are stored as position/quaternion/scale;
## reset_bone_poses() decomposes each rest, and any shear is silently dropped
## (asymmetrically, per the rotation involved — one arm springs back to
## T-pose). Non-uniform scale compensated through a rotated child basis IS
## shear, so:
##  - girth = post-multiply the bone's rest basis by a UNIFORM scale g, then
##    exactly compensate each immediate child (basis pre-multiplied by 1/g,
##    origin divided by g) so descendants keep their size and every joint
##    provably stays put. Uniform scale commutes with rotation — no shear.
##  - uniform subtree = post-multiply the bone's rest basis, do NOT compensate
##    children: a 1.28x hand grows its fingers with it (the heroic read).
##  - length / shoulder push-out = scale the CHILD joint's rest origin (the
##    parent bone runs from its own joint to the child's).
##  - pose (arm hang) = a world-space rotation conjugated into the bone's
##    local rest frame — side-agnostic, and a pure rotation because every
##    ancestor scale is uniform.
## Everything is deterministic: presets are constants, there is no randomness.

const BASE_SCENE_PATH := "res://assets/characters/superhero_male/Superhero_Male_FullBody.gltf"
const FOREARM_RELAX_DEG := 10.0
const HAND_RELAX_DEG := 8.0

enum Preset { BASE, GROUNDED, HERO }

## Proportion presets. Values are multipliers vs the committed base body
## (which is already heroic — a Quaternius "Superhero" body — so HERO pushes
## moderately toward the WoW register and GROUNDED pulls toward realism; the
## side-by-side range is what the taste gate judges).
const PRESETS := {
	Preset.BASE: {
		"girth": {}, "uniform": {}, "length": {}, "shoulder_out": 1.0,
	},
	Preset.GROUNDED: {
		"girth": {
			"neck_01": 0.95, "spine_03": 0.95, "spine_02": 0.98,
			"upperarm": 0.94, "lowerarm": 0.94, "thigh": 0.96, "calf": 0.95,
		},
		"uniform": { "hand": 0.92, "foot": 0.97 },
		"length": {},
		"shoulder_out": 0.95,
	},
	Preset.HERO: {
		"girth": {
			"neck_01": 1.18, "spine_03": 1.12, "spine_02": 1.06, "spine_01": 0.95,
			"upperarm": 1.10, "lowerarm": 1.18, "thigh": 1.08, "calf": 1.15,
		},
		"uniform": { "Head": 1.06, "hand": 1.28, "foot": 1.15 },
		"length": { "lowerarm": 1.04, "hand": 1.06 },
		"shoulder_out": 1.08,
	},
}

@export var preset: Preset = Preset.HERO:
	set(v):
		preset = v
		if is_inside_tree():
			rebuild()
## Degrees the arms hang down from the T-pose (0 keeps the T-pose). A pose
## parameter, not a proportion: applied to every preset so bodies compare
## honestly.
@export var arm_hang_deg: float = 62.0:
	set(v):
		arm_hang_deg = v
		if is_inside_tree():
			rebuild()

var _instance: Node3D


func _ready() -> void:
	rebuild()


## Rebuilds the character from the current parameters.
func rebuild() -> void:
	if _instance != null:
		_instance.queue_free()
	_instance = build(preset, arm_hang_deg)
	if _instance != null:
		add_child(_instance)


## Pure construction — static so tests can call it without a scene tree.
## Returns the proportioned base-mesh instance, or null (with an error) if the
## committed asset is missing.
static func build(p_preset: Preset, p_arm_hang_deg: float) -> Node3D:
	var packed: PackedScene = load(BASE_SCENE_PATH)
	if packed == null:
		push_error("CharacterGen: cannot load %s" % BASE_SCENE_PATH)
		return null
	var instance := packed.instantiate() as Node3D
	var skel := find_skeleton(instance)
	if skel == null:
		push_error("CharacterGen: no Skeleton3D in %s" % BASE_SCENE_PATH)
		instance.free()
		return null
	apply_proportions(skel, PRESETS[p_preset])
	if absf(p_arm_hang_deg) > 0.001:
		for arm in ["upperarm_l", "upperarm_r"]:
			_hang_toward_down(skel, skel.find_bone(arm), p_arm_hang_deg)
		# A slight elbow and wrist curl so the hang reads relaxed, not
		# scarecrow: forearm and hand each continue a few degrees further
		# toward vertical.
		for forearm in ["lowerarm_l", "lowerarm_r"]:
			_hang_toward_down(skel, skel.find_bone(forearm), FOREARM_RELAX_DEG)
		for hand in ["hand_l", "hand_r"]:
			_hang_toward_down(skel, skel.find_bone(hand), HAND_RELAX_DEG)
	skel.reset_bone_poses()
	skel.force_update_all_bone_transforms()
	return instance


## Applies a preset's proportion edits to the skeleton's rests.
## Order matters only in that girth compensation writes child BASES before the
## extremities' own uniform scales post-multiply them.
static func apply_proportions(skel: Skeleton3D, params: Dictionary) -> void:
	for key: String in params["girth"]:
		for bone in _bones_for(skel, key):
			_apply_girth(skel, bone, params["girth"][key])
	for key: String in params["uniform"]:
		for bone in _bones_for(skel, key):
			_apply_uniform_subtree(skel, bone, params["uniform"][key])
	for key: String in params["length"]:
		for bone in _bones_for(skel, key):
			_scale_joint_origin(skel, bone, params["length"][key])
	var out: float = params["shoulder_out"]
	if not is_equal_approx(out, 1.0):
		for bone in _bones_for(skel, "upperarm"):
			_scale_joint_origin(skel, bone, out)


## Resolves a preset key to bone indices: an exact bone name, or the
## left/right pair when only `key + "_l"/"_r"` exist.
static func _bones_for(skel: Skeleton3D, key: String) -> PackedInt32Array:
	var out := PackedInt32Array()
	var exact := skel.find_bone(key)
	if exact >= 0:
		out.append(exact)
		return out
	for suffix in ["_l", "_r"]:
		var i := skel.find_bone(key + suffix)
		if i >= 0:
			out.append(i)
	if out.is_empty():
		push_error("CharacterGen: no bone matches '%s'" % key)
	return out


## Girth: thicken/slim the weight region around one bone with a UNIFORM scale
## (non-uniform would shear rotated children — see the header). Immediate
## children are exactly compensated: basis by 1/g, origin by 1/g (the parent's
## scaled basis multiplies it right back), so joints never move and
## descendants keep their size.
static func _apply_girth(skel: Skeleton3D, bone: int, g: float) -> void:
	var rest := skel.get_bone_rest(bone)
	skel.set_bone_rest(bone, Transform3D(rest.basis * Basis.from_scale(Vector3.ONE * g), rest.origin))
	for child in skel.get_bone_children(bone):
		var child_rest := skel.get_bone_rest(child)
		skel.set_bone_rest(child, Transform3D(
			child_rest.basis * Basis.from_scale(Vector3.ONE / g), child_rest.origin / g))


## Uniform subtree scale: the bone and everything below it grow around the
## bone's own joint (hands grow their fingers, the head its face).
static func _apply_uniform_subtree(skel: Skeleton3D, bone: int, f: float) -> void:
	var rest := skel.get_bone_rest(bone)
	skel.set_bone_rest(bone, Transform3D(rest.basis * Basis.from_scale(Vector3.ONE * f), rest.origin))


## Moves a joint along its offset from the parent joint: scaling hand's origin
## lengthens the FOREARM; scaling upperarm's origin pushes the shoulder out
## along the clavicle.
static func _scale_joint_origin(skel: Skeleton3D, bone: int, f: float) -> void:
	var rest := skel.get_bone_rest(bone)
	skel.set_bone_rest(bone, Transform3D(rest.basis, rest.origin * f))


## Rotates a bone (in world space) so its axis tilts from the current rest
## direction toward straight down by `deg` — brings T-pose arms to a relaxed
## hang. Conjugating the world rotation into the local rest frame keeps this
## exact for either side and after any girth scaling.
##
## The global rest is composed MANUALLY here, never via get_bone_global_rest:
## reading the engine's global caches between set_bone_rest edits desyncs the
## rest and pose caches in Godot 4.7 (one arm renders back in the T-pose while
## the local poses read correct) — no engine global may be read until all rest
## edits are done and reset_bone_poses()/force_update has run.
static func _hang_toward_down(skel: Skeleton3D, bone: int, deg: float) -> void:
	if bone < 0:
		push_error("CharacterGen: arm bone not found")
		return
	var global_rest := _composed_global_rest(skel, bone)
	var dir := global_rest.basis.y.normalized()
	var axis := dir.cross(Vector3.DOWN)
	if axis.length_squared() < 0.000001:
		return
	var world_rot := Basis(axis.normalized(), deg_to_rad(deg))
	var local_rot := global_rest.basis.inverse() * (world_rot * global_rest.basis)
	var rest := skel.get_bone_rest(bone)
	skel.set_bone_rest(bone, Transform3D(rest.basis * local_rot, rest.origin))


## Global rest composed by walking the parent chain — see _hang_toward_down
## for why the engine's cached get_bone_global_rest must not be used here.
static func _composed_global_rest(skel: Skeleton3D, bone: int) -> Transform3D:
	var chain: Array[int] = []
	var walk := bone
	while walk >= 0:
		chain.push_front(walk)
		walk = skel.get_bone_parent(walk)
	var global := Transform3D.IDENTITY
	for i in chain:
		global = global * skel.get_bone_rest(i)
	return global


## First Skeleton3D under `node`, or null.
static func find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := find_skeleton(child)
		if found != null:
			return found
	return null


## Order-stable fingerprint of the posed skeleton AND the skin-deformed mesh;
## the determinism test compares it across builds. Skinning is computed on the
## CPU (v' = Σ w · global_pose · bind · v) because the GPU bake API needs a
## live RenderingServer skeleton, which headless CI does not have.
static func fingerprint(root: Node3D) -> String:
	var skel := find_skeleton(root)
	if skel == null:
		return "no-skeleton"
	skel.force_update_all_bone_transforms()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for i in skel.get_bone_count():
		ctx.update(var_to_bytes(skel.get_bone_global_rest(i)))
	var tris := 0
	for child in skel.get_children():
		if child is not MeshInstance3D:
			continue
		var mi := child as MeshInstance3D
		var deformed := _cpu_skin(skel, mi)
		ctx.update(var_to_bytes(deformed))
		tris += deformed.size()
	return "bones=%d skinned_verts=%d sha256=%s" % [
		skel.get_bone_count(), tris, ctx.finish().hex_encode()]


## CPU linear-blend skinning of a MeshInstance3D against its skeleton's
## current global poses. Returns the deformed vertex stream, surface-ordered.
static func _cpu_skin(skel: Skeleton3D, mi: MeshInstance3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	var skin := mi.skin
	if skin == null:
		return out
	# Per-bind deform matrix: global pose composed with the original inverse
	# bind (never regenerate the binds — that would cancel the rest edits).
	var deform: Array[Transform3D] = []
	for b in skin.get_bind_count():
		var bone := skin.get_bind_bone(b)
		if bone < 0:
			bone = skel.find_bone(skin.get_bind_name(b))
		deform.append(skel.get_bone_global_pose(bone) * skin.get_bind_pose(b))
	for s in mi.mesh.get_surface_count():
		var arrays := mi.mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		if bones.is_empty() or weights.is_empty():
			out.append_array(verts)
			continue
		var influences := bones.size() / verts.size()
		for v in verts.size():
			var p := Vector3.ZERO
			for k in influences:
				var wgt := weights[v * influences + k]
				if wgt > 0.0:
					p += deform[bones[v * influences + k]] * verts[v] * wgt
			out.append(p)
	return out
