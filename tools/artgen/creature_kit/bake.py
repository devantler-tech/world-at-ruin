"""Creature kit bake — creature archetype pilot (issue #24, final stage).

Runs inside headless Blender (no extensions, no downloaded assets — the
creature is authored ENTIRELY by this script from Blender primitives):

    blender --background --python bake.py -- /abs/output/ash_hound.glb

Bakes one non-humanoid archetype (the ash hound, a quadruped scavenger)
through the same machinery as the humanoid kit: a parametric body built from
manifest.json -> named morph shape keys -> one canonical skeleton per
archetype with deterministic segment-distance skinning -> GLB plus a
structural report and the runtime tint registry (tints.json).

Topology comes from a hand-authored joint graph run through Blender's skin
modifier, built ONCE. Morphs never rebuild the hull (the skin modifier's
vertex count depends on the radii, so a girth change would alter topology and
break the morph contract). Instead every vertex is BOUND to the joint graph
(nearest graph edge, parameter along it, radial offset, radius at that point)
and each morph is a parametric REPROJECTION of that binding through the
morph's joints and radii — identical topology, capturable as an absolute-
target shape key, handling both bone-position and girth morphs uniformly.

Deterministic by construction: everything is driven by manifest.json and the
pinned Blender version; the artgen workflow bakes twice and byte-compares,
then compares the structural report against the committed ash_hound_report.txt.

This directory is part of the sanctioned Python/bpy exception (AGENTS.md,
Scripting); Python appears nowhere else in the repo.
"""
import hashlib
import json
import os
import sys
import traceback

import bpy
from mathutils import Vector

KIT_DIR = os.path.dirname(os.path.abspath(__file__))


def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def joints(p):
    """Every joint of the hound graph from the manifest parameters, Blender
    axes (x lateral, y forward, z up; feet planted near z~0). The keys are the
    single source of truth for graph edges, bones and skin weights alike."""
    hip_z = p["hip_height"] - p["belly_drop"]
    chest_z = p["chest_height"] - p["belly_drop"]
    chest_y = p["chest_forward"]
    hip_y = p["hip_back"]
    stance = p["leg_stance"]
    neck_y = chest_y + p["neck_length"]
    head_y = neck_y + 0.18
    head_z = p["chest_height"] + 0.18
    # shoulder/pelvis are the front/rear leg HUBS: the front legs branch off
    # the shoulder and the rear off the pelvis, so no torso joint ever carries
    # more than three graph edges (chest: spine+neck+shoulder; hips:
    # spine+tail+pelvis). A skin-modifier joint above valence 3 sprouts a loose
    # flap — this keeps the topline clean without any smoothing tricks.
    out = {
        "hips": (0.0, hip_y, hip_z),
        "chest": (0.0, chest_y, chest_z),
        "shoulder": (0.0, chest_y, chest_z * 0.66),
        "pelvis": (0.0, hip_y, hip_z * 0.66),
        "neck_base": (0.0, neck_y, p["chest_height"] + 0.1),
        "head": (0.0, head_y, head_z),
        "snout": (0.0, head_y + p["snout_length"], head_z - 0.05),
        "tail_mid": (0.0, hip_y - 0.2, hip_z - 0.06 + p["tail_lift"] * 0.5),
        "tail_tip": (0.0, hip_y - 0.36, hip_z - 0.24 + p["tail_lift"]),
    }
    for side, sx in (("l", -1.0), ("r", 1.0)):
        out[f"ear_{side}"] = (sx * 0.055, head_y - 0.04, head_z + 0.07 + p["ear_height"])
        for prefix, hub_z in (("f", chest_z), ("b", hip_z)):
            x = sx * stance
            leg_y = (chest_y if prefix == "f" else hip_y) + 0.02
            out[f"leg_{prefix}{side}_knee"] = (x, leg_y, hub_z * 0.42)
            out[f"leg_{prefix}{side}_ankle"] = (x + sx * 0.01, leg_y + 0.01, 0.16)
            out[f"foot_{prefix}{side}"] = (x + sx * 0.01, leg_y + 0.05, 0.05)
    return out


def radii(p):
    """Skin-modifier radius per joint (metres), and the same values drive the
    morph reprojection's girth scaling."""
    t = p["torso_radius_scale"]
    limb = p["limb_radius_scale"]
    head_r = 0.115 * p["head_size"]
    out = {
        "hips": 0.15 * t,
        "chest": 0.18 * t,
        "shoulder": 0.15 * t,
        "pelvis": 0.15 * t,
        "neck_base": 0.105 * t,
        "head": head_r,
        "snout": 0.05 * p["head_size"],
        "tail_mid": 0.045,
        "tail_tip": 0.02,
    }
    for side in ("l", "r"):
        out[f"ear_{side}"] = 0.018
        for prefix in ("f", "b"):
            out[f"leg_{prefix}{side}_knee"] = (0.062 if prefix == "f" else 0.075) * limb
            out[f"leg_{prefix}{side}_ankle"] = 0.042 * limb
            out[f"foot_{prefix}{side}"] = 0.05 * limb
    return out


