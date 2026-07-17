# Provenance — humanoid kit (baked)

The canonical humanoid for the character system
([#24](https://github.com/devantler-tech/world-at-ruin/issues/24)): base body, `game_engine` rig
(53 deform bones), 21 named morph shapes + 3 `equip_hide_*` shapes, and four skinned equipment
pieces under `equipment/`, **baked entirely by committed code** —
`tools/artgen/humanoid_kit/bake.py` driven by `manifest.json`, reproducible byte-for-byte with
the pinned toolchain. `kit_report.txt` is the structural contract checked by the
`humanoid_kit_test` regression test and the artgen workflow; `equipment/equipment.json` is the
runtime registry `CharacterFactory` composes from.

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
- **Baked:** 2026-07-17 on macOS; body GLB sha256
  `09e0bad05461213c8dd59badbb40bc41221f18e73ddc3be03bb3ea49aa9f473f` (2 780 372 bytes).
  Regenerate with the commands in `tools/artgen/humanoid_kit/README.md`.

## Equipment pieces (`equipment/*.glb`)

MHCLO clothes from the **official MakeHuman 01-series CC0 asset packs** — the `_cc0.zip`
variants, which contain only CC0-licensed assets (the CC-BY variants are policy-excluded;
AGENTS.md licensing). Downloaded pinned + checksummed by `tools/artgen/humanoid_kit/bootstrap.sh`;
each `.mhclo` header declares `license CC0` (verified per piece 2026-07-17). Fitted, skinned to
the kit rig and re-exported by the bake; the packs' MakeSkin textures are deliberately not used
(flat `diffuseColor` materials — the texture layer is a later stage of #24).

Source packs (files.makehumancommunity.org/asset_packs/):

| pack | zip sha256 |
|---|---|
| `shirts01_cc0.zip` | `a5a723b0e84a109bb190fcfeac7f1de4138d875da3e30fe5b3340eac9f38bcd3` |
| `pants01_cc0.zip` | `e4e0ec60db34f279be291a83cfd7b342a7c5cf09bb7676682a5f39f4f6ac4ad9` |
| `shoes01_cc0.zip` | `ded3f70428505eabbf1f6d7b5f61196a7366ef20757103d276ad0ed336c35ada` |

Pieces (author attributions are courtesy — CC0 requires none):

| piece | source `.mhclo` | author | licence |
|---|---|---|---|
| `shirt_ragged` | shirts01 `elvs_crude_t-shirt_male` | MakeHuman team, edited by Elvaerwyn | CC0 |
| `pants_wool` | pants01 `toigo_wool_pants` | MRT | CC0 |
| `shoes_cloth` | shoes01 `toigo_mj_cloth_shoes` | MRT | CC0 |
| `boots_worn` | shoes01 `culturalibre_male_boots` | culturalibre | CC0 |
