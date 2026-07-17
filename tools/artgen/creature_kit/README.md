# Creature kit bake — creature system pilot

The offline half of the creature system ([#24](https://github.com/devantler-tech/world-at-ruin/issues/24),
final stage): headless Blender bakes the **ash hound** — the first non-humanoid archetype, a
quadruped scavenger — as one 20-bone rig, the manifest's morph shapes as named glTF blend shapes,
and a small tint palette. The committed artifact lives at
`client/assets/characters/creature_kit/` and is consumed by the in-engine composition layer
(`CreatureFactory`).

This shares `tools/artgen/`'s **sanctioned Python/bpy exception** (AGENTS.md → Scripting): Python
exists here and nowhere else, because Blender's only scripting surface is Python.

## Authored from primitives — no external assets

Unlike the humanoid kit (which bakes CC0 MakeHuman data via MPFB), MPFB/MakeHuman is a *humanoid*
system with no parametric quadruped, and no adoptable CC0 parametric-creature system exists
(verified in #24). So the hound is **originated here as code**: a hand-authored joint graph run
through Blender's **skin modifier** + subdivision, positions and radii driven entirely by
`manifest.json`. There is no third-party mesh, texture, or asset in the chain — the output is ours
outright. Blender (GPL) is a tool, downloaded at bake time, never committed.

## Topology & morphs

The joint graph keeps every torso joint at **valence ≤ 3** (a `shoulder`/`pelvis` hub carries the
front/rear legs), because a skin-modifier joint above valence 3 sprouts a loose flap on the
topline. The base hide is built once (fixed topology); **morphs are parametric reprojections** of
each bound vertex through the morphed joint graph (LBS-style, with radius scaling), so a girth
change never rebuilds the hull and every morph keeps the base vertex count.

## Determinism (product law)

`manifest.json` is the single source of truth. Same manifest + pinned Blender ⇒ **byte-identical
GLB** (verified by baking twice in the artgen workflow; exporter tangents are off because Blender's
threaded mikktspace pass jitters mantissa bits — Godot's importer generates tangents
deterministically instead). Shape and tint names are the stable public API for recipes: **never
rename or remove a shipped shape/tint, only add** (no-resets law).

## Usage

```sh
# No bootstrap — the creature kit needs only Blender (no MPFB, no asset packs).
blender --background --python bake.py -- /abs/path/ash_hound.glb
```

The bake prints `BAKE_REPORT` lines and writes `ash_hound_report.txt` + `tints.json` next to the
GLB. To update the committed kit: run the bake, copy the GLB, report and `tints.json` into
`client/assets/characters/creature_kit/`, and ship them in the same PR as the manifest change that
caused them.

Pinned toolchain: Blender **5.2.0 LTS**.