## Graph edges (joint name pairs) — the hound's connectivity, fixed across
## every morph so topology never changes. Vertices bind to these.
EDGES = [
    ("hips", "chest"),
    ("chest", "shoulder"),
    ("hips", "pelvis"),
    ("chest", "neck_base"),
    ("neck_base", "head"),
    ("head", "snout"),
    ("hips", "tail_mid"),
    ("tail_mid", "tail_tip"),
]
for _side in ("l", "r"):
    EDGES.append(("head", f"ear_{_side}"))
    EDGES.append(("shoulder", f"leg_f{_side}_knee"))
    EDGES.append((f"leg_f{_side}_knee", f"leg_f{_side}_ankle"))
    EDGES.append((f"leg_f{_side}_ankle", f"foot_f{_side}"))
    EDGES.append(("pelvis", f"leg_b{_side}_knee"))
    EDGES.append((f"leg_b{_side}_knee", f"leg_b{_side}_ankle"))
    EDGES.append((f"leg_b{_side}_ankle", f"foot_b{_side}"))

## The canonical skeleton: bone name -> (head joint, tail joint, parent).
## Rest pose IS the standing pose — no runtime pose pass (unlike the humanoid
## arm-hang): a quadruped is baked standing. bone_scale recipes and (later)
## animation clips key on these names forever.
BONES = [
    ("root", "hips", "chest", None),
    ("spine", "hips", "chest", "root"),
    ("shoulder", "chest", "shoulder", "spine"),
    ("pelvis", "hips", "pelvis", "root"),
    ("neck", "chest", "neck_base", "spine"),
    ("head", "neck_base", "snout", "neck"),
    ("tail_01", "hips", "tail_mid", "root"),
    ("tail_02", "tail_mid", "tail_tip", "tail_01"),
]
for _side in ("l", "r"):
    BONES.append((f"leg_f{_side}_upper", "shoulder", f"leg_f{_side}_knee", "shoulder"))
    BONES.append((f"leg_f{_side}_lower", f"leg_f{_side}_knee", f"leg_f{_side}_ankle", f"leg_f{_side}_upper"))
    BONES.append((f"foot_f{_side}", f"leg_f{_side}_ankle", f"foot_f{_side}", f"leg_f{_side}_lower"))
    BONES.append((f"leg_b{_side}_upper", "pelvis", f"leg_b{_side}_knee", "pelvis"))
    BONES.append((f"leg_b{_side}_lower", f"leg_b{_side}_knee", f"leg_b{_side}_ankle", f"leg_b{_side}_upper"))
    BONES.append((f"foot_b{_side}", f"leg_b{_side}_ankle", f"foot_b{_side}", f"leg_b{_side}_lower"))


def closest_on_edge(point, a, b):
    """(t, closest_point) for `point` against segment a->b, t clamped to [0,1]."""
    ab = b - a
    seg_len_sq = ab.length_squared
    t = 0.0 if seg_len_sq == 0.0 else max(0.0, min(1.0, (point - a).dot(ab) / seg_len_sq))
    return t, a + ab * t


def bind_vertices(coords, base_joints, base_radii):
    """Bind every base vertex to the joint graph: the nearest edge, the
    parameter t along it, the radial offset vector, and the interpolated
    radius at t. This binding is the base pose; morphs reproject it."""
    bindings = []
    for co in coords:
        p = Vector(co)
        best = None
        for edge_index, (a_name, b_name) in enumerate(EDGES):
            a = Vector(base_joints[a_name])
            b = Vector(base_joints[b_name])
            t, closest = closest_on_edge(p, a, b)
            dist = (p - closest).length
            if best is None or dist < best[0]:
                r_at_t = base_radii[a_name] * (1.0 - t) + base_radii[b_name] * t
                best = (dist, edge_index, t, p - closest, r_at_t)
        bindings.append((best[1], best[2], best[3], best[4]))
    return bindings


def reproject(bindings, morph_joints, morph_radii, base_joints):
    """Every bound vertex's position under a morph's joints+radii: the base
    point slides to the morphed edge, the radial offset rotates with the edge
    and scales with the local girth. Pure deterministic vector math."""
    out = []
    for edge_index, t, radial, base_r_at_t in bindings:
        a_name, b_name = EDGES[edge_index]
        base_a = Vector(base_joints[a_name])
        base_b = Vector(base_joints[b_name])
        new_a = Vector(morph_joints[a_name])
        new_b = Vector(morph_joints[b_name])
        base_dir = base_b - base_a
        new_dir = new_b - new_a
        new_radial = Vector(radial)
        if base_dir.length_squared > 1e-12 and new_dir.length_squared > 1e-12:
            new_radial = base_dir.rotation_difference(new_dir) @ new_radial
        morph_r_at_t = morph_radii[a_name] * (1.0 - t) + morph_radii[b_name] * t
        if base_r_at_t > 1e-9:
            new_radial = new_radial * (morph_r_at_t / base_r_at_t)
        base_point = new_a.lerp(new_b, t)
        out.append(base_point + new_radial)
    return out


