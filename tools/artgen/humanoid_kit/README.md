# Humanoid kit bake — character system stages 1+3

The offline half of the character system ([#24](https://github.com/devantler-tech/world-at-ruin/issues/24)):
headless Blender + MPFB bakes the **canonical humanoid** — one base body, the `game_engine` rig
(53 deform bones) and the manifest's morph shapes as named glTF blend shapes — plus the
**equipment pieces**: CC0 MHCLO clothes fitted to the body plus deterministic garments generated
from the same CC0 body, all skinned to the same rig, fitted under every kit shape, and exported one
GLB per piece with a runtime registry (`equipment/equipment.json`). MHCLO `delete_verts` and
generated coverage regions become `equip_hide_*` body shapes that tuck covered skin inward (no
runtime mesh surgery, shared-mesh friendly). Generated garments may also carry deterministic
embedded material maps; the ragged base uses woven albedo, roughness and normal maps. The
committed artifact lives at `client/assets/characters/humanoid_kit/` and is consumed by the
in-engine composition layer (stage 2+).

This directory is the repo's **sanctioned Python/bpy exception** (AGENTS.md → Scripting): Python
exists here and nowhere else, because Blender's only scripting surface is Python.

## Licence posture

- **Blender (GPL) and MPFB (GPLv3) are tools, never shipped and never committed** — `bootstrap.sh`
  downloads MPFB pinned by sha256; CI downloads its own pinned Blender. Nothing GPL enters the tree.
- **Everything baked is CC0-derived and ours**: MPFB's `LICENSE.md` §C places the base mesh,
  targets/modifiers and rigs under CC0 1.0, and §D disclaims all output ("We regard these things
  as your data"). Full provenance in the kit's committed `PROVENANCE.md`.
- **Policy: CC0-labelled asset packs only** when later stages add clothes/hair/skins; CC-BY packs
  and the uncurated user repo are excluded.

## Determinism (product law)

`manifest.json` is the single source of truth — base parameters, rig, strip list, ordered shape
list, and both downloaded and generated equipment. Same manifest + pinned tools ⇒ **byte-identical
GLB** (verified by baking twice in the
artgen workflow; exporter tangents are deliberately off because Blender's threaded mikktspace pass
jitters mantissa bits — Godot's importer generates tangents deterministically instead). Shape
names are the stable public API for recipes: **never rename or remove a shipped shape, only add**
(no-resets law).

## Usage

This optional pipeline regenerates art; it is not needed to play the game or make a documentation
change. Run from the **repository root** with Blender **5.2.0 LTS** available as `blender`, plus
`curl`, `jq`, `unzip`, and either `sha256sum` or `shasum`. Bootstrap verifies its pinned downloads,
installs MPFB into your local Blender `user_default` extension repository, and downloads the
ignored input packs into this kit directory. Review those local changes before running it.

```sh
tools/artgen/humanoid_kit/bootstrap.sh
mkdir -p build/humanoid-kit-check
war_bake_dir=$(mktemp -d "${PWD}/build/humanoid-kit-check/run.XXXXXX")
mkdir "$war_bake_dir/a" "$war_bake_dir/b"
blender --background --python tools/artgen/humanoid_kit/bake.py -- "$war_bake_dir/a/humanoid_base.glb"
blender --background --python tools/artgen/humanoid_kit/bake.py -- "$war_bake_dir/b/humanoid_base.glb"
diff -r "$war_bake_dir/a" "$war_bake_dir/b"
```

Each bake must finish with `RESULT: SUCCESS`; the recursive comparison must exit zero without
differences. A missing prerequisite, failed download, bake error, or difference is a failure to
investigate, not a reason to copy partial output. The unique directory gives each comparison fresh
outputs, so an older file cannot survive into both bakes and hide a removed or renamed artifact.

The bake writes `humanoid_base.glb`, `humanoid_base_report.txt`, the `equipment/` GLBs and
`equipment.json`, and the `skins/` textures and `skins.json`. To update the committed kit, transfer
the **complete generated output** into `client/assets/characters/humanoid_kit/`, renaming the report
to `kit_report.txt`. Compare the fresh output's file inventory with the tracked baked files:
remove obsolete generated assets and their `.import` sidecars in the same change, including removed
or renamed equipment and skins. Preserve existing Godot texture import sidecars only for assets
that still exist in the fresh bake; preserve authored `PROVENANCE.md` and other documentation.
Do not use a whole-directory replacement that deletes those authored files. Review the whole diff,
including both registries and their provenance checksums. Ship regenerated files with the manifest
change that caused them; never hand-edit generated assets or registries. The artgen workflow checks
the repeated bake, report, and both registries, while client CI checks importing and using the kit.

Pinned toolchain: Blender **5.2.0 LTS**, MPFB **2.0.16**
(sha256 `b5cdc8b08147e0c6463e4faa01147491b13a0b062f73415363f029debd11c934`).
