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

## Tracked repository outputs

This manifest binds every non-Markdown file covered by this record to the exact bytes reviewed under
the source and licence chains above. The GLBs and skin PNGs map to the body, skin and equipment
sources named in the preceding sections. The ragged-loincloth material PNGs are the deterministic
first-party textures described with that piece. `kit_report.txt`, `equipment/equipment.json` and
`skins/skins.json` are first-party bake outputs/runtime registries from the committed inputs. Each
`.import` file is Godot's tracked importer metadata for its paired GLB or PNG and contains no
independently sourced art. `tools/provenance-guard.sh` verifies these checksums from Git's index, so
adding or replacing a covered file fails CI until this record is deliberately updated.

```text
9218c57b3fc628b0226463b2a8a84f50ec3db49da0ab7fce4ab01b0ce9fd0395  equipment/boots_worn.glb
1334028e21666739532c6a9405e60a10bfb42bdf5a3a838cfe69bf0343ccdb66  equipment/boots_worn.glb.import
09b6bc46a957a32672c1986c0132086962c83c152e0c0fee2b0db0cc3c478d93  equipment/equipment.json
b0bce5c38469b887bf85eaee6fba351a9c957837a0d0323d3a446964167eba39  equipment/loincloth_ragged.glb
e4c3ad324a60b93225a8d940667d3bf7a5872e5e43e64feb68d5c41952bf7216  equipment/loincloth_ragged.glb.import
b37dce4df5ef58700c0bcc4e8f7ddcad3341bfc2868c4cce4bf9291432299d15  equipment/loincloth_ragged_loincloth_ragged_albedo.png
3efa1a15bf801f754e4319a1370479c7b85b14e2eb9a79e19114e8b703dd129d  equipment/loincloth_ragged_loincloth_ragged_albedo.png.import
ad9ab5308b7b7fa97eb229a62c15f9c10962b0ab1833affdb31ba30ed796d7e1  equipment/loincloth_ragged_loincloth_ragged_normal.png
983c8c297412a45447dac087d059ab40d3062e727e9ef74abe1b0a8d953b6edd  equipment/loincloth_ragged_loincloth_ragged_normal.png.import
c897134244e5208d01c883094fb2cb03c4165e2d8dccaa3e2c280e6209ba5741  equipment/loincloth_ragged_loincloth_ragged_roughness.png
fcc8717c8cb0514269b64922f6fe6fa0728443afaf2b9dabc714e86c1d0414a4  equipment/loincloth_ragged_loincloth_ragged_roughness.png.import
af0a9c91dddfb981a283c7ee94661baab7112c0594ea3ffb20d2187d8acc58be  equipment/pants_wool.glb
9f1054ed978985a98f72e4155182a05c765b614fc3e634a9bde9b8736e165fc8  equipment/pants_wool.glb.import
d99aea1a543900ca28711183005f726902ef1e69c552a05091804a6f1d6c3ac9  equipment/shirt_ragged.glb
df089d0a11668b03759603f5be1f72fe5deeb0233bd9bf33e2333af23de6fe13  equipment/shirt_ragged.glb.import
d36a2cfa7159b8bee548c2fa107cbfce82e8ae98a80cc053918ccfdc768da62d  equipment/shoes_cloth.glb
5b48bbccab33f47758748b950026795e6044c6d94f461d20aa8fb78b57e0ae10  equipment/shoes_cloth.glb.import
51cf634de80f34f4650880ccf43eb98b83cedc14f918db17baa299a0a4ff1538  humanoid_base.glb
49a83c611e575377fb52f68c2121c6d8488481a5996ae275a61183f506ca018d  humanoid_base.glb.import
776470f0e4e2794cb7fec071506052a6bf2d59003e361b9cdd35024d91a31de0  kit_report.txt
300c087e4957efdffce83954fe7b3eb07894f63c9ba5e4bb6994346bbe9d6a04  skins/skin_female_aged.png
7cb93110da0b9c7e21fff9159856181cdea3822240a4b25363084fb1e5796bea  skins/skin_female_aged.png.import
ab9e330fc71a8910795cbea02235d197c71519062477e8ef1606df79179d0794  skins/skin_female_light.png
ab129ae68cf0fb9cc2e4bf7c8f310252b74864a9c634d49e5d9452b1bb3a77a3  skins/skin_female_light.png.import
854dbeac813ea0822324264a10dcfdd0be045d4b0e02497e43286c95e049be37  skins/skin_female_mid.png
4bc004487b0efffe0fc44f74e051300a14abbc52dc3b1e7fe17f6ff80c9755ee  skins/skin_female_mid.png.import
fb697014d35c7e08d602e709bd1a9c71960e7e0c444f1013e3cef51867153d66  skins/skin_male_aged.png
4b4a2955adad918aedb3d673e5f08c66d2aa2ee220214961919691529c373145  skins/skin_male_aged.png.import
c9b03eed714890b7999317b29f4230e3b276c1ddaa5044cba37a851ad3bb23a3  skins/skin_male_deep.png
e2ec885a0cd728016eb5418666ad7609771069f8429803650c8a48ba0dfe39ce  skins/skin_male_deep.png.import
0f64d85b52c6003102f4258255a02324e18ba54fe2c5135b38789272319a8480  skins/skin_male_light.png
30048b02ad954aa6ca69adc035f79edd1c96858493f5a9f371861442731cebb9  skins/skin_male_light.png.import
1948ffe9656a756ad3493ca4ce06a632c1340b92968c25ede8f3049389b577be  skins/skins.json
```