def build_hide(manifest, params, name):
    """The hide mesh from the joint graph: skin modifier + subdivision, applied
    (fixed topology). Same manifest+params -> byte-identical mesh."""
    j = joints(params)
    r = radii(params)
    names = sorted(j)
    index = {jn: i for i, jn in enumerate(names)}
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([j[jn] for jn in names], [(index[a], index[b]) for a, b in EDGES], [])
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj

    skin = obj.modifiers.new("Skin", "SKIN")
    skin.branch_smoothing = manifest["branch_smoothing"]
    for jn in names:
        sv = mesh.skin_vertices[0].data[index[jn]]
        sv.radius = (r[jn], r[jn])
        sv.use_root = jn == "hips"
    subdiv = obj.modifiers.new("Subdivision", "SUBSURF")
    subdiv.levels = manifest["subdivision"]
    subdiv.render_levels = manifest["subdivision"]
    bpy.ops.object.modifier_apply(modifier=skin.name)
    bpy.ops.object.modifier_apply(modifier=subdiv.name)
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.ops.object.shade_smooth()
    return obj


def add_eyes(body, params):
    """Two small eye spheres near the head, a second material slot the runtime
    tint never touches (it overrides surface 0, the hide). Joined into the
    body so they morph with it (bound to the head/snout edge)."""
    j = joints(params)
    hy, hz = j["head"][1], j["head"][2]
    sy = j["snout"][1]
    eye_y = hy + (sy - hy) * 0.45
    eye_z = hz + 0.035
    eyes = []
    for side_x in (-0.062, 0.062):
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=2, radius=0.021, location=(side_x, eye_y, eye_z))
        eyes.append(bpy.context.active_object)
    body_mat = bpy.data.materials.get("creature_body") or bpy.data.materials.new("creature_body")
    eye_mat = bpy.data.materials.get("creature_eye") or bpy.data.materials.new("creature_eye")
    if not body.data.materials:
        body.data.materials.append(body_mat)
    bpy.ops.object.select_all(action="DESELECT")
    body.select_set(True)
    for eye in eyes:
        eye.data.materials.append(eye_mat)
        eye.select_set(True)
    bpy.context.view_layer.objects.active = body
    bpy.ops.object.join()


def paint_materials(manifest):
    """Flat principled materials from the manifest colours (sRGB -> linear,
    the humanoid-kit convention). The body colour is the untinted base; the
    runtime overrides surface 0 with a shared per-tint material."""
    for mat_name, key, rough in (("creature_body", "body_color", 0.9), ("creature_eye", "eye_color", 0.35)):
        mat = bpy.data.materials[mat_name]
        mat.use_nodes = True
        bsdf = mat.node_tree.nodes.get("Principled BSDF")
        rgb = [srgb_to_linear(c) for c in manifest[key]]
        bsdf.inputs["Base Color"].default_value = (rgb[0], rgb[1], rgb[2], 1.0)
        bsdf.inputs["Roughness"].default_value = rough


def build_armature(params):
    """The canonical ash-hound skeleton, standing rest pose, one per archetype."""
    j = joints(params)
    arm = bpy.data.armatures.new("ash_hound_rig")
    arm_obj = bpy.data.objects.new("ash_hound_rig", arm)
    bpy.context.collection.objects.link(arm_obj)
    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.mode_set(mode="EDIT")
    for bone_name, head, tail, parent in BONES:
        eb = arm.edit_bones.new(bone_name)
        hx, hy, hz = j[head]
        tx, ty, tz = j[tail]
        if bone_name == "root":
            # Root sits at the hips pointing forward, a short handle bone the
            # whole creature hangs off (subtree-scale target for size variety).
            eb.head = (hx, hy, hz)
            eb.tail = (hx, hy + 0.12, hz)
        elif head == tail:
            # Foot bones end the graph; give the bone a short forward reach so
            # it has direction and length.
            eb.head = (hx, hy, hz)
            eb.tail = (hx, hy + 0.08, hz - 0.03)
        else:
            eb.head = (hx, hy, hz)
            eb.tail = (tx, ty, tz)
        if parent is not None:
            eb.parent = arm.edit_bones[parent]
    bpy.ops.object.mode_set(mode="OBJECT")
    return arm_obj


