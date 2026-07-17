# AGENTS.md — World at Ruin

Canonical instructions for AI agents working on **World at Ruin**: a source-available, cloud-native
MMORPG built **almost entirely by agents** as a **first-class portfolio product** — it gets the same
attention and love as every other product and sits in the normal selection rotation (maintainer
direction 2026-07-17, superseding the bootstrap-day "lowest priority" note); expect the game to
accrete over years all the same. The maintainer redirects via
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
  Haven / ambientCG (CC0) materials; **Material Maker** / text `.gdshader` for procedural
  materials (MIT/output-yours); **Sapling Tree Gen** for foliage; WFC interiors, grammar towns,
  SDF/marching-cubes caves, noise + hydraulic-erosion terrain.
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

### Platforms — deliberately last

Every platform added early multiplies the cost of every change made after it, so platforms are the
**final roadmap phase**: **macOS/Windows/Linux first** (same tier, cheap); **consoles via W4
Games** — Godot's only console path, paid/commercial middleware, deliberately deferred, but
**platform-holder applications start early** because approval is slow and independent of code;
**iOS/iPadOS last and optional** — reduced tier, **controller required** (no virtual sticks for a
game about standing in the right place).

### Licensing

**Source-available and proprietary — NEVER call it "open source"** (free redistribution is clause 1
of the OSD). Copying/redistribution prohibited. The legal set is in place: `LICENSE.md` (bespoke
source-available licence), `EULA.md` (governs playing distributed builds), and `CLA.md` (**copyright
assignment**, EU: with a fallback exclusive licence). The first-party, dependency-free `CLA`
workflow blocks an external PR until its author signs; signatures are ledgered on the **permanent
`cla-signatures` branch — never delete it**, and an external PR that touches
`.github/workflows/cla.yaml` is inherently suspect (it can repaint its own check, never the
ledger). **No GPL/AGPL in the shipped tree** — enforced in CI (`license-guard` job), not
remembered.

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

### Setting & story — a medieval-futuristic world at rebirth

Settled with the maintainer 2026-07-17. This is the fiction every zone, asset and system renders.

