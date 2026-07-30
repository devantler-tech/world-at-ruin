# Provenance — humanoid kit (baked)

The canonical humanoid for the character system
([#24](https://github.com/devantler-tech/world-at-ruin/issues/24)): base body, `game_engine` rig
(53 deform bones), 29 named morph shapes (21 targets + 8 gender/phenotype macro axes) + 5
`equip_hide_*` shapes, and eight skinned equipment pieces under `equipment/`, **baked entirely by
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
- **Baked:** 2026-07-29 on macOS; body GLB sha256
  `af7b82fb2b1a22b54e994460cc01979cf64c3aa8c8dd50229ccac2736de558ff` (5 377 088 bytes).
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

The remaining pieces are MHCLO clothes from the **official MakeHuman CC0 asset packs**.

Those packs use the `_cc0.zip`
variants, which contain only CC0-licensed assets (the CC-BY variants are policy-excluded;
AGENTS.md licensing). Downloaded pinned + checksummed by `tools/artgen/humanoid_kit/bootstrap.sh`;
each `.mhclo` header declares `license CC0` (verified per piece through 2026-07-29). Fitted, skinned to
the kit rig and re-exported by the bake; the packs' MakeSkin textures are deliberately not used
(flat `diffuseColor` materials — the texture layer is a later stage of #24).

Source packs (files.makehumancommunity.org/asset_packs/):

| pack | zip sha256 |
|---|---|
| `shirts01_cc0.zip` | `a5a723b0e84a109bb190fcfeac7f1de4138d875da3e30fe5b3340eac9f38bcd3` |
| `pants01_cc0.zip` | `e4e0ec60db34f279be291a83cfd7b342a7c5cf09bb7676682a5f39f4f6ac4ad9` |
| `shoes01_cc0.zip` | `ded3f70428505eabbf1f6d7b5f61196a7366ef20757103d276ad0ed336c35ada` |
| `glasses01_cc0.zip` | `f215c58e09e31b7ee568c814067cb47704cee6da1f6fc01cffb8e9fca37bafdd` |
| `hats02_cc0.zip` | `838b9b51ba31d27f21198ad4506eb9b23e1c03eb246fe68f26da99e26b40e1aa` |
| `gloves01_cc0.zip` | `ecdaee1d02749d17352791d415cb622a883350cc8a4b90eda3725aef35d9afb2` |

Pieces (author attributions are courtesy — CC0 requires none):

| piece | source | author | licence |
|---|---|---|---|
| `loincloth_ragged` | generated from the MakeHuman basemesh | devantler-tech | CC0-derived |
| `shirt_ragged` | shirts01 `elvs_crude_t-shirt_male` | MakeHuman team, edited by Elvaerwyn | CC0 |
| `pants_wool` | pants01 `toigo_wool_pants` | MRT | CC0 |
| `shoes_cloth` | shoes01 `toigo_mj_cloth_shoes` | MRT | CC0 |
| `boots_worn` | shoes01 `culturalibre_male_boots` | culturalibre | CC0 |
| `relic_goggles` | glasses01 `culturalibre_doc_ock_glasses` | culturalibre | CC0 |
| `ruin_drake_helm` | hats02 `culturalibre_warrior_helmet` | culturalibre | CC0 |
| `ashen_bindings` | gloves01 `culturalibre_hero-heroine_gloves_5` | culturalibre | CC0 |

The first head-layer pair is intentionally exposed only through the guarded layered-outfit preview
while its flat bake materials remain below the character-art bar. Baked GLB sha256:
`relic_goggles` `66e0c8428c8e311a84dbd41e870e7d5f10bef59a4e776e1d5a68e3cd3093f41b`
(3 882 096 bytes); `ruin_drake_helm`
`dc2764375ea9d74eae03ed393cc140794fca89902e21d28d3ca74cd5075520b9`
(526 004 bytes).

`ashen_bindings` is the preview-only first hand-slot armor piece: a dark, rough, scalloped binding
that fits the early worn-light-armor tier without exposing a production writer before the retained
reader release. Baked GLB sha256:
`fdd81071ee4762321ca3ce8ce5701405d983640949ab927e4143e2cbfce215da`
(1 345 072 bytes).

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
fdd81071ee4762321ca3ce8ce5701405d983640949ab927e4143e2cbfce215da  equipment/ashen_bindings.glb
e3cb568bc74cffdda584e8b2d792d34b66bc39894dec482abd0cb727ce2601d0  equipment/ashen_bindings.glb.import
17dcb4f0c0ef707c2a7346ca26a3c19e2a78f808cbbfebaa792210df18445e5d  equipment/equipment.json
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
66e0c8428c8e311a84dbd41e870e7d5f10bef59a4e776e1d5a68e3cd3093f41b  equipment/relic_goggles.glb
1494f1d1e9aaf24ef355b992c85238e5b496dd6758850b87cffc845513cf2738  equipment/relic_goggles.glb.import
dc2764375ea9d74eae03ed393cc140794fca89902e21d28d3ca74cd5075520b9  equipment/ruin_drake_helm.glb
726b302d3575ab9c8e3f46aa97a77901b09e8160c0704a8c0b5437460adf3562  equipment/ruin_drake_helm.glb.import
d99aea1a543900ca28711183005f726902ef1e69c552a05091804a6f1d6c3ac9  equipment/shirt_ragged.glb
df089d0a11668b03759603f5be1f72fe5deeb0233bd9bf33e2333af23de6fe13  equipment/shirt_ragged.glb.import
d36a2cfa7159b8bee548c2fa107cbfce82e8ae98a80cc053918ccfdc768da62d  equipment/shoes_cloth.glb
5b48bbccab33f47758748b950026795e6044c6d94f461d20aa8fb78b57e0ae10  equipment/shoes_cloth.glb.import
af7b82fb2b1a22b54e994460cc01979cf64c3aa8c8dd50229ccac2736de558ff  humanoid_base.glb
49a83c611e575377fb52f68c2121c6d8488481a5996ae275a61183f506ca018d  humanoid_base.glb.import
978d90350c525c3abb86626af0cf738d28380e0c4302e4bb065f3b286e08a4c8  kit_report.txt
300c087e4957efdffce83954fe7b3eb07894f63c9ba5e4bb6994346bbe9d6a04  skins/skin_female_aged.png
02e1fd4171ea849eb8c2c1e2ec69a9f541a2f1cdd795523b9de9627bd071c159  skins/skin_female_aged.png.import
ab9e330fc71a8910795cbea02235d197c71519062477e8ef1606df79179d0794  skins/skin_female_light.png
6389f87f51f05842e5458fc38e078333616d8b3a91b97428418cee53bb3bb065  skins/skin_female_light.png.import
854dbeac813ea0822324264a10dcfdd0be045d4b0e02497e43286c95e049be37  skins/skin_female_mid.png
ba6756b144bbdf3197ad4c086c761cd10e3eeead6da0ffd45d9b72c68fef1613  skins/skin_female_mid.png.import
fb697014d35c7e08d602e709bd1a9c71960e7e0c444f1013e3cef51867153d66  skins/skin_male_aged.png
162368ff07769d384ed405e1835297f16d2e39cd6375e5f8bc5e64a5ca126764  skins/skin_male_aged.png.import
c9b03eed714890b7999317b29f4230e3b276c1ddaa5044cba37a851ad3bb23a3  skins/skin_male_deep.png
37dd3be0281ce86c59ddc70ca06c39c1e9cd9702388af7da54ae4c1011952cf0  skins/skin_male_deep.png.import
0f64d85b52c6003102f4258255a02324e18ba54fe2c5135b38789272319a8480  skins/skin_male_light.png
cf16c2135216c6f6aae91df4de73de78e2c2e0d5622ae9ab6acef77a79a9bf4b  skins/skin_male_light.png.import
dcbceb6dd37826e400f95a49469f55fac22d5364712af8f91f9b23761e4da517  skins/skins.json
```
