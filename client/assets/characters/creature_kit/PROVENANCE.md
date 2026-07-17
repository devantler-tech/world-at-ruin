# Provenance — creature kit (baked)

The first non-humanoid archetype for the creature system pilot
([#24](https://github.com/devantler-tech/world-at-ruin/issues/24), final stage): the **ash hound**,
a quadruped scavenger — canonical 20-bone rig, 6 named morph shapes
(`body_heavy`, `body_gaunt`, `legs_long`, `snout_long`, `ears_alert`, `tail_high`) and a
4-colour tint palette — **baked entirely by committed code**,
`tools/artgen/creature_kit/bake.py` driven by `manifest.json`, reproducible byte-for-byte with the
pinned toolchain. `ash_hound_report.txt` is the structural contract checked by the
`creature_kit_test` regression test and the artgen workflow; `tints.json` is the runtime registry
`CreatureFactory` composes from.

- **Authored from:** nothing external. The hound is generated from a hand-authored joint graph run
  through Blender's **skin modifier** + subdivision — positions and radii come entirely from
  `manifest.json`, so there is **no third-party mesh, texture, or asset of any kind** in the source
  chain. Morph shapes are parametric reprojections of the base topology through the same graph, so
  every morph keeps the base vertex count.
- **Licence of the source data:** none needed — the geometry is originated here, wholly ours.
- **Licence of the output:** ours, outright. The GPL covers the tool (Blender), which is downloaded
  at bake time and never enters this tree; the output is not a derivative of any GPL asset.
- **Baked:** 2026-07-17 on macOS with **Blender 5.2.0 LTS**; GLB sha256
  `a9232db50ce6108b3cded6496c3f5595fbf4d0055756d3342b9ad17b4a5d770c` (474 572 bytes).
  Regenerate with the commands in `tools/artgen/creature_kit/README.md`.
- **Why a quadruped from primitives, not MPFB:** MPFB/MakeHuman is a *humanoid* system — it has no
  parametric quadruped. No adoptable CC0 parametric-creature system exists (verified in #24). So the
  pilot proves the same pipeline shape (bake → committed GLB → runtime factory with versioned,
  name-keyed, forward-only recipes → seeded spawns) works for a non-humanoid by originating the mesh
  as code. Later archetypes reuse this machinery, one canonical skeleton per archetype.
