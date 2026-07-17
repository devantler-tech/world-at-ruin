# Story & progression — the Undying Work, the Chronicle, and the Atlas

> **Status: PROPOSAL (2026-07-17).** Research-backed ideation for the maintainer to redirect —
> nothing below is settled until he says so. It builds on the settled *Setting & story* section of
> `AGENTS.md` (the Ruin, cave awakening, medieval-futuristic, world at rebirth) and contradicts no
> product law. All names are working names and flagged for a naming pass. On acceptance (whole or
> in part), the short laws graduate into `AGENTS.md`; this document stays as the design reference.

## The brief (maintainer, 2026-07-17)

- Shrouded in mystery; **exploration is key**.
- **No click-and-collect quests.** Objectives are dynamic and gameplay-oriented — never
  "go talk to this guy and that guy".
- An interesting **story progression system**: new areas and story arcs unlock by exploring and
  solving objectives throughout the world.
- **One protagonist's arc is not the same as another's.**
- **Elden Ring-shaped**: the story unfolds as you go, and no specific order is needed for it to
  make sense.
- **World progression/completion**: first-time dungeon clears, objectives, artifacts, rares and
  elites, achievements — rewards that empower the feeling of completing the world.
- **Completion is living and shrouded**: elements are tracked only once found (see a cave on the
  map, and its name, only after finding it). Completed elements whose content later changes flip
  back to "in mystery" — still tracked, so a player can revisit changed content easily instead of
  assuming nothing changed. The world must stay rediscoverable forever as it is updated.

## What the research says

Compressed from three research passes (single-player mystery masters; MMO precedents; per-player
narrative systems). Sources at the end. Each lesson carries its consequence for this design.

1. **Any-order storytelling works when arcs are small, local and self-contained.** Outer Wilds was
   designed assuming "the player knows any amount and combination of information at any time";
   Obra Dinn decomposes into bounded disasters; Elden Ring into regional legends. → Every zone is
   a closed arc; world-mystery revelations are written self-contained, enriching but never
   requiring each other.
2. **Tier the content: surface entries are cheap, answers live at the hidden tier.** Outer Wilds'
   three tiers (surface / mid / hidden; "answers to mysteries are always at the hidden level") is
   what makes any-order play converge. → Same tiering per zone, enforced structurally.
3. **Anchor every mystery to a shown spectacle, not text.** Question–spectacle pairing (the
   supernova, the probe launch; ruined Caelid). → Every zone leads with a visible anomaly you can
   walk toward.
4. **Track knowledge, never infer it.** The Outer Wilds ship log records only what the player
   provably read — inference stays the player's job; that rule is what keeps a journal from
   becoming a quest log. → The Chronicle obeys zero-inference strictly.
5. **Landmarks and prose, not markers.** The Erdtree orients; Morrowind's prose directions made
   geography *earned* — and its wrong directions taught that direction QA is content QA. Elden
   Ring's patched-in NPC markers are documented as a band-aid that eroded mystery without fixing
   breakage. → No objective markers, ever; the map records where you have been, not where to go;
   prose directions are tested content.
6. **Silent breakage is the cardinal sin of any-order worlds.** Elden Ring quest threads that
   silently void made guides the *default* interface — the hidden Ranni ending has higher Steam
   completion (25.9%) than the standard ending (19.6%). → No thread ever dies silently: threads
   are immune to world advancement or are *closed in fiction*, and CI proves reachability.
7. **Only performed knowledge survives wikis.** Every informational secret leaks on day one; The
   Witness' Challenge (randomized instances of learned rules) is the genre's one wiki-proof gate.
   → Rites are *performed*: rules are communal and discoverable, instances are seeded per account.
