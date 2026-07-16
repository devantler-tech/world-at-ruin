# AGENTS.md — World at Ruin

Canonical instructions for AI agents working on **World at Ruin**: a source-available, cloud-native
MMORPG built **almost entirely by agents** at **lowest portfolio priority** — pick it up only when
nothing else demands attention, and expect it to accrete over years. The maintainer redirects via
the **PR workflow**; ship draft PRs as usual. Shared cross-repo rules live in the monorepo
[`AGENTS.md`](https://github.com/devantler-tech/monorepo/blob/main/AGENTS.md) (trust gate, draft-PR
discipline, issue-driven work, guardrails); this file adds the product's settled design and
repo-specific conventions.

Everything in *The settled design* below was **decided with the maintainer directly (2026-07-16) —
do not re-litigate it.** Refinements happen through issues and draft PRs he can redirect, never by
silently drifting from these decisions.

## The settled design

### The premise — "as code", which decides everything else

No UI clicks, no desktop design tools. Everything text-authored, built headlessly in CI. **If an
agent cannot author it, it does not get built**, because nobody is hand-making this. So "as code"
is the *premise* and every other preference — engine, fidelity — yields to it.

- **Client: Godot 4** — chosen *because* `.tscn`/`.tres`/`.gdshader` are text and headless export
  is first-class. **Unreal was rejected:** `.uasset`/`.umap` are binary, so agents cannot author
  levels or materials. This knowingly costs the graphics ceiling (Godot ≈ semi-realistic PBR; no
  Nanite/Lumen).
- **Art: generated as code, all OSS/CC0 — never commercial assets.** Headless Blender (`bpy`) →
  glTF; **MPFB2 + Rigify** for characters (core assets CC0, explicitly closed-source-safe); Poly
  Haven / ambientCG (CC0) materials; WFC interiors, grammar towns, SDF caves, erosion terrain.
  **Blender's GPL covers the tool, never the output.** Target is **stylised-realistic ("a more
  realistic WoW")** — that style is *parametric*, which is exactly why it is expressible as code.
  Photorealism is unreachable in any engine without a human sculptor; do not re-attempt it.
- **Weakest link: animation.** CMU mocap (verify licence per dataset — AMASS/LAFAN1 are
  research-only, never ship them) + procedural IK. Telegraphed combat mitigates this by putting the
  signal in the ground, not the frames.
- **AI-generated 3D**: MIT models exist (TRELLIS, TripoSR) but topology is poor and **training-data
  provenance is murky** — a liability for something the owner owns outright. Concept/props only,
  never a shipped hero asset.

### Server

- **Realtime tier**: zone / dungeon-instance **Agones** GameServers (CNCF). **One tick loop per
  process — NEVER decomposed.** The unit of scale is the *number* of zones. A network hop between
  "player moved" and "was he in the cone" re-creates the desync problem telegraphs exist to avoid.
- **Meta tier**: real Go microservices over gRPC — mostly **Nakama** (Apache-2.0) for
  auth/social/chat/storage. Write only what it doesn't give you.
- **Postgres/CNPG**; runs on the existing platform via Flux. **Seamless instancing** falls out of
  Agones: allocate the dungeon server as the player approaches, pre-connect, hand off — no loading
  screens, no pop-in, ever.
- **Physics stays OUT of the authoritative path** — capsules/navmesh only. This is what makes a Go
  authority cheap, deterministic and latency-tolerant.

### Licensing

**Source-available and proprietary — NEVER call it "open source"** (free redistribution is clause 1
of the OSD). Copying/redistribution prohibited. Needs a **bespoke EULA** and a **CLA with copyright
assignment** (EU: assignment plus fallback exclusive licence) gating the first external PR. **No
GPL/AGPL in the shipped tree** — enforced in CI (`license-guard` job), not remembered.

### Product law — the two constraints that outrank the design

1. **No hard resets, ever.** An early player keeps playing as it evolves: no wipes, no seasons, no
   stat squishes. Every change is **forward-only and non-destructive** (expand/contract migrations,
   versioned save data, backward-compatible protocols, feature-flag-first). **CI-enforceable, and
   the guard must exist before the first player does** — an agent must not be able to merge a
   change that strands a character.
