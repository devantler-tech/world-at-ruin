# Provenance — humanoid kit (baked)

The canonical humanoid for the character system
([#24](https://github.com/devantler-tech/world-at-ruin/issues/24)): base body, `game_engine` rig
(53 deform bones) and 21 named morph shapes, **baked entirely by committed code** —
`tools/artgen/humanoid_kit/bake.py` driven by `manifest.json`, reproducible byte-for-byte with
the pinned toolchain. `kit_report.txt` is the structural contract checked by the
`humanoid_kit_test` regression test and the artgen workflow.

- **Derived from:** MakeHuman CC0 assets (base mesh, morph targets, rigs) as bundled by
  **MPFB 2.0.16** (sha256 `b5cdc8b08147e0c6463e4faa01147491b13a0b062f73415363f029debd11c934`,
  extensions.blender.org), baked with **Blender 5.2.0 LTS**.
- **Licence of the source data:** CC0 1.0 Universal — MPFB `LICENSE.md` §C explicitly covers
  "The base mesh and proxies; Targets and modifiers; Textures; Clothes; **Rigs**, poses and
  expressions" (<https://github.com/makehumancommunity/mpfb2/blob/master/LICENSE.md>), full text
  in `LICENSE.ASSETS.md`. Verified 2026-07-17.
- **Licence of the output:** ours. MPFB `LICENSE.md` §D: "the MakeHuman team makes no claim
  whatsoever over output … We regard these things as your data." The GPL covers the tools
  (Blender, MPFB), which are downloaded at bake time and never enter this tree.
- **Baked:** 2026-07-17 on macOS; GLB sha256
  `f6e0611b21324f7a729f71576dd3cf469e93a28fc84bc66444c96b067f71bdc8` (2 521 388 bytes).
  Regenerate with the commands in `tools/artgen/humanoid_kit/README.md`.
