"""Humanoid kit bake — character system stages 1+3 (issue #24).

Runs inside headless Blender with the MPFB extension installed (see
bootstrap.sh for the pinned install AND the pinned CC0 asset-pack downloads):

    blender --background --python bake.py -- /abs/output/humanoid_base.glb

Bakes the canonical humanoid from CC0 MakeHuman data (via MPFB, GPL tool —
tool never ships, output is ours per MPFB LICENSE.md sections C/D):
base body -> manifest shapes merged into named shape keys -> game_engine rig
-> equipment pieces (CC0 MHCLO) fitted, skinned to the same rig, refit under
every kit shape so clothes carry matching morphs -> helper geometry stripped
-> equip_hide_* body shapes from MHCLO delete_verts -> one body GLB plus one
GLB per equipment piece, and equipment/equipment.json for the runtime layer.

Deterministic by construction: everything is driven by manifest.json and the
pinned tool versions; the artgen workflow bakes twice and byte-compares, then
compares the structural report against the committed kit_report.txt.

This directory is the sanctioned Python/bpy exception (AGENTS.md, Scripting);
Python appears nowhere else in the repo.
"""
import hashlib
import importlib
import json
import math
import os
import sys
import traceback

import bpy

KIT_DIR = os.path.dirname(os.path.abspath(__file__))
PACKS_DIR = os.path.join(KIT_DIR, "packs")
# How far (metres) an equip_hide_* shape tucks covered body vertices inward
# along their normals — deep enough that animation never pokes skin through
# the garment, shallow enough to stay inside it.
HIDE_INSET = 0.012


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


def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def merge_macro_into_shape(mesh_obj, shape_name, macro_overrides, base, services):
    """Bake one gender/phenotype macro axis as a shape key: create a second
    human with that one macro pushed off the defaults, capture its vertices
    as an absolute-target key on the kit body, delete it. MakeHuman's macro
    system is an interpolation grid (gender x age x race x ...), not single
    target files — diffing whole humans uses MPFB's own macro math exactly."""
    HumanService, TargetService = services
    macro = TargetService.get_default_macro_info_dict()
    for key, value in macro_overrides.items():
        macro[key] = dict(value) if isinstance(value, dict) else value
    ref = HumanService.create_human(
        mask_helpers=base["mask_helpers"],
        detailed_helpers=base["detailed_helpers"],
        extra_vertex_groups=base["extra_vertex_groups"],
        feet_on_ground=base["feet_on_ground"],
        scale=base["scale"],
        macro_detail_dict=macro,
    )
    if ref.data.shape_keys is not None:
        TargetService.bake_targets(ref)
    if len(ref.data.vertices) != len(mesh_obj.data.vertices):
        raise RuntimeError(f"{shape_name}: macro reference has {len(ref.data.vertices)} verts, base has {len(mesh_obj.data.vertices)}")
    coords = [tuple(v.co) for v in ref.data.vertices]
    bpy.data.objects.remove(ref, do_unlink=True)
    kb = mesh_obj.shape_key_add(name=shape_name, from_mix=False)
    for i, co in enumerate(coords):
        kb.data[i].co = co
    kb.value = 0.0
    return kb