2. **No power/wealth inflation, no ecosystem corruption.** **There is no undo**: a dupe, a runaway
   drop rate or a bad migration is permanent. Transactional integrity, idempotency and an audit
   trail are day-one requirements.

**The collision to keep front of mind: WoW/Diablo-4's answer to inflation IS the reset** (D4 wipes
seasonally; WoW squishes stats). Both are forbidden, so economics come from **Guild Wars 2**
instead: horizontal progression, a ceiling that never rises, bound loot, no trading/auction house
(kills RMT, botting and dupe *value* at the root), hard sinks. WoW/D4 texture, GW2 economics.

### Design — classless weapon mastery (The Secret World-shaped)

- **Classless.** Playstyle is defined by which weapons you master. **Two weapons equipped, or one
  wielded alone to empower it** — flexibility and multi-specialisation.
- **Trifecta**: damage / healer / tank. Each weapon leans toward one or more roles.
- **Progression = weapon mastery, earned by *using* the weapon.** Mastery unlocks **new arsenals —
  never more damage**: more and more interesting ways to approach combat.
- **Death**: lose some unbanked mastery, respawn at the nearest respawn point, and **reclaim it or
  lose it forever** (a Souls bloodstain, kept even though the Souls loop was dropped). A filled bar
  **banks unlosable progress** — a ratchet floor.
- **Balance**: mitigation / damage / healing throughputs stay balanced so **all areas stay
  relevant**. Progression is *advisable* for the hardest content, never *required* — doing it
  unprogressed should be possible but unwise. Some areas/dungeons are **gated by story or orderly
  completion**; unlocks are **account-bound**.
- **Hard, skill-based bosses and elites** spread across open world, dungeons and raids — opt-in
  risk of losing or gaining larger amounts of mastery, plus the odd cosmetic.
- **Loot is Elder-Scrolls-shaped: a sword is a sword.** How well you use it is *your* mastery. Huge
  visual variety so players find the look they want **without touching balance**. **Armour is the
  exception** — real mitigation/lightness trade-offs: light = agile, heavy = takes a hit.
- **Endgame**: mythic-like dungeons, regular dungeons, raids, endless dungeons. **Loot-based
  progression here only** — gear upgraded and specialised to take on harder content. **Outside the
  endgame, loot is visual only**, so the open world stays relevant.

### Design guards — the traps in the above, and how to hold them

These are the non-obvious failure modes. Treat them as laws, and prefer designing them out over
policing them (there is no undo).

- **🔴 The endgame ladder is the one place power grows — it MUST be bounded and inert outside
  itself.** "Gear upgraded to take on harder and harder content" *is* vertical progression, i.e.
  the exact inflation the product law forbids. It is only coherent if: (a) endgame gear is
  **stat-normalised or inert outside endgame instances** (GW2 downscaling / WoW Timewalking), or it
  trivialises the open world and breaks "all areas relevant"; and (b) the ladder has a **ceiling**
  — beyond it, **difficulty scales, not power** (endless dungeons, mythic keys), and rewards become
  **score and cosmetics**. That is how "harder and harder" runs forever with no inflation and no
  reset.
- **🔴 Usage-based progression's classic exploit is AFK/dummy grinding** (UO, Skyrim, ESO all bled
  here). With no wipe available this is permanent. **Mastery accrues only from meaningful contested
  combat** — appropriate-level hostile targets, server-authoritative, diminishing returns, and
  **zero** progress from training dummies, self-damage, or trivial mobs.
- **Every new arsenal ability must be a SIDEGRADE, never a strict upgrade.** More options raise
  throughput in effect — that is precisely how power creep enters a game that claims to have none.
  Situational-by-design is the law, and **"no strict dominance" is simulatable**, so it is an
  agent-ownable CI guard rather than a matter of taste.
- **Tune content against the *banked floor*, not peak mastery.** Unlosable progress is the only
  power level every player is guaranteed to have; everything above it is skill expression.