def skin_weights(obj, params):
    """Deterministic skinning: each vertex is weighted to its two nearest bone
    segments with inverse-square falloff, normalised. Pure arithmetic — no heat
    solve, nothing threaded, nothing version-fragile."""
    j = joints(params)
    segments = [(bone_name, Vector(j[head]), Vector(j[tail]))
                for bone_name, head, tail, _parent in BONES if bone_name != "root"]
    groups = {name: obj.vertex_groups.new(name=name) for name, _h, _t in segments}
    for v in obj.data.vertices:
        p = Vector(v.co)
        scored = sorted(((p - closest_on_edge(p, h, t)[1]).length, name) for name, h, t in segments)
        nearest = scored[:2]
        weights = [(name, 1.0 / (d + 0.02) ** 2) for d, name in nearest]
        total = sum(w for _n, w in weights)
        for name, w in weights:
            groups[name].add([v.index], w / total, "REPLACE")


def export_glb(out_path, objects):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    # No baked tangents: Blender's mikktspace pass is threaded and jitters a
    # couple of mantissa bits between runs, breaking byte-determinism (the
    # humanoid-kit lesson). Godot's importer generates tangents itself.
    bpy.ops.export_scene.gltf(
        filepath=out_path,
        use_selection=True,
        export_format="GLB",
        export_morph=True,
        export_morph_normal=True,
        export_skins=True,
        export_yup=True,
    )


def write_tints(manifest, out_dir):
    """The runtime tint registry: linear-space flat colours the CreatureFactory
    turns into one shared material per tint. Names are forward-only, exactly
    like the humanoid kit's blend shapes and skins."""
    index = {}
    for tint in manifest["tints"]:
        index[tint["name"]] = {"color": [round(srgb_to_linear(c), 6) for c in tint["color"]]}
    with open(os.path.join(out_dir, "tints.json"), "w", encoding="utf-8") as f:
        json.dump({
            "kit_version": manifest["kit_version"],
            "space": "linear",
            "tints": index,
        }, f, indent=2, sort_keys=True)
        f.write("\n")


def main() -> None:
    out_path = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else os.path.join(KIT_DIR, "ash_hound.glb")
    with open(os.path.join(KIT_DIR, "manifest.json"), encoding="utf-8") as f:
        manifest = json.load(f)

    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)

    base_params = manifest["base"]
    base_joints = joints(base_params)
    base_radii = radii(base_params)

    body = build_hide(manifest, base_params, "ash_hound")
    add_eyes(body, base_params)
    paint_materials(manifest)

    coords = [tuple(v.co) for v in body.data.vertices]
    bindings = bind_vertices(coords, base_joints, base_radii)
    body.shape_key_add(name="Basis")

    # Morphs by parametric reprojection of the fixed base topology: same
    # graph, morphed numbers -> same vertex count, guaranteed.
    for shape in manifest["shapes"]:
        params = dict(base_params)
        params.update(shape["params"])
        morphed = reproject(bindings, joints(params), radii(params), base_joints)
        kb = body.shape_key_add(name=shape["name"], from_mix=False)
        for i, co in enumerate(morphed):
            kb.data[i].co = co
        kb.value = 0.0

    arm_obj = build_armature(base_params)
    skin_weights(body, base_params)
    mod = body.modifiers.new("Armature", "ARMATURE")
    mod.object = arm_obj
    body.parent = arm_obj

    for kb in body.data.shape_keys.key_blocks:
        kb.value = 0.0

    export_glb(out_path, [body, arm_obj])

    out_dir = os.path.dirname(os.path.abspath(out_path))
    write_tints(manifest, out_dir)

    shape_names = [kb.name for kb in body.data.shape_keys.key_blocks[1:]]
    sha = hashlib.sha256(open(out_path, "rb").read()).hexdigest()
    # The structural report is the committed contract the Godot regression
    # test and the artgen workflow both check against; the GLB sha is printed
    # for run-to-run determinism checks but kept out of the report file (float
    # bit-exactness across OS/arch is not guaranteed, structure is).
    report_lines = [
        "kit_version=%d" % manifest["kit_version"],
        "archetype=%s" % manifest["archetype"],
        "verts=%d" % len(body.data.vertices),
        "bones=%d" % len(arm_obj.data.bones),
        "shapes=%s" % ",".join(shape_names),
        "tints=%s" % ",".join(tint["name"] for tint in manifest["tints"]),
    ]
    with open(os.path.splitext(out_path)[0] + "_report.txt", "w", encoding="utf-8") as f:
        f.write("\n".join(report_lines) + "\n")
    for line in report_lines:
        print("BAKE_REPORT " + line)
    print("BAKE_REPORT glb_sha256=%s size=%d" % (sha, os.path.getsize(out_path)))
    print("RESULT: SUCCESS")


try:
    main()
except Exception:
    traceback.print_exc()
    print("RESULT: FAILURE")
    sys.exit(1)