def parse_mhmat_diffuse(mhmat_path):
    """The piece's flat colour from its .mhmat (`diffuseColor r g b`). The
    full texture layer is a later stage; a flat albedo keeps the GLB small
    and the bake byte-deterministic."""
    if mhmat_path and os.path.isfile(mhmat_path):
        with open(mhmat_path, encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.split()
                if len(parts) == 4 and parts[0] == "diffuseColor":
                    return tuple(float(p) for p in parts[1:])
    return (0.8, 0.8, 0.8)


def capture_coords(clothes_obj):
    return [tuple(v.co) for v in clothes_obj.data.vertices]


def generated_cloth_images(piece, rgb):
    """Build deterministic woven albedo, roughness and normal textures.

    This is intentionally tiny and arithmetic: the weave needs to read as a
    named coarse cloth, not carry photographic detail. Packed images travel
    inside the GLB, so the generated artifact stays one-file and reproducible.
    """
    size = 128

    def new_image(suffix, non_color=False):
        image = bpy.data.images.new(f"{piece['name']}_{suffix}", width=size, height=size)
        if non_color:
            image.colorspace_settings.name = "Non-Color"
        return image

    albedo = new_image("albedo")
    roughness = new_image("roughness", True)
    normal = new_image("normal", True)
    albedo_pixels = []
    roughness_pixels = []
    normal_pixels = []
    for y in range(size):
        for x in range(size):
            # Two differently-spaced thread directions stop the surface
            # reading as a checkerboard. A low-frequency stain breaks the
            # otherwise-perfect repetition without any random state.
            warp = 0.07 if x % 8 < 2 else -0.025
            weft = 0.045 if y % 6 < 1 else -0.018
            stain = 0.94 + 0.04 * math.sin(x * 0.19 + y * 0.11) \
                + 0.025 * math.sin(x * 0.047 - y * 0.071)
            factor = max(0.72, min(1.08, stain + warp + weft))
            albedo_pixels.extend((rgb[0] * factor, rgb[1] * factor,
                                  rgb[2] * factor, 1.0))

            rough = 0.82 + 0.12 * (0.5 + 0.5 * math.sin(x * 0.61) * math.sin(y * 0.73))
            roughness_pixels.extend((rough, rough, rough, 1.0))

            nx = 0.5 + 0.10 * math.sin(2.0 * math.pi * x / 8.0)
            ny = 0.5 + 0.08 * math.sin(2.0 * math.pi * y / 6.0)
            normal_pixels.extend((nx, ny, 1.0, 1.0))

    albedo.pixels.foreach_set(albedo_pixels)
    roughness.pixels.foreach_set(roughness_pixels)
    normal.pixels.foreach_set(normal_pixels)
    for image in (albedo, roughness, normal):
        image.pack()
    return albedo, roughness, normal


def equipment_material(piece):
    """Build the shared material seam for generated and MHCLO gear."""
    srgb = tuple(piece["color"]) if "color" in piece else (0.8, 0.8, 0.8)
    rgb = tuple(srgb_to_linear(c) for c in srgb)
    mat = bpy.data.materials.new("equip_" + piece["name"])
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (rgb[0], rgb[1], rgb[2], 1.0)
    bsdf.inputs["Roughness"].default_value = float(piece.get("roughness", 0.85))

    texture_generator = piece.get("texture_generator")
    if texture_generator:
        if texture_generator != "coarse_cloth":
            raise RuntimeError(
                f"{piece['name']}: unknown material generator {texture_generator}")
        # Image pixels are authored in sRGB; the renderer performs the transfer
        # to linear. Passing the BSDF's already-linear fallback values here
        # would apply that transfer twice and crush the cloth nearly to black.
        albedo, roughness, normal = generated_cloth_images(piece, srgb)
        nodes = mat.node_tree.nodes
        links = mat.node_tree.links
        albedo_node = nodes.new("ShaderNodeTexImage")
        albedo_node.name = piece["name"] + "_albedo"
        albedo_node.image = albedo
        links.new(albedo_node.outputs["Color"], bsdf.inputs["Base Color"])
        roughness_node = nodes.new("ShaderNodeTexImage")
        roughness_node.name = piece["name"] + "_roughness"
        roughness_node.image = roughness
        links.new(roughness_node.outputs["Color"], bsdf.inputs["Roughness"])
        normal_node = nodes.new("ShaderNodeTexImage")
        normal_node.name = piece["name"] + "_normal"
        normal_node.image = normal
        normal_map = nodes.new("ShaderNodeNormalMap")
        normal_map.inputs["Strength"].default_value = 0.45
        links.new(normal_node.outputs["Color"], normal_map.inputs["Color"])
        links.new(normal_map.outputs["Normal"], bsdf.inputs["Normal"])
    return mat


def ragged_wrap_coords(scale=(1.0, 1.0, 1.0)):
    """Return a closed, low-poly scrap-of-cloth wrap around the pelvis.

    A thick elliptical belt holds separate front/back flaps. Coarse folds and
    an uneven hem change the silhouette in geometry, so the wear still reads
    at creator-portrait distance without relying on a texture.
    """
    sx, sy, sz = scale
    center_y = -0.018
    center_z = 0.86
    vertices = []
    faces = []

    def scaled(co):
        x, y, z = co
        return (x * sx, center_y + (y - center_y) * sy,
                center_z + (z - center_z) * sz)

    # Four belt rings (outer bottom/top, inner bottom/top) make a closed band
    # with visible top and bottom seams rather than an infinitely thin card.
    segments = 20
    for inner in (False, True):
        inset = 0.009 if inner else 0.0
        for z in (0.888, 0.940):
            for i in range(segments):
                angle = 2.0 * math.pi * i / segments
                x = (0.158 - inset) * math.cos(angle)
                radius_y = (0.116 if math.sin(angle) < 0.0 else 0.113) - inset
                y = center_y + radius_y * math.sin(angle)
                vertices.append(scaled((x, y, z)))
    outer_bottom, outer_top = 0, segments
    inner_bottom, inner_top = segments * 2, segments * 3
    for i in range(segments):
        j = (i + 1) % segments
        faces.extend([
            (outer_bottom + i, outer_bottom + j, outer_top + j, outer_top + i),
            (inner_bottom + j, inner_bottom + i, inner_top + i, inner_top + j),
            (outer_top + i, outer_top + j, inner_top + j, inner_top + i),
            (outer_bottom + j, outer_bottom + i, inner_bottom + i, inner_bottom + j),
        ])

    def add_flap(front):
        # Seven columns preserve three authored folds. Five rows taper from the
        # belt to the torn hem; the back flap is deliberately shorter.
        start = len(vertices)
        cols, rows = 7, 5
        top_z = 0.908
        base_bottom = 0.685 if front else 0.735
        top_width = 0.137 if front else 0.126
        bottom_width = 0.097 if front else 0.088
        hem = (0.020, -0.012, 0.009, -0.026, 0.015, -0.005, 0.024)
        # Close to skin by construction: ordinary trousers must cover this
        # base layer in depth as well as in registry order.
        outer_y = -0.119 if front else 0.086
        thickness = 0.008
        for inside in (False, True):
            for row in range(rows):
                t = row / (rows - 1)
                width = top_width * (1.0 - t) + bottom_width * t
                z = top_z * (1.0 - t) + base_bottom * t
                for col in range(cols):
                    u = col / (cols - 1)
                    x = -width + 2.0 * width * u
                    fold = (0.006 + 0.009 * t) * math.cos(u * 3.0 * math.pi)
                    y = outer_y + (-fold if front else fold)
                    if inside:
                        y += thickness if front else -thickness
                    ragged_z = z + (hem[col] * t if front else hem[6 - col] * t * 0.65)
                    vertices.append(scaled((x, y, ragged_z)))
        surface = cols * rows
        for side in (0, 1):
            offset = start + side * surface
            reverse = side == 1
            for row in range(rows - 1):
                for col in range(cols - 1):
                    a = offset + row * cols + col
                    b = a + 1
                    c = a + cols + 1
                    d = a + cols
                    faces.append((d, c, b, a) if reverse else (a, b, c, d))
        # Close every perimeter edge so side seams and hem have real thickness.
        outside = start
        inside = start + surface
        perimeter = list(range(cols))
        perimeter.extend(row * cols + cols - 1 for row in range(1, rows))
        perimeter.extend((rows - 1) * cols + col for col in range(cols - 2, -1, -1))
        perimeter.extend(row * cols for row in range(rows - 2, 0, -1))
        for p, q in zip(perimeter, perimeter[1:] + perimeter[:1]):
            faces.append((outside + p, outside + q, inside + q, inside + p))

    add_flap(True)
    add_flap(False)
    return vertices, faces


def pelvis_scale(mesh_obj, shape_name=None):
    """Measure one body morph around the pelvis and return xyz scale."""
    basis = mesh_obj.data.shape_keys.key_blocks["Basis"].data
    indices = [i for i, v in enumerate(basis)
               if 0.70 <= v.co.z <= 1.00 and abs(v.co.x) <= 0.24]
    target = mesh_obj.data.shape_keys.key_blocks[shape_name].data if shape_name else basis

    def extents(data):
        coords = [data[i].co for i in indices]
        return tuple(max(v[axis] for v in coords) - min(v[axis] for v in coords)
                     for axis in range(3))

    base_size = extents(basis)
    target_size = extents(target)
    return tuple(target_size[i] / base_size[i] if base_size[i] > 1e-9 else 1.0
                 for i in range(3))


def bake_ragged_wrap(piece, mesh_obj, rig_obj, shape_names):
    """Generate the permanent CC0 base garment and bind it to the kit rig."""
    coords, faces = ragged_wrap_coords()
    mesh = bpy.data.meshes.new(piece["name"])
    mesh.from_pydata(coords, [], faces)
    mesh.update()
    # A stable planar UV is part of the asset contract: Godot's importer
    # generates tangents for the material maps by default, and a mesh with no
    # UVs makes that otherwise-clean import emit an error.
    uv_layer = mesh.uv_layers.new(name="UVMap")
    for polygon in mesh.polygons:
        for loop_index in polygon.loop_indices:
            co = mesh.vertices[mesh.loops[loop_index].vertex_index].co
            uv_layer.data[loop_index].uv = ((co.x + 0.20) / 0.40,
                                             (co.z - 0.65) / 0.34)
    clothes = bpy.data.objects.new(piece["name"], mesh)
    bpy.context.collection.objects.link(clothes)
    clothes.data.materials.append(equipment_material(piece))

    # The belt follows the pelvis and its loose hem blends into both thighs.
    # Positive X is thigh_l in this rig.
    groups = {name: clothes.vertex_groups.new(name=name)
              for name in ("pelvis", "thigh_l", "thigh_r")}
    for vertex in mesh.vertices:
        pelvis_weight = max(0.2, min(1.0, (vertex.co.z - 0.70) / 0.19))
        groups["pelvis"].add([vertex.index], pelvis_weight, "REPLACE")
        remaining = 1.0 - pelvis_weight
        if remaining > 0.0:
            left = max(0.0, min(1.0, 0.5 + vertex.co.x / 0.24))
            groups["thigh_l"].add([vertex.index], remaining * left, "REPLACE")
            groups["thigh_r"].add([vertex.index], remaining * (1.0 - left), "REPLACE")
    armature = clothes.modifiers.new("Armature", "ARMATURE")
    armature.object = rig_obj

    clothes.shape_key_add(name="Basis")
    for shape_name in shape_names:
        shaped, shaped_faces = ragged_wrap_coords(pelvis_scale(mesh_obj, shape_name))
        if shaped_faces != faces or len(shaped) != len(mesh.vertices):
            raise RuntimeError(f"{piece['name']}: procedural morph changed topology")
        kb = clothes.shape_key_add(name=shape_name, from_mix=False)
        for i, co in enumerate(shaped):
            kb.data[i].co = co
        kb.value = 0.0

    # Generated garments have no MHCLO delete_verts, so create the equivalent
    # group from the exact body region the belt and flaps cover.
    hide = mesh_obj.vertex_groups.new(name=piece["hide_group"])
    hidden = []
    for vertex in mesh_obj.data.vertices:
        x, y, z = vertex.co
        under_belt = 0.88 <= z <= 0.945 and abs(x) <= 0.20
        under_flap = 0.68 <= z < 0.90 and abs(x) <= 0.14 and (y <= -0.075 or y >= 0.025)
        if under_belt or under_flap:
            hidden.append(vertex.index)
    if not hidden:
        raise RuntimeError(f"{piece['name']}: generated hide region selected no body vertices")
    hide.add(hidden, 1.0, "REPLACE")
    return clothes


def bake_equipment_piece(piece, mesh_obj, rig_obj, shape_names, services):
    """Fit one MHCLO piece to the body (helpers still present), skin it to
    the shared rig, and give it a blend shape per kit shape by refitting the
    garment under each morph — the runtime drives body and clothes with the
    same weights, so equipment follows the body."""
    if piece.get("generator") == "ragged_wrap":
        return bake_ragged_wrap(piece, mesh_obj, rig_obj, shape_names)
    if piece.get("generator"):
        raise RuntimeError(f"{piece['name']}: unknown equipment generator {piece['generator']}")

    HumanService, ClothesService, Mhclo = services
    mhclo_path = os.path.join(PACKS_DIR, piece["pack"], piece["mhclo"])
    if not os.path.isfile(mhclo_path):
        raise RuntimeError(f"{piece['name']}: {mhclo_path} missing — run bootstrap.sh")

    # material_type="NONE": strips the pack's MakeSkin material (textures are
    # a later stage); a flat principled material from the mhmat colour instead.
    clothes = HumanService.add_mhclo_asset(
        mhclo_path, mesh_obj, asset_type="Clothes", subdiv_levels=0, material_type="NONE")
    clothes.name = piece["name"]
    clothes.data.name = piece["name"]

    mhclo = Mhclo()
    mhclo.load(mhclo_path)
    mhclo.clothes = clothes

    # Manifest colour wins: pack mhmats mostly say white (their colour lives
    # in textures, which are a later stage) — the flat palette is authored
    # here, in the manifest, like everything else about the kit. Manifest
    # values are sRGB (what a colour picker shows); the BSDF wants linear.
    if "color" not in piece:
        piece = dict(piece, color=parse_mhmat_diffuse(mhclo.material))
    clothes.data.materials.append(equipment_material(piece))

    # Refit under each kit shape ONE at a time and capture the fitted verts;
    # shape keys are added only after every capture (fit_clothes_to_human
    # takes a slower edit-mode path once the garment has keys).
    key_blocks = mesh_obj.data.shape_keys.key_blocks
    captured = {}
    for shape_name in shape_names:
        key_blocks[shape_name].value = 1.0
        ClothesService.fit_clothes_to_human(clothes, mesh_obj, mhclo)
        captured[shape_name] = capture_coords(clothes)
        key_blocks[shape_name].value = 0.0
    ClothesService.fit_clothes_to_human(clothes, mesh_obj, mhclo)  # back to basis

    clothes.shape_key_add(name="Basis")
    for shape_name in shape_names:
        kb = clothes.shape_key_add(name=shape_name, from_mix=False)
        for i, co in enumerate(captured[shape_name]):
            kb.data[i].co = co
        kb.value = 0.0

    # Subdiv modifiers etc. would double geometry at export; keep armature only.
    for mod in list(clothes.modifiers):
        if mod.type != "ARMATURE":
            clothes.modifiers.remove(mod)
    return clothes


def parse_mhmat_texture(mhmat_path):
    """The diffuse texture file referenced by a .mhmat, resolved next to it."""
    with open(mhmat_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.split(None, 1)
            if len(parts) == 2 and parts[0] == "diffuseTexture":
                return os.path.join(os.path.dirname(mhmat_path), parts[1].strip())
    raise RuntimeError(f"{mhmat_path}: no diffuseTexture line")


def bake_skins(manifest, out_dir):
    """Downscale each manifest skin's diffuse texture (painted on the shared
    MakeHuman body UV) to the manifest size and write it plus the runtime
    registry. The runtime assigns skins per recipe; textures stay OUT of the
    body GLB so N skins do not mean N bodies."""
    skins = manifest.get("skins", [])
    if not skins:
        return {}
    skins_dir = os.path.join(out_dir, "skins")
    os.makedirs(skins_dir, exist_ok=True)
    size = manifest.get("skin_texture_size", 1024)
    index = {}
    for skin in skins:
        mhmat_path = os.path.join(PACKS_DIR, skin["pack"], skin["mhmat"])
        if not os.path.isfile(mhmat_path):
            raise RuntimeError(f"{skin['name']}: {mhmat_path} missing — run bootstrap.sh")
        image = bpy.data.images.load(parse_mhmat_texture(mhmat_path))
        image.scale(size, size)
        image.filepath_raw = os.path.join(skins_dir, skin["name"] + ".png")
        image.file_format = "PNG"
        image.save()
        bpy.data.images.remove(image)
        index[skin["name"]] = {"texture": skin["name"] + ".png"}
    with open(os.path.join(skins_dir, "skins.json"), "w", encoding="utf-8") as f:
        json.dump({
            "kit_version": manifest["kit_version"],
            "size": size,
            "skins": index,
        }, f, indent=2, sort_keys=True)
        f.write("\n")
    return index


def delete_group_name(piece):
    """Replicates add_mhclo_asset's naming for the delete group it leaves on
    the basemesh (the MHCLO delete_verts — body vertices the piece covers)."""
    if piece.get("hide_group"):
        return piece["hide_group"]
    base = os.path.basename(piece["mhclo"])
    return "Delete." + base.replace(".mhclo", "").replace(".MHCLO", "").replace(" ", "_")


def add_hide_shape(mesh_obj, group_name, shape_name):
    """Bake a body shape key that tucks every vertex of the delete group
    inward along its normal: setting it to 1.0 hides the skin the equipped
    piece covers (same shared-mesh trick as the morphs — per-instance weights,
    no runtime mesh surgery). Returns the number of vertices moved."""
    if group_name not in mesh_obj.vertex_groups:
        return 0
    group_index = mesh_obj.vertex_groups[group_name].index
    kb = mesh_obj.shape_key_add(name=shape_name, from_mix=False)
    kb.value = 0.0
    moved = 0
    for v in mesh_obj.data.vertices:
        if any(ge.group == group_index and ge.weight > 0.0 for ge in v.groups):
            kb.data[v.index].co = v.co - v.normal * HIDE_INSET
            moved += 1
    if moved == 0:
        mesh_obj.shape_key_remove(kb)
    return moved


def export_glb(out_path, objects):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
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

    # The module path depends on which extension repo MPFB was installed
    # into: extensions.blender.org installs land in blender_org, the pinned
    # bootstrap.sh install-file lands in user_default (CI).
    for module in ("bl_ext.user_default.mpfb", "bl_ext.blender_org.mpfb"):
        try:
            bpy.ops.preferences.addon_enable(module=module)
            break
        except Exception:
            continue
    else:
        raise RuntimeError("MPFB is not installed in any known extension repo — run bootstrap.sh")
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

    # Gender/phenotype axes append after the target shapes (names are the
    # forward-only API; order within the kit may shift between kit versions).
    for macro_shape in manifest.get("macro_shapes", []):
        merge_macro_into_shape(
            mesh_obj, macro_shape["name"], macro_shape["macro"], base, (HumanService, TargetService))

    rig_obj = HumanService.add_builtin_rig(mesh_obj, manifest["rig"])

    # Equipment fits against the body WITH helpers (MHCLO vertex matching
    # references the clothes-helper geometry), so pieces come before the strip.
    Mhclo = dynamic_import("mpfb.entities.clothes.mhclo", "Mhclo")
    ClothesService = dynamic_import("mpfb.services.clothesservice", "ClothesService")
    manifest_shape_names = [shape["name"] for shape in manifest["shapes"]] \
        + [macro_shape["name"] for macro_shape in manifest.get("macro_shapes", [])]
    pieces = []
    for piece in manifest.get("equipment", []):
        clothes = bake_equipment_piece(
            piece, mesh_obj, rig_obj, manifest_shape_names,
            (HumanService, ClothesService, Mhclo))
        pieces.append((piece, clothes))

    stripped = strip_vertex_groups(mesh_obj, manifest["strip_vertex_groups"])

    # The helper mask modifier is moot once helper vertices are gone, and
    # add_mhclo_asset leaves per-piece delete-group MASK modifiers; drop
    # every modifier except the armature so the export is exactly the skin.
    for mod in list(mesh_obj.modifiers):
        if mod.type != "ARMATURE":
            mesh_obj.modifiers.remove(mod)

    # equip_hide_* body shapes from the pieces' delete groups (post-strip so
    # vertex indices are final; group membership survives the delete).
    hidden_counts = {}
    for piece, _clothes in pieces:
        hidden_counts[piece["name"]] = add_hide_shape(
            mesh_obj, delete_group_name(piece), "equip_hide_" + piece["name"])

    for kb in mesh_obj.data.shape_keys.key_blocks:
        kb.value = 0.0
    mesh_obj.show_only_shape_key = False

    export_glb(out_path, [mesh_obj, rig_obj])

    equip_dir = os.path.join(os.path.dirname(os.path.abspath(out_path)), "equipment")
    os.makedirs(equip_dir, exist_ok=True)
    equipment_index = {}
    for piece, clothes in pieces:
        export_glb(os.path.join(equip_dir, piece["name"] + ".glb"), [clothes, rig_obj])
        entry = {
            "slot": piece["slot"],
            # Which of the two wearable layers this piece belongs to. `slot` is
            # the body REGION; `layer` is what sits over what there, so cloth
            # shoes and worn boots can share `feet` instead of evicting each
            # other. Required — a piece with no layer cannot be placed.
            "layer": piece["layer"],
            "scene": piece["name"] + ".glb",
        }
        if hidden_counts[piece["name"]] > 0:
            entry["hide_shape"] = "equip_hide_" + piece["name"]
        # Layers whose presence in the SAME region hides this piece — the
        # data-driven occlusion rule (eyewear under a helm, cloth shoes under
        # boots). Absent means "always renders when equipped".
        if piece.get("occluded_by"):
            entry["occluded_by"] = list(piece["occluded_by"])
        equipment_index[piece["name"]] = entry
    # The runtime registry: CharacterFactory composes from this, so its keys
    # are as forward-only as the shape names.
    with open(os.path.join(equip_dir, "equipment.json"), "w", encoding="utf-8") as f:
        json.dump({
            "kit_version": manifest["kit_version"],
            "slots": manifest.get("equipment_slots", []),
            "layers": manifest.get("equipment_layers", []),
            "base_pieces": manifest.get("base_pieces", []),
            "pieces": equipment_index,
        }, f, indent=2, sort_keys=True)
        f.write("\n")

    bake_skins(manifest, os.path.dirname(os.path.abspath(out_path)))

    shape_names = [kb.name for kb in mesh_obj.data.shape_keys.key_blocks[1:]]
    with open(out_path, "rb") as glb:
        sha = hashlib.sha256(glb.read()).hexdigest()
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
        "equipment=%s" % ",".join(piece["name"] for piece, _ in pieces),
        "skins=%s" % ",".join(skin["name"] for skin in manifest.get("skins", [])),
    ]
    for piece, clothes in pieces:
        report_lines.append("equip_%s=slot:%s,verts:%d,hidden:%d,shapes:%d" % (
            piece["name"], piece["slot"], len(clothes.data.vertices),
            hidden_counts[piece["name"]],
            len(clothes.data.shape_keys.key_blocks) - 1))
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
