"""Humanoid kit bake — character system stage 1 (issue #24).

Runs inside headless Blender with the MPFB extension installed (see
bootstrap.sh for the pinned install):

    blender --background --python bake.py -- /abs/output/humanoid_base.glb

Bakes the canonical humanoid from CC0 MakeHuman data (via MPFB, GPL tool —
tool never ships, output is ours per MPFB LICENSE.md sections C/D):
base body -> manifest shapes merged into named shape keys -> game_engine rig
-> helper geometry stripped -> one GLB with named morph targets.

Deterministic by construction: everything is driven by manifest.json and the
pinned tool versions; the artgen workflow bakes twice and byte-compares, then
compares the structural report against the committed kit_report.txt.

This directory is the sanctioned Python/bpy exception (AGENTS.md, Scripting);
Python appears nowhere else in the repo.
"""
import hashlib
import importlib
import json
import os
import sys
import traceback

import bpy

KIT_DIR = os.path.dirname(os.path.abspath(__file__))


def dynamic_import(package_suffix: str, key: str):
    """Resolve an MPFB service class regardless of the extension mount point
    (bl_ext.blender_org.mpfb.*) — the official pattern from MPFB's own
    script_samples."""
    for module_name in list(sys.modules):
        if module_name.endswith(package_suffix):
            return getattr(importlib.import_module(module_name), key)
    raise ValueError(f"No loaded module ends in {package_suffix} — is MPFB installed?")


def merge_targets_into_shape(mesh_obj, shape_name: str, target_paths, targets_root, target_service):
    """Load one or more MakeHuman .target files and collapse them into a
    single named shape key (l/r pairs and muscle groups become one axis)."""
    basis = mesh_obj.data.shape_keys.key_blocks[0]
    before = {kb.name for kb in mesh_obj.data.shape_keys.key_blocks}
    for rel in target_paths:
        target_service.load_target(mesh_obj, os.path.join(targets_root, rel), weight=1.0)
    loaded = [kb for kb in mesh_obj.data.shape_keys.key_blocks if kb.name not in before]
    if len(loaded) != len(target_paths):
        raise RuntimeError(f"{shape_name}: expected {len(target_paths)} loaded targets, got {len(loaded)}")
    for kb in loaded:
        kb.value = 1.0
    merged = mesh_obj.shape_key_add(name=shape_name, from_mix=True)
    merged.value = 0.0
    for kb in loaded:
        mesh_obj.shape_key_remove(kb)
    return merged


def strip_vertex_groups(mesh_obj, group_names):
    """Delete every vertex weighted to the named groups (helper geometry and
    joint cubes). Shape keys and skin weights on surviving vertices are
    preserved by Blender across the delete."""
    indices = {mesh_obj.vertex_groups[g].index for g in group_names if g in mesh_obj.vertex_groups}
    if not indices:
        raise RuntimeError(f"none of the strip groups {group_names} exist")
    doomed = [v.index for v in mesh_obj.data.vertices
              if any(ge.group in indices and ge.weight > 0.0 for ge in v.groups)]
    bpy.context.view_layer.objects.active = mesh_obj
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="DESELECT")
    bpy.ops.object.mode_set(mode="OBJECT")
    for i in doomed:
        mesh_obj.data.vertices[i].select = True
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.delete(type="VERT")
    bpy.ops.object.mode_set(mode="OBJECT")
    return len(doomed)


def main() -> None:
    out_path = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else os.path.join(KIT_DIR, "humanoid_base.glb")
    with open(os.path.join(KIT_DIR, "manifest.json"), encoding="utf-8") as f:
        manifest = json.load(f)

    bpy.ops.preferences.addon_enable(module="bl_ext.blender_org.mpfb")
    HumanService = dynamic_import("mpfb.services.humanservice", "HumanService")
    TargetService = dynamic_import("mpfb.services.targetservice", "TargetService")
    LocationService = dynamic_import("mpfb.services.locationservice", "LocationService")
    targets_root = LocationService.get_mpfb_data("targets")

    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)

    base = manifest["base"]
    mesh_obj = HumanService.create_human(
        mask_helpers=base["mask_helpers"],
        detailed_helpers=base["detailed_helpers"],
        extra_vertex_groups=base["extra_vertex_groups"],
        feet_on_ground=base["feet_on_ground"],
        scale=base["scale"],
        macro_detail_dict=base["macro_detail_dict"],
    )
    # create_human leaves MPFB's macro-phenotype shape keys ($md-...) on the
    # mesh; bake them into the base so the kit ships ONLY the manifest shapes.
    if mesh_obj.data.shape_keys is not None:
        TargetService.bake_targets(mesh_obj)
    mesh_obj.shape_key_add(name="Basis")

    for shape in manifest["shapes"]:
        merge_targets_into_shape(mesh_obj, shape["name"], shape["targets"], targets_root, TargetService)

    rig_obj = HumanService.add_builtin_rig(mesh_obj, manifest["rig"])

    stripped = strip_vertex_groups(mesh_obj, manifest["strip_vertex_groups"])

    # The helper mask modifier is moot once helper vertices are gone; drop
    # every modifier except the armature so the export is exactly the skin.
    for mod in list(mesh_obj.modifiers):
        if mod.type != "ARMATURE":
            mesh_obj.modifiers.remove(mod)

    for kb in mesh_obj.data.shape_keys.key_blocks:
        kb.value = 0.0
    mesh_obj.show_only_shape_key = False

    bpy.ops.object.select_all(action="DESELECT")
    mesh_obj.select_set(True)
    rig_obj.select_set(True)
    # No baked tangents: Blender's mikktspace pass is threaded and jitters a
    # couple of mantissa bits between runs, breaking byte-determinism. Godot's
    # importer generates tangents itself (ensure_tangents default), same for
    # base and morph geometry.
    bpy.ops.export_scene.gltf(
        filepath=out_path,
        use_selection=True,
        export_format="GLB",
        export_morph=True,
        export_morph_normal=True,
        export_skins=True,
        export_yup=True,
    )

    shape_names = [kb.name for kb in mesh_obj.data.shape_keys.key_blocks[1:]]
    sha = hashlib.sha256(open(out_path, "rb").read()).hexdigest()
    # The structural report is the committed contract the Godot regression
    # test and the artgen workflow both check against. The GLB sha is printed
    # for run-to-run determinism checks but kept out of the report file:
    # float bit-exactness across OS/arch is not guaranteed, structure is.
    report_lines = [
        "kit_version=%d" % manifest["kit_version"],
        "verts=%d" % len(mesh_obj.data.vertices),
        "stripped=%d" % stripped,
        "bones=%d" % len(rig_obj.data.bones),
        "shapes=%s" % ",".join(shape_names),
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