8. **Community-scale mysteries must make aggregation the puzzle — and never hold content
   hostage.** Outbreak Prime / Corridors of Time sharded information across thousands of players
   (beloved); Niobe Labs gated everyone's paid content behind an unsolved, non-self-verifying
   puzzle (mea culpa'd). → Communal gates gate *flavor, lore and firsts*; steps self-verify; the
   aftermath unlocks for everyone.
9. **Anything in the client is known on patch day.** Bungie's own engineering verdict: encrypting
   a content web is prohibitive; secrets that mattered were server-side or unannounced. → Secret
   truths (trigger conditions, rite instances, personal seeds, revelation content where feasible)
   live server-side.
10. **Per-player phasing corrodes the MMO contract.** WoW phasing's documented failure: players in
    different phases can't see or help each other. → The personal layer is additive and cosmetic
    only (glow, engravings, page state) — never occlusion, never divergent terrain or NPCs.
11. **Parallel authored story spines are economically fatal; braids and state-selected content are
    the proven engines.** SWTOR retreated from 8 spines after ~$200M; GW2's 15 openings braid into
    one; Hades, Wildermyth and Fallen London all *select hand-authored fragments by player state*
    (salience pools, role-matched templates, quality-gated storylets). → Former Lives are a braid;
    all reactive content is state-selected from pools.
12. **Cyclic events give texture; permanence needs "elite trigger, universal aftermath".** GW2
    dynamic events taught players nothing matters (it resets); Destiny's Dreaming City let a
    world-first clear change the world for everyone, permanently. → Stirrings cycle; milestones
    are communal, additive and permanent — which is exactly what forward-only allows.
13. **One-shot bespoke puzzles die of cost.** TSW's investigation missions — the genre's best —
    were consumed once, then became wiki data-entry; Funcom couldn't afford volume. → Reusable
    puzzle grammars with seeded instances, not one-off set pieces.
14. **Consistency beats variety in generated narrative.** Wildermyth: "one bad name ruins ten good
    ones"; players notice 1–2 traits, thoroughness is still mandatory. → Style bible, schemas and
    lint for the many small texts; the few big texts (revelations) go through the maintainer's
    taste gate.
15. **The Nemesis patent (US 10,926,179 + live continuations, expires ~2036, US-only) covers:
    player↔NPC interaction outcomes propagating parameter/status changes to *other* opposing NPCs
    through a ranked faction hierarchy.** → Our consequences propagate through *world state and
    dialogue availability*, never through enemy-NPC hierarchies. (Also the better design.)

---

## Part I — the fiction: the Undying Work

### The load-bearing conceit: the mechanics are already the story

Every awkward MMO convention this game has is made diegetic, so the fiction explains the game
instead of fighting it:

| Mechanic (settled)                          | Fiction                                             |
| ------------------------------------------- | --------------------------------------------------- |
| Every player wakes alone in a cave          | The caves are not shelters. Something *returns* people in them |
| Respawn at Wardens' shrines                 | Shrine flames catch your thread when you fall       |
| Death spills unbanked mastery; reclaimable  | Mastery *is* memory; what is not banked spills where you fell |
| Mastery grows by use, unlocks arsenals      | **You are not learning. You are remembering.** Your hands already know the blade |
| Amnesiac start, ragged clothes              | Not a blank slate — a *specific erased person*, discoverable |
| Thousands of protagonists                   | The waking is *ongoing*. Wanderers have been waking for a long time |
| The world keeps changing (live updates)     | The world is *at rebirth* — it grows, shifts, and re-shrouds |

### The mystery onion

Five layers. Each is complete in itself, and each recontextualizes everything below it. Players
peel them in any order and at any depth — the layers are reachable through every zone, not
staged one-per-region.

- **L0 — what you see.** A dead world under ash, strewn with ruins of impossible things: a glass
  bridge a mile long, a tower whose top is *elsewhere*, roads that end mid-air. New life growing
  strangely — flora that hums old songs, fauna with too many memories. Shrines that burn without
  fuel, tended by the hooded Wardens. And wanderers, waking in caves.
- **L1 — what the shrine-folk say.** Folk religion: the old world sinned by its brilliance and
  heaven burned it; the Wardens keep the last mercy-fires; the sleepers wake as penance, or as
  grace. (Every player hears L1 early. It is wrong in instructive ways.)
- **L2 — what the evidence says.** The old world was *ours* — brilliant and futuristic. The "gods"
  of the folk tales resolve, testimony by testimony, into its institutions and engines. The Ruin
  came from within. This layer also settles the tech economy diegetically: **iron is forged, laser
  is found.** The rebuilt peoples smith swords; nobody alive can make a laser blade — relic-tech
  is excavated, traded, half-understood, and slowly failing. (This *is* the medieval-feel guard,
  enforced by the economy instead of by style policing.)
- **L3 — the turn.** The Ruin was neither weapon nor accident. The old world attempted **the
  Undying Work** (working name): to make death optional — to anchor every soul so that nothing
  would ever be lost again. *It worked.* That is the horror: the miracle and the disaster are the
  same event. The world itself paid — its living substance unwritten to fuel the anchoring. The
  ash is not burnt matter; it is *unwritten* matter. The world died so that its people could not.
  - Everything clicks retroactively: the caves return the anchored, one by one, memory-scoured
    (you may have woken before — some testimonies imply centuries of wanderers); the shrine
    flames are the Work's surviving anchor-points, and the Wardens' tending is maintenance of a
    machine they only half-remember as liturgy; your mastery is *remembering* because you have
    lived, and perhaps fought, before.
  - And one late, quiet dread: the rebirth may not be recovery. The lush zones may grow where
    anchors have finally *failed* — where the dead at last died, and the world took back what was
    hers. The rebirth and the wanderers may be on opposite sides of the ledger.
- **L4 — the open horizon.** Never fully settled — deliberately, so the mystery outlives years of
  content. Who were the architects of the Work, and does any hand remain on it? The aliens: their
  own testimonies say their skies broke too — the Work did not respect the boundary of one world,
  or they came through the wounds it tore; their accounts contradict the human ones *productively*.
  And the question the whole game orbits, which no NPC will ever answer: **should the Work be
  completed, broken, or tended?**

### The four stances (factions)

Factions are stances on the orbit question, not team colors. Allegiance is earned by deeds in
their territory (never by dialogue), shapes which testimonies you hear and which arcs open, and
is the third axis of per-player divergence.

- **The Wardens** — tend the flames, keep the returned alive, decide nothing. The player's first
  shelter, and the game's diegetic hint system (below).
- **The Restorers** (working name) — finish the Work properly: bring back everyone, rebuild the
  old world. Attractive, articulate — and excavating things better left anchored.
- **The Verdant** (working name) — break the Work: let death return so the world can live. Gentle
  gardeners whose logical end is letting *you* die for good.
- **The Carrion Courts** (working name) — the evil and the criminal: harvesters of anchors,
  memory-sellers, press-gangs that meet the newly-woken at cave mouths and "recruit" them. The
  early-game antagonists, and a dark mirror of your own awakening.

### Why this canon survives years of agents: the testimony principle

**All lore is testimony; there is no omniscient narrator.** Every fragment is somebody's account —
carved, sung, written, remembered, or echoed — and witnesses disagree. This is the doctrinal rule
that makes an ever-growing, agent-written canon safe *forever*:

- New content can *reinterpret* old content but never needs to retcon it: contradiction is
  diegetic (someone was wrong, lying, or remembering badly).
- It matches forward-only law: canon is additive by construction.
- It matches the mystery: the player's job is source criticism, which is exactly the Elden Ring
  pleasure of assembling truth from fragments.
- It gives agents a hard style law: **never write the voice of God; always write a witness.**

---

## Part II — your arc is not my arc

Three independent mechanisms of divergence, cheapest first; together they make "one protagonist's
arc is not the same as another's" true structurally, not cosmetically.

1. **Order-emergence (free).** The world mystery is assembled in whatever order you explore — two
   players hold different fragments, believe different hypotheses, and had different "oh no"
   moments. This is the Elden Ring effect and it costs nothing extra once the architecture below
   exists.
2. **Allegiance (cheap).** Stances open different testimony pools, rites and arcs in the *same*
   zones.
3. **The Former Life (the centerpiece).** Every character is assigned at creation — seeded,
   hidden, permanent — a specific person they *were* before the Ruin. The game's Planescape move:
   the world already contains the consequences of your own former deeds, and "who was I?" is the
   central personal quest. Not backstory delivery — an investigation where the solution is you.

### How a Former Life works

- **Composition**: an authored **archetype** (launch target: ~8–10 — e.g. a Keeper of the Work, a
  soldier of the last war, an architect's apprentice, a thief of the dying cities, a singer whose
  songs the flora now hums back, one of the Fallen-Through who crossed before the end...) ×
  authored **deed variants** (2–3 per archetype: hero / complicit / cause) × **assigned places**
  (drawn from zone pools, so your traces live in different regions than mine). Wildermyth
  economics: hand-written templates, combinatorially cast.
- **Surfacing**: traces appear through the salience pattern (Hades / L4D-style most-specific-wins
  selection over shared state): a cave mark only *you* can read; an echo-scene that renders
  differently for you; a stranger who calls you by a name and apologizes; a rare that hesitates
  before you. No markers — traces are staged in the world and the Chronicle records them like any
  evidence.
- **Structure**: each archetype is a small braid (GW2-style diverge–reconverge), not a parallel
  campaign — SWTOR's lesson is law. Mid-arc, threads reconverge on shared infrastructure
  (the same dungeons, zones, rites) entered with different meaning.
- **Capstone**: you find where your former self ended, and what they did at the moment of the
  Ruin. Then the Torment question, made mechanical: **reclaim the name or renounce it** — a
  permanent identity choice with testimony, cosmetic and dialogue consequence. Never power
  (product law).
- **Multiplayer texture**: comparing Former Lives is the social loop ("mine was *at the Work* when
  it happened — what was yours?"). Archetypes are designed to interlock: two players' former
  selves may have met.
- **Patent guard**: all consequences propagate through world-state, dialogue availability and the
  player's own record — never through parameter changes on ranked hostile-NPC hierarchies. Rival
  NPCs, if ever wanted, stay 1:1 (single-NPC memory is safe ground). Prior art of our approach
  (CK2 2012, Fallen London 2009, Anarchy Online 2001) documented here deliberately.
- **Interaction with one-character-per-account** (under consideration in AGENTS.md): if adopted,
  the Former Life becomes account identity — strengthening both. Flagged for the maintainer.

---

## Part III — the Chronicle: how story progresses

The progression system. Working name: **the Chronicle** — an in-fiction journal every wanderer
keeps. It is the anti-quest-log: it records the *past*, never assigns the future.

### Leads, not quests

- A **lead** is a recorded observation plus the player's own open question, written as testimony
  and prose direction ("The ferryman would not cross the sound. He watched the water north of the
  black stacks."). No markers, no objective text, no checkboxes.
- Leads obey **zero-inference**: the Chronicle records only what you have provably seen, heard or
  read. Connecting is the player's job. "There is more here" pips (rumor-map style) are the only
  meta-signal, and they never say *how much* more.
- The world map is drawn by walking it: **nothing is tracked until found** (the maintainer's
  shrouding law — a cave appears on the map, with its name, only after you find it). The map is a
  record of where you have been — the Chronicle's cartographic page — not a to-do list.

### Evidence

Five typed units, all data resources agents author:

- **Testimonies** — what witnesses say (NPCs, recordings, letters). Dialogue is a *reward* for
  deeds and standing, never an objective. NPCs have itineraries and motives, not exclamation
  marks.
- **Relics** — things held; item-description lore (the Elden Ring channel). Relic-tech is
  excavated ("iron is forged, laser is found"), so *loot itself is evidence*.
- **Marks** — the old world's script, a learnable glyph language (Tunic/Fez). Reading is a real
  player skill that compounds across the whole world.
- **Echoes** — playable visions at resonant sites: short, staged scenes (the Work's residue
  replaying what it anchored). Solo seamless instances (settled Agones instancing).
- **Charts** — places, depths, routes: the world itself as evidence.

### Revelations

When you hold enough related evidence, the Chronicle lets you **assert a hypothesis** — and the
assertion is always a deed, not a menu: go there, dive it, ring it, read it aloud at the right
stone. If you are right, the revelation plays — a self-contained scene (echo, vault, vista,
confession) that reframes what you hold. Wrong assertions fail in fiction, cheaply and legibly
(the stone stays cold), never punishing exploration.

- Revelations sit at the **hidden tier** (lesson 2); their entry evidence is surface/mid tier.
- Each is **self-contained** (lesson 1): readable alone, richer in context, required by nothing.
- Every zone leads with a **shown anomaly** (lesson 3): the mile-long glass bridge is visible long
  before any testimony about it.

### Gates: how areas and arcs unlock

"Unlock new areas and story arcs by exploring and solving objectives" — five gate types, all
gameplay, none dialogue:

- **Rite gates (performed knowledge, per account).** A door, causeway, or passage that answers a
  performed rite — sequence, tone, timing — whose *rule* is discovered in the world (marks,
  echoes, testimony) and whose *instance* is seeded per account (lesson 7: the rule is communal,
  the execution is yours; a wiki teaches you the grammar, not your answer). This is the workhorse
  "story unlocks area" mechanism, and it is wiki-resistant by construction.
- **Deed gates.** The world reacts to accomplished things: fell the thing nesting in the
  lighthouse and the light returns and ships sail a new route; relight a shrine and its road
  wakes. Per-account where personal, communal where monumental.
- **Depth gates.** Diving, pressure, breath and dark — the ocean is a vertical frontier and the
  settled undersea destiny arrives as exploration-first content (per the AGENTS.md guard).
- **Mastery-soft gates.** Dangerous, not locked (settled law: progression advisable, never
  required).
- **Communal gates.** Server-scale mysteries designed *for* collective solving (lesson 8):
  information sharded per account so aggregation is the puzzle; self-verifying steps; firsts win
  honor and engravings (below), the aftermath opens for everyone. Used sparingly, for the big
  arcs of an age.

### The verb law (objectives)

Every objective resolves through a gameplay verb. The authoring whitelist:

**REACH** (traversal challenge) · **SURVIVE** (endure/hold) · **FELL** (rare/elite/boss) ·
**DECODE** (marks, alignments, rites-as-puzzles) · **CARRY** (move a thing with rules — a flame
that must not gutter, a bell that must not sound; environmental constraints, never NPC-pathing
escorts) · **CHART** (find, map, sound the depth) · **PERFORM** (execute a rite) · **AWAKEN**
(operate the Work: light, bind, unbind).

Banned as objectives, enforced by lint: *talk to X* (dialogue is a reward), *collect N of Y*
(collection without a puzzle, traversal or combat identity is filler), *escort NPC* (CARRY covers
the fantasy without the pathing misery). This is the anti-fetch law with teeth.

### Stirrings (dynamic objectives)

The rebirth is active. **Stirrings** are condition-triggered world events, GW2-shaped but honest
about what cycles: ashstorms that reveal glyphs while they blow; low tides that open sea-caves;
aurora nights that wake certain ruins; a rare's death letting a grove regrow until dusk; seasonal
migrations of things that should not migrate. Stirrings give texture and repeatable objectives.
**Permanent change is reserved for communal milestones** — elite trigger, universal aftermath,
always *additive* (the world only ever gains), which is precisely what forward-only law permits.

---

## Part IV — the Atlas: world completion, shrouded

Working name: **the Atlas** — the Chronicle's completion surface. Diegetic frame: the world lost
its map in the Ruin; every wanderer is re-charting it.

### Shrouded tracking (the maintainer's law)

- Every trackable element — caves, dungeons, rares, elites, artifacts, high points, deeds, depths,
  stirrings — starts **Unfound**: absent from map and Atlas. No spoiler checklists, no "12/47
  treasures" — totals are never shown for unfound content.
- Finding it makes it **In Mystery**: named, mapped, tracked, with its open threads pipped. Now it
  is *yours to work on*, and revisitable at a glance.
- Closing its known threads makes it **Tended** (working name for completed): the page
  illuminates; rewards land (below).
- **Living completion**: when a later update changes a Tended element, it flips back to
  **In Mystery** — still tracked, name and history kept, its page visibly dimmed with fresh ash.
  You can see *where* the world changed without being told *what* changed. Rediscovery is the
  point; silent change is the sin (lesson 6, applied to content updates).

### The two-layer ratchet

- **Deeds ratchet.** Achievements, titles, cosmetics, keepsakes, engravings, banked mastery —
  once earned, never revoked, never expiring, no FOMO, nothing seasonal-exclusive (product law
  applied to achievements). Your "Tended in the Age of Embers" mark on a page is permanent even
  after the page re-shrouds.
- **Knowledge lives.** Discovery state is allowed to regress to In Mystery when the world truly
  changed. The world can become unknown again; what you *did* cannot be undone.

In fiction: the Atlas records what you knew, not what is. Testimony goes stale — of course it
does; the world is at rebirth.

### The epoch contract (CI-enforceable)

Every tracked element carries a **mystery epoch**. Any player-visible content change to it MUST
bump the epoch in the same PR (lint-checkable, like the dev-log law) → all accounts' state for it
re-shrouds to In Mystery automatically. An agent cannot silently change discovered content; a
bumped epoch without a content diff is equally flagged. This is the whole "soft-reset" machinery:
one integer per element, forward-only, no player state destroyed.

### What feeds completion

- **First-clears**: a dungeon's first completion (per account) grants its **echo** — the dungeon's
  revelation is *loot for doing*, not a cutscene for arriving. Repeat clears stay valuable via the
  settled keys-and-scaling endgame; the *story* payout is the first.
- **Rares and elites**: each is a named consequence of the Ruin with a one-line legend; felling it
  yields its testimony fragment (+ the settled opt-in mastery stakes and odd cosmetic). Hunting
  rares *is* reading the world.
- **Artifacts**: excavated relic-tech with item-lore; collections displayed as keepsakes (your
  camp/shrine trim), each collection quietly assembling one testimony.
- **High points and depths**: climb it or sound it to chart it (GW2 vistas; Subnautica's
  no-map-but-beacons spirit underwater).
- **Deeds and rites**: every gate opened is a page entry.
- **Engravings (communal memory)**: monumental firsts — server-first clears, communal gate
  solutions, the raising of a great bell — are carved onto the monument itself, in-world, with the
  doers' names, permanently (Dwarf Fortress's engravings, made multiplayer). The world remembers
  its wanderers; late arrivals read the history of the server on its stones. Forward-only,
  additive, and the strongest cheap "the world is alive" signal an MMO can buy.
- **Zone aftermath**: a Tended zone shows it — *your* shrine flames burn brighter, roads you woke
  stay lit for you (account-layer, additive-cosmetic only; never occlusion, never divergent
  terrain — lesson 10).

---

## Part V — surviving the shared world

- **Two products ship: the first-solver's and the guide-follower's** (lesson 13's corollary). The
  first-solver gets the mystery; the guide-follower gets execution that stays worth doing (rites
  are performed; instances are seeded; traversal, combat and diving don't copy-paste). Communal
  hint culture is fostered diegetically: Wardens are the in-fiction hint tier ("ask a Warden"
  dialogue mirrors Outer Wilds' Travelers — soft direction, never answers), and the community will
  build its spoiler-tiered etiquette on top (TSW/Secret-Finding-Discord precedent).
- **Datamining**: rite instances, trigger conditions, personal seeds, communal-gate shards, and
  unreleased revelation text live server-side (lesson 9). The client holds geometry and grammar,
  not answers. (Server tier arrives Phase 1+; the data contracts should assume this split from
  day one.)
- **Personal seeds resist wikis structurally**: your traces, your rite instances, your Former Life
  — a guide can explain the system, not your answers.
- **Group pacing**: deduction is one-brain work (TSW's lesson). Investigation content is scoped
  solo/duo by default; group content shards information across members when it wants deduction
  (each holds a piece — Obra Dinn's verification-batch spirit); raids keep puzzles executable
  (self-verifying, performance-shaped), not archival.
- **Never hold shared content hostage** (Niobe law): communal gates decorate and reveal; they do
  not lock the playerbase out of core content pending a solve.
- **Nonlinearity's cost is cast attachment** (FFXIV's counter-lesson). Mitigation: a small
  recurring cast of witnesses — a Warden, a ferryman, a Carrion fixer, a Fallen-Through
  chronicler — who appear across zones and react to *your* state via salience pools (Hades
  pattern): attachment through reactivity instead of a linear spine.

## Part VI — why an agent-built game can afford this

The economics that killed the precedents are inverted here:

- **What killed TSW/SWTOR-style content**: human authoring cost of bespoke text, VO and one-shot
  puzzles. **This game has no VO** (testimony is text and staging by design — also the animation
  weakness never touches the narrative channel), and its authors are agents: text-dense, systemic,
  data-driven narrative is the *cheapest* content class in this production function.
- **What stays expensive for agents**: taste and consistency (Wildermyth's law). So the shape is:
  the *many small* texts (leads, legends, item-lore, barks) are schema'd, linted, style-bibled;
  the *few large* texts (revelations, capstones, L3/L4 canon) are authored rarely and go through
  the maintainer's taste gate like Phase 0 art does. The mystery onion means one good revelation
  irrigates hundreds of cheap fragments pointing at it.
- **CI-checkable story laws** (the agent-shaped part — same spirit as "no strict dominance is
  simulatable"):
  1. **Reachability**: from the cave, every evidence node is reachable under any exploration
     order (graph solver over the story data).
  2. **Multi-path**: every revelation has ≥ 2 independent lead-chains (no single chokepoint).
  3. **Gate solvability**: every rite's teaching evidence exists and is reachable before or
     without the gate.
  4. **Verb lint**: objectives parse against the verb whitelist; `talk-to`/`collect-N`/`escort`
     patterns fail CI.
  5. **Zero-inference lint**: Chronicle entries reference only evidence the player state holds.
  6. **Epoch law**: content diffs touching tracked elements bump their mystery epoch (and only
     with a diff).
  7. **No-silent-void**: thread state machines have no dead ends; every closure carries a fiction
     line.
  8. **Seed determinism**: personal traces derive reproducibly from account seed (same seed, same
     Former Life, forever — a character's past never changes).
  9. **Testimony voice lint**: no lore text in omniscient voice (heuristic + review flag).

## Part VII — a worked example: the Drowned Bell

Graymere Coast (invented zone, for illustration). The anomaly you *see*: a bell tower standing in
the sea, half-drowned, and at low tide — a stirring — you *hear* it: the bell rings from **under**
the water, slow, like something breathing.

- A cliff shrine holds a mural in marks: the bell raised whole, a phrase carved beneath (DECODE —
  if you've learned these glyphs elsewhere; if not, this is where you start wanting to).
- The ferryman won't cross the sound; earn his testimony by clearing the wreck-nester from the
  strait (FELL — it's also the zone elite, also an Atlas legend). He speaks of the harbor that the
  bell used to call home. There is no harbor on any horizon.
- Low tide + the mural's phrase: dive the tower (CHART, depth gate), find the bellkeeper's echo —
  he drowned lashing the bell silent, because the ships that answered it were following a harbor
  light that no longer existed. His tally-marks end mid-stroke.
- Assert the hypothesis at the tower: ring the true sequence (PERFORM — the *rule* is the mural's,
  learnable from any guide; the *sequence* is seeded per account). The bell answers. The drowned
  harbor district opens below — an undersea area, exploration-first per the settled guard — and
  its revelation reframes L2 for you: the harbor didn't sink. It was *unwritten*, and the bell is
  an anchor that would not let its people go.
- **Player A vs player B**: A's Former Life is the singer — her trace is that the bellkeeper's
  drowning-song is *hers*, and her arc thread continues here; B (the soldier) instead carries a
  tally-mark trace pointing to the garrison wreck two bays north. A helped B fell the nester; they
  compared Chronicles afterward and had genuinely different stories to tell.
- **Months later**: agents ship the harbor's second ward. The Drowned Bell's epoch bumps; every
  account that Tended it sees the page dim to In Mystery under fresh ash. A returning player
  doesn't wonder whether anything changed — she sees exactly where the world moved, sails back,
  and finds the bell ringing a note it never rang before. Her "Tended in the Age of Embers"
  engraving on the page remains.

## What to settle (decision list for the maintainer)

1. The fiction: the Undying Work as L3 truth; the testimony principle; the four stances; "iron is
   forged, laser is found"; aliens as the Fallen-Through. (Accept / redirect per item.)
2. The Former Life system as the personal-arc centerpiece — and its interaction with
   one-character-per-account.
3. The Chronicle laws: leads-not-quests, zero-inference, no markers, map-drawn-by-walking.
4. The verb law and its ban list.
5. Gate taxonomy, esp. per-account seeded rites as the standard area-unlock.
6. The Atlas: shrouded tracking, In Mystery / Tended states, the two-layer ratchet, the epoch
   contract, engravings.
7. Tone check: how dark may L3/L4 get? (Current pitch: melancholy-hopeful, dread at the edges —
   WoW-bright zones are still fully compatible.)
8. Naming pass: the Undying Work, Chronicle, Atlas, Tended, In Mystery, stirrings, Restorers,
   Verdant, Carrion Courts, Fallen-Through, engravings — all working names.
9. Light legal follow-up at the appropriate time: counsel confirmation on the Nemesis family scope
   (US-only) — our design steers clear by construction, this is belt-and-braces.

## Proposed next steps (agent-shaped, post-redirect)

1. Fold accepted laws into `AGENTS.md` (short form), keep this doc as reference (docs PR).
2. **Chronicle data schema + validator**: evidence/lead/revelation resource formats + a headless
   test scene running the reachability/multi-path/gate-solvability solvers (CI job).
3. **Verb lint + epoch law** in CI (cheap, pure text checks — do these first).
4. **First evidence set in the Phase-0/1 cave**: one mark, one echo, one lead that surfaces at
   Ashfall Reach — so the vertical slice already *is* the story's first hour.
5. **Atlas skeleton**: map-drawn-by-walking + page states over the existing slice (the shrine and
   the first cave as the first two tracked elements).
6. **Style bible: "the voice of testimony"** — the writing law agents follow; maintainer-approved
   exemplars per evidence type.

## Sources (key)

Kelsey Beachum, *Sparking Curiosity-Driven Exploration Through Narrative in Outer Wilds* (GDC
2021, slides); Alex Beachum's USC thesis; Miyazaki interviews (frontlinejp 2022, PlayStation Blog
2022, Kotaku/WIRED 2016); PC Gamer on Elden Ring's quest markers; DualShockers Steam ending stats;
Worch & Smith, *What Happened Here? Environmental Storytelling* (GDC 2010); Charlie Cleveland,
*The Design of Subnautica* (GDC 2019); Monica Evans, Game Studies 24(4); Andrew Shouldice, *TUNIC:
This Was Here the Whole Time* (GDC 2023); Jonathan Blow, *Modeling Epiphany*; Lucas Pope Obra Dinn
interviews; Thinky Games & Azhdarchid on knowledge-gated games; Joel Bylos TSW interviews (Ten Ton
Hammer, Flash Point #42); Richard Bartle via Tobold on WildStar paths (2014); Bio Break WildStar
postmortems; GDC Vault *Designing Guild Wars 2 Dynamic Events* + ArenaNet manifesto; Bungie Niobe
Labs clarification; Forbes/Tassi on Corridors of Time and David Aldridge's 2022 encryption
statements; Golden Sands Tall Tales Q&A (Chapman/Preston); PC Gamer on WoW's secret-finding
community; ESO One Tamriel forum analyses; Google Patents US 10,926,179 B2 / US 11,660,540 B2 /
US 12,201,908 B2 + Finnegan §101 analysis + Patent Arcade prosecution history; Nate Austin,
*Getting Players Emotionally Invested in Procedural Characters in Wildermyth* (GDC 2022, slides);
Greg Kasavin, GDC Podcast ep. 16 + Supergiant's voice-line infographic; Emily Short, *Beyond
Branching* (2016) and *Storylets: You Want Them* (2019); Elan Ruskin, *AI-driven Dynamic Dialog*
(GDC 2012); ICIDS 2015 CK2 emergent-narrative paper; Tarn Adams interviews; GW2/SWTOR/WoW wikis
and forum archives for phasing, personal story and cost data.
