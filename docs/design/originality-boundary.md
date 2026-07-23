# Originality boundary — draw from ideas, author the expression

World at Ruin may learn from other games, but it must not reproduce their protected expression or
present itself as connected to them. This is the repository's engineering and release policy, not a
legal opinion or a substitute for qualified intellectual-property counsel.

## The legal boundary this policy implements

The practical line is **idea and function versus expression**:

- The [US Copyright Office's games guidance](https://www.copyright.gov/register/tx-games.html)
  says a game's idea, title and methods of play are not protected by copyright, while sufficiently
  expressive text and graphics can be.
- [17 U.S.C. § 102(b)](https://www.copyright.gov/title17/92chap1.html#102) excludes ideas,
  procedures, processes, systems and methods of operation from copyright even when a protected work
  describes or embodies them.
- In the EU, the Court of Justice held in
  [SAS Institute, C-406/10](https://infocuria.curia.europa.eu/tabs/redirect/juris/liste.jsf?num=C-406%2F10)
  that software functionality and programming languages are not copyright-protected forms of
  expression. It also recognised in
  [Nintendo, C-355/12](https://infocuria.curia.europa.eu/tabs/redirect/juris/liste.jsf?num=C-355%2F12)
  that a videogame includes original audiovisual material protected as a complex work.
- Copyright and branding are separate. A title may fall outside copyright while still creating
  trade-mark or passing-off risk. The
  [USPTO likelihood-of-confusion guidance](https://www.uspto.gov/trademarks/search/likelihood-confusion)
  explains that similar marks on related goods or services can be refused because consumers may
  think they share a source.

The working consequence is deliberately conservative: **systems and abstract goals may inspire;
another game's authored realisation may not be copied or closely adapted.**

## What may and may not transfer

Safe material to study and re-express independently includes:

- rules and mechanics, such as recoverable death loss, telegraphed attacks, horizontal progression
  or an exploration-led journal;
- design goals, such as readable danger, a material-visible equipment hierarchy, an any-order
  story, or a medieval baseline interrupted by scarce technology;
- genre conventions and abstract qualities, such as warm versus cool light, a heavy versus agile
  silhouette, worn materials, sparse ambience or a restrained camera.

Do not copy, trace, closely adapt or reconstruct:

- source code, data, prose, dialogue, lore, quests or distinctive plot sequences;
- characters, factions, creatures, proper names, signature items or a distinctive combination of
  their traits and relationships;
- maps, level layouts, puzzles, encounter choreography or quest structures at an expressive level;
- screenshots, concept art, textures, models, animation, audio, music, voice, UI layouts,
  iconography, VFX, compositions or distinctive equipment silhouettes;
- another title's terminology, marketing language, visual identity or anything suggesting an
  official connection.

An external reference is **view-only and link-only**. Never download it into this repository, trace
or paint over it, feed it to a generator, use it for style transfer, or describe it as a source
asset. Generated work may use only first-party or licence-cleared inputs covered by the asset
provenance contract.

## Required reference-distance workflow

Every player-visible change that uses a named-game reference must do all of the following:

1. Link the exact official or otherwise lawful reference without committing its media.
2. Translate the target into an abstract written brief before authoring the result.
3. Make at least **three independent expressive choices** across silhouette, composition, palette,
   material, naming, narrative cause, interaction, animation and audio.
4. Build only from first-party or verified CC0/permissive inputs, with the provenance required by
   `AGENTS.md`.
5. Inspect the result beside the reference. Remove distinctive shapes, staging, text, names or
   combinations that remain recognisably reference-specific.
6. Include this section in the delivery PR:

   ```markdown
   ## Originality

   - Abstract target:
   - Independent choices:
   - Excluded reference-specific expression:
   - Inputs and provenance:
   - Remaining similarity risk:
   ```

7. Stop and obtain qualified IP review before release when the remaining risk depends on a
   substantial-similarity judgment, a distinctive narrative/character combination, fair use, or
   trade-mark clearance. Automation may prove repository facts; it cannot give legal clearance.

The originality note complements the existing frame, named-reference and remaining-gap evidence. It
does not replace them.

## Current reference-distance audit

This table records what each named influence is allowed to contribute and what World at Ruin must
keep independent.

| Influence | Abstract lesson allowed | Expression excluded or held | Current action |
|---|---|---|---|
| **Numenera / the Ninth World** | A far-future medieval society among misunderstood remnants can inform the premise. | Exclude its terminology, history, characters, factions, creatures, locations, plots, relics and compositions. | Keep a link-only conceptual anchor; independently author World at Ruin's history and visual language. |
| **Planescape: Torment** | Identity and memory are abstract themes. | The proposed immortal/amnesiac protagonist, forgotten former lives and identity investigation form a high-risk cluster. | The story proposal is under **ORIGINALITY HOLD** pending independent rewrite and legal judgment. |
| **Elden Ring and Souls-like games** | Recoverable death loss, nonlinear exploration and telegraphs are functional ideas. | Exclude terminology, characters, narrative delivery, maps, UI, text, VFX, encounters and dropped-currency presentation. | Keep World at Ruin's own resurrection cause, vocabulary, map language and audiovisual treatment. |
| **WoW, WildStar, Guild Wars 2, The Secret World and The Elder Scrolls** | Readability, horizontal progression, mastery and ambience may be studied abstractly. | Exclude ability kits, quests, factions, zones, silhouettes, UI, icons, dialogue, audio and names. | Remove internal comparisons from player prose; use World at Ruin's own target language. |
| **Fatekeeper, Kingmakers, Diablo IV and Horizon** | Material, light, equipment-tier readability and fidelity are abstract qualities. | No screenshots, tracing, paint-over, copied gear, compositions, palettes, prompt inputs or scene reconstruction. | Keep references external; document independent choices and cleared inputs. |
| **Outer Wilds, Obra Dinn, The Witness and other story-research titles** | Information structure, any-order robustness and puzzle verification can inform system requirements. | Do not copy mysteries, puzzles, clue text, world layout, journal/ship-log presentation or story beats. | Reduce every use to a testable abstract rule before writing World at Ruin content. |

The audit found no third-party screenshot, model, texture, audio, source-code copy or other direct
reference asset in the tracked tree. `docs/art-direction/` contains link-only Markdown; the tracked
Phase 0 images are first-party captures of World at Ruin; current character assets are procedural or
documented CC0 inputs. The asset coverage weakness is being closed separately by
[#358](https://github.com/devantler-tech/world-at-ruin/pull/358), which binds provenance records to
exact tracked bytes.

That is evidence about the current repository, **not a declaration that the game cannot infringe**.
Substantial similarity can arise from a protected combination even when no file was copied. The
story proposal above is therefore quarantined, and each future player-visible delivery must expose
its reference-distance reasoning for review.

## Release and counsel gate

Before commercial branding or release:

- obtain a qualified IP lawyer's review of the name **World at Ruin** and other product/faction
  marks for the intended territories;
- obtain review of any high-risk narrative, hero character, signature creature, zone, UI or
  audiovisual package whose remaining similarity cannot be resolved by independent redesign; and
- preserve the reviewed PR evidence and asset provenance as the release's clearance record.

Passing `tools/originality-guard.sh` means only that the objective repository boundary is intact:
references are link-only, art generation has no tracked binary reference inputs, internal
comparisons are absent from player prose, and the high-risk proposal remains held. It does not
certify non-infringement.
