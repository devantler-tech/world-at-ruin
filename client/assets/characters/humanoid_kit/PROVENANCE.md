# Provenance — humanoid kit (baked)

The canonical humanoid for the character system
([#24](https://github.com/devantler-tech/world-at-ruin/issues/24)): base body, `game_engine` rig
(53 deform bones), 29 named morph shapes (21 targets + 8 gender/phenotype macro axes) + 4
`equip_hide_*` shapes, and five skinned equipment pieces under `equipment/`, **baked entirely by
committed code** —
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
- **Baked:** 2026-07-21 on macOS; body GLB sha256
  `51cf634de80f34f4650880ccf43eb98b83cedc14f918db17baa299a0a4ff1538` (5 234 252 bytes).
  Regenerate with the commands in `tools/artgen/humanoid_kit/README.md`.
- **Macro axes** (`body_female`, `body_male`, `body_aged`, `body_heavy`, `body_slim`,
  `phenotype_african`, `phenotype_asian`, `phenotype_caucasian`) are diffed from second MPFB
  humans with one macro pushed off the defaults — same CC0 MakeHuman macro-target data, same
  licence chain. The phenotype axes are whole-body morphs (the macro grid is full-body), each
  re-grounded at the feet.

## Skins (`skins/*.png`)

Diffuse body textures from the **official CC0 skins packs** (release note 2023-05-20: "New CC0
skins packs", the `_cc0.zip` variants), painted on the shared MakeHuman body UV, downscaled to
1024² by the bake and registered in `skins/skins.json`. Makeup/tattoo/anatomical variants are
deliberately excluded. Source packs: `skins01_cc0.zip` (sha256
`7495ab99287053bd19ff1636114e64b608994d9f7437fea6cc75ea387f96dba9`), `skins02_cc0.zip` (sha256
`1613f1ef3afca53094511d26620ed7cf1d2dedc29ed3d384d60bdebe250698ae`).

| skin | source | author | licence |
|---|---|---|---|
| `skin_female_light` | skins01 `bobby_03_young_female_hairless` | bobby_03 | CC0 |
| `skin_female_mid` | skins01 `callharvey3d_midtoned_female` | callharvey3d | CC0 |
| `skin_female_aged` | skins01 `onlytheghosts_old_eurasian_female` | onlytheghosts | CC0 |
| `skin_male_light` | skins02 `toigo_light_skin_male_bronze` | toigo | CC0 |
| `skin_male_deep` | skins02 `mindfront_skin_male_african_middleage` | mindfront | CC0 |
| `skin_male_aged` | skins02 `onlytheghosts_old_eurasian_male` | onlytheghosts | CC0 |

## Equipment pieces (`equipment/*.glb`)

`loincloth_ragged` is generated deterministically by `bake.py` from authored dimensions around the
CC0 MakeHuman pelvis. It is a closed 220-vertex garment with a thick stitched belt, separate folded
front/back flaps, an asymmetrical torn hem, pelvis/thigh skin weights, and one fitted shape for each
of the kit's 29 body morphs. The bake also generates and embeds its 128² woven albedo, roughness and
normal maps from deterministic arithmetic. Its body-tuck coverage is generated beside the mesh
rather than coming from an MHCLO `delete_verts` declaration. The source geometry and rig remain the
CC0 MakeHuman data covered above; no additional downloaded asset enters its licence chain. Baked GLB
sha256: `b0bce5c38469b887bf85eaee6fba351a9c957837a0d0323d3a446964167eba39` (355 968 bytes).

The remaining pieces are MHCLO clothes from the **official MakeHuman 01-series CC0 asset packs**.

Those packs use the `_cc0.zip`
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

| piece | source | author | licence |
|---|---|---|---|
| `loincloth_ragged` | generated from the MakeHuman basemesh | devantler-tech | CC0-derived |
| `shirt_ragged` | shirts01 `elvs_crude_t-shirt_male` | MakeHuman team, edited by Elvaerwyn | CC0 |
| `pants_wool` | pants01 `toigo_wool_pants` | MRT | CC0 |
| `shoes_cloth` | shoes01 `toigo_mj_cloth_shoes` | MRT | CC0 |
| `boots_worn` | shoes01 `culturalibre_male_boots` | culturalibre | CC0 |