- **The arc.** In a far-future era, a mystical disaster — working name **the Ruin** (agent-proposed
  from the title; redirect if wrong) — left the world a wasteland. The wanderer wakes in a cave
  with nothing but ragged clothes and bare hands, fights their way to the surface, and emerges
  into a barren world. The journey starts there. **This opening IS Phase 1's vertical slice**
  ("unarmed and lightly clothed in an abandoned cave", #8) — the intro and the engineering slice
  are the same artefact, and the Phase-0 cave is its stage.
- **A world at rebirth.** Barren, but coming back to life: a deliberate mix of wasteland and lush,
  vibrant zones. New lifeforms, monsters, and mystical, evil and criminal humanoids **and aliens**
  populate it. Aliens are strange peoples of this world's rebirth, not a starfleet — they must
  never drag the setting toward hard sci-fi.
- **Tone: medieval-futuristic, and the medieval feel wins.** Anything from iron swords to laser
  swords and blasters exists, but it must *still feel medieval*. Style references: **World of
  Warcraft and WildStar** — and WildStar is the sci-fi *ceiling*, never the baseline. When in
  doubt, technology reads as relic, salvage or artefact — forged, scavenged, half-understood —
  never as clean manufactured sci-fi.
- **World shape: open and horizontal** (consistent with the progression law), with **oceans that
  can be travelled** and **swimming down to undersea areas and caves**.

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
  progression here only** — vertical, **with a real loft**: gear upgraded and specialised to take
  on harder content, a climb worth making. **In the open world, endgame gear gives a cosmetic edge
  ONLY** (maintainer direction 2026-07-17): the open world is a **fair challenge for everyone**,
  and an experienced player's edge there is their **arsenal of abilities and weapon skills** —
  never stats.
- **All endgame stays relevant — keys and scaling everywhere** (maintainer direction 2026-07-17):
  every endgame activity (mythic-like, regular dungeons, raids, endless) carries **keys and
  scaling** that keep it engaging and replayable at the current loft — no endgame content is ever
  outleveled into irrelevance. **Expanding the endgame means BOTH improving what exists and
  building more content**; neither the endgame nor the open world is ever allowed to go stale or
  irrelevant.

### Design guards — the traps in the above, and how to hold them

These are the non-obvious failure modes. Treat them as laws, and prefer designing them out over
policing them (there is no undo).

- **🔴 The endgame ladder is the one place power grows — it MUST be bounded and inert outside
  itself.** "Gear upgraded to take on harder and harder content" *is* vertical progression, i.e.
  the exact inflation the product law forbids. **SETTLED by maintainer direction 2026-07-17:**
  (a) endgame gear is **cosmetic-edge-only in the open world** (stat-normalised/inert outside
  endgame instances — GW2 downscaling / WoW Timewalking are the reference mechanics), so the open
  world stays a fair challenge for everyone; and (b) the vertical has a **loft but a bounded one**
  — beyond it, **difficulty scales, not power**, via the keys-and-scaling law above, and rewards
  become **score and cosmetics**. That is how "harder and harder" runs forever with no inflation
  and no reset.
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
- **"Still feels medieval" is a taste judgement — give it an enforceable proxy.** Silhouettes,
  materials and architecture stay medieval; energy and tech are the *accent*, never the baseline.
  An asset or zone that would look at home in a pure sci-fi game has crossed the line — route edge
  cases to the maintainer rather than drifting there one blaster at a time.
- **Blasters must not smuggle in a different genre of combat.** A blaster or laser sword is a
  weapon mastery inside the same telegraph/trifecta design — same telegraphs, same roles, same
  sidegrade law — never a cover-shooter bolted onto an MMO. If ranged energy weapons start
  demanding their own combat rules, that is drift.
- **Oceans and undersea zones are settled destiny, not an early deliverable.** They slot into the
  world/game phases (#10, #13). The known trap is underwater combat legibility (WoW's Vashj'ir
  bled players here): telegraphs put the signal on the *ground*, and 3D swimming has no ground.
  Undersea areas ship exploration-first and gain combat only once telegraphs have an underwater
  grammar that keeps fights fair. Reserve a swim state in server-authoritative movement early — a
  third movement mode is cheap to reserve and expensive to retrofit.

### Phase 0 — before further game systems

**Prove the art pipeline**: headless Blender in CI → one MPFB2 character with proportions pushed
stylised-realistic → one procedural cave → standing in Godot. It is a **taste gate the maintainer
judges**, not a test suite, and it is the project's **one unproven bet**. If generated art can't
clear his bar, the premise fails — cheap to learn now, ruinous to learn later. (The `v0.1.0`
walkable slice predates this gate by the maintainer's direct instruction — it exists so progress
can be watched by playing; every *further* art/game system waits on Phase 0.)

## Maintenance

- **Structure:** `client/` is the Godot 4 project (scenes built in GDScript from engine
  primitives). The one sanctioned exception to "no binary assets" is `client/assets/` — artifacts
  BAKED BY COMMITTED CODE (`tools/artgen/`, the Python/bpy exception) from CC0 data, plus the
  sanctioned committed CC0 base meshes that generators reshape in code (maintainer direction on
  #20); every asset directory carries a `PROVENANCE.md` with licence chain and checksums, and
  bakes must be deterministic (the artgen workflow re-bakes and byte-compares). Characters are
  composed at runtime by `CharacterFactory` from **recipes** (`client/recipes/*.json`, versioned
  and name-keyed — names are forward-only per the no-resets law; `tests/save_fixture_guard_test`
  enforces it: every historical golden fixture must load with zero loss, every recipe version up
  to `RECIPE_VERSION` must have one, and `tests/data/shipped_recipe_versions.txt` is the
  append-only ledger anchoring that range — bumping `RECIPE_VERSION` means appending the ledger
  line AND committing the version's golden fixture in the same PR); non-humanoid **creatures**
  follow the same shape — `CreatureFactory` composes a baked creature kit (the ash hound is the
  pilot archetype) from versioned, name-keyed, forward-only recipes, one canonical skeleton per
  archetype. `server/` is the Go authoritative tier — its **zone tick core** has landed
  (`server/sim/`, the deterministic fixed-timestep simulation; `server/cmd/zone/`, the runnable
  skeleton), plus its **area-of-interest** query and enter/leave tracker (`server/sim/aoi.go` —
  the seam the replication layer will consume, with its own cross-platform golden), with the
  Agones/Nakama/networking layers arriving as later children of the
  server-foundation epic (#4); `deploy/` (platform manifests) arrives later per the roadmap.
- **Run:** `godot client` (macOS: `/Applications/Godot.app/Contents/MacOS/Godot client`).
- **Validate before every PR:**
  `godot --headless --editor --quit --path client && godot --headless --quit-after 120 --path client` —
  the editor pass imports AND writes the global class-name cache (`--import` alone never writes
  it, and scene-arg runs hang without it); the smoke boot must print the `BOOT_OK` marker AND no
  `SCRIPT ERROR`/`ERROR`. **`--path` is required on the smoke boot too** — the bare positional
  form (`godot ... client`) silently boots no project at all (verified on 4.7.1: ~1 s, no
  project mount) and every absence-of-error check then passes vacuously.
  Then run the regression tests: `godot --headless --path client res://tests/<name>.tscn` for each
  scene under `client/tests/`. CI (`ci.yaml`) runs exactly this, plus the `license-guard` job (no
  GPL/AGPL texts in the tree) and the `Server CI (Go)` job (below).
- **Validate the server before every PR:** from `server/`, `gofmt -l .` (must print nothing),
  `go vet ./...`, `go test -race ./...` (includes the tick-determinism and golden-hash tests), and
  `go build ./...`. The `Server CI (Go)` job runs exactly this and feeds the `CI - Required Checks`
  aggregate. Simulation determinism is a product-law requirement: the sim is integer-only with no
  wall-clock or unseeded randomness in the authoritative path, and changing the committed golden
  hash (`server/sim`) is a deliberate, reviewed act — never a rubber-stamp.
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
  until their author signs the CLA (`CLA.md`; the `CLA` workflow enforces this, with the ledger on
  the permanent `cla-signatures` branch).
- **Roadmap:** GitHub Issues on this repo (`roadmap` label for epics). The plan is **phase-gated**
  — Phase 0 (art-pipeline taste gate, #1) through Phase 8 (platforms, #15), each phase's exit
  criteria unlocking the next, plus the standing risk register (#16). Keep issues **agent-shaped**
  — small, specified, testable, art-free; every issue should be agent-completable without a human
  (testable, independently shippable, Go-and-tests-heavy). **The project stalls the moment the
  next task is "make the combat feel good"**: that is a taste judgement, route it to the
  maintainer rather than guessing.
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