- **Death penalty in group content breeds blame.** A bloodstain is fine solo; "you cost me my
  mastery" on a raid wipe is why WoW removed corpse runs. Full risk in open world/solo (the stated
  risk/reward intent) and a softened penalty in organised group content — flag it as a decision,
  not a detail.
- **Classless + dual weapons SOLVES tank/healer scarcity** — the classic MMO queue problem. Any
  player can swap to fill the missing role. Protect this; it is a genuine strength of the design.
- **Axis map, to keep balance legible**: **weapons = horizontal** (your arsenal; cosmetic variety
  only). **Armour = your role/agility axis, and the bounded endgame vertical.** Keep them from
  blurring.
- **Classless + account-bound unlocks make alts near-pointless** — especially with full appearance
  freedom. Consider **one character per account**: it simplifies the data model and identity, and
  removes mule characters as an economy vector.

### Phase 0 — before further game systems

**Prove the art pipeline**: headless Blender in CI → one MPFB2 character with proportions pushed
stylised-realistic → one procedural cave → standing in Godot. It is a **taste gate the maintainer
judges**, not a test suite, and it is the project's **one unproven bet**. If generated art can't
clear his bar, the premise fails — cheap to learn now, ruinous to learn later. (The `v0.1.0`
walkable slice predates this gate by the maintainer's direct instruction — it exists so progress
can be watched by playing; every *further* art/game system waits on Phase 0.)

## Maintenance

- **Structure:** `client/` is the Godot 4 project (all scenes built in GDScript from engine
  primitives — no binary assets). `server/` (Agones realtime tier, Go meta services) and `deploy/`
  (platform manifests) arrive later per the roadmap.
- **Run:** `godot client` (macOS: `/Applications/Godot.app/Contents/MacOS/Godot client`).
- **Validate before every PR:**
  `godot --headless --editor --quit --path client && godot --headless --quit-after 120 client` —
  the editor pass imports AND writes the global class-name cache (`--import` alone never writes
  it, and scene-arg runs hang without it); the smoke boot must print no `SCRIPT ERROR`/`ERROR`.
  Then run the regression tests: `godot --headless --path client res://tests/<name>.tscn` for each
  scene under `client/tests/`. CI (`ci.yaml`) runs exactly this, plus the `license-guard` job (no
  GPL/AGPL texts in the tree).
- **Determinism:** world generation is seeded (`WorldGen.WORLD_SEED`) — the same world every boot.
  Never introduce wall-clock or unseeded randomness into generation; differences between builds
  must be attributable to code.
- **Dev log is a contract:** every player-visible change adds a `DevLog.ENTRIES` entry (newest
  first) in the same PR — the maintainer watches progress by playing, and the dev log is that
  surface. Bump `DevLog.VERSION` (and `config/version` in `project.godot`) per release-worthy
  change.
- **Scripting:** GDScript in the Godot project; **bash or Go everywhere else — never Python**
  (portfolio constitution). The Phase-0 Blender pipeline is the sole, explicitly-settled exception
  (`bpy` is Python by nature); keep it isolated under `tools/artgen/` when it lands.
- **Licensing hygiene:** no GPL/AGPL code or assets in the shipped tree; no commercial assets;
  CC0/OSS-permissive only, with licence verified per asset dataset. External PRs cannot be merged
  until the EULA/CLA exists (see `LICENSE.md`).
- **Roadmap:** GitHub Issues on this repo (`roadmap` label for epics). Keep issues **agent-shaped**
  — small, specified, testable, art-free. **The project stalls the moment the next task is "make
  the combat feel good"**: that is a taste judgement, route it to the maintainer rather than
  guessing.
- **Merge queue:** not enabled (org default rulesets only — PR required, signed commits,
  `CI - Required Checks` status).

## Review guidelines

Reviewers (Codex/CodeRabbit) flag **P0/P1 only**:

- **P0 — product law:** any change that could wipe/strand/devalue player state (destructive
  migration, save-format break, non-backward-compatible protocol change), introduce power/wealth
  inflation, or add GPL/AGPL/commercial-licensed content.
- **P1 — correctness:** unseeded/non-deterministic world generation, client-authoritative gameplay
  state (once networking exists), physics entering the authoritative path, or a player-visible
  change with no dev-log entry.
