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

### Product law — the constraints that outrank the design

1. **No hard resets, and nothing is taken from a player silently.** An early player keeps playing
   as the game evolves: no wipes, no seasons, no stat squishes. **The world may be migrated — that
   is expected and healthy** — but every migration is either **non-breaking** (expand/contract
   migrations, versioned save data, backward-compatible protocols; the player never notices) **or
   goes through a visible deprecation** that tells the player, in-game and ahead of time, exactly
   what is being changed, removed, or destroyed and when. Nothing a player earned disappears
   without that notice. **CI-enforceable, and the guard must exist before the first player does** —
   an agent must not be able to merge a change that strands a character or removes something from a
   player without an announced deprecation.
2. **Experimental features are opt-in behind a feature flag.** Anything not yet settled ships
   **default-off** behind a flag; a player must **opt in** to use it, it is validated in that
   opt-in state, and only once proven does it flip to default-on and the short-lived release flag
   is retired. A player is never silently enrolled into an unfinished experience, and turning an
   experiment off never destroys what they did while it was on. (This is the game-facing edge of
   the portfolio-wide **feature-flag-first delivery** rule.)
3. **No power/wealth inflation, no ecosystem corruption.** A dupe, a runaway drop rate, or a
   botched economy change does damage that cannot be un-printed without the very reset the game
   forbids — so economic integrity is engineered at the root, not patched after the fact:
   transactional integrity, idempotency and an audit trail are day-one requirements. Migrating
   *content and data* forward is expected; letting *value* leak is the thing that is never allowed.

**The collision to keep front of mind: WoW/Diablo-4's answer to inflation IS the reset** (D4 wipes
seasonally; WoW squishes stats). Both are forbidden, so economics come from **Guild Wars 2**
instead: horizontal progression, a ceiling that never rises, bound loot, no trading/auction house
(kills RMT, botting and dupe *value* at the root), hard sinks. WoW/D4 texture, GW2 economics.

### Quality bar — it has to resemble a AAA game

**Maintainer direction (2026-07-18)**, given after the first foliage pass shipped as untextured
engine primitives in flat colours: *"This needs to resemble a AAA game, so that is unacceptable.
Same goes for all other parts of the game and design."* This is a standing constraint of the same
rank as the product law above, and it outranks velocity, convenience, and an agent's own sense of
"done".

**The bar.** Every player-facing surface — models, materials and texturing, lighting, VFX,
animation, audio, UI/UX, world and level composition, camera, game feel — **and the design behind
it** must look and play like it belongs in a shipped AAA title. **"Functional but basic" is a
defect, not a milestone.** A system that demonstrably works while looking like programmer art has
not met the bar; it has only earned the right to be finished.

**Green tests are not the bar.** Machine verification proves a thing is *correct*; it can never
prove it is *good*. So a player-visible change is judged on the **rendered frame and the felt
experience**, not on the suite: look at it, play it, and compare it against a named AAA reference.
**Attach the frame.** A PR carries an inspectable screenshot, captured frame or short clip of the
actual change, the reference it is judged against, and the remaining gap — because a written claim
that "I looked at it and it's fine" is self-attestation, and self-attestation is exactly what let a
field of grey primitives ship. A green suite plus a frame that reads as placeholder is a PR that is
**not ready**.

**How to produce that frame.** CI runs `client/tools/frame_capture.tscn` on player-visible PRs and
publishes the rendered vantages as a **build artifact** — so the evidence is reproducible on a known
machine rather than dependent on whoever happened to run the game. Point a reviewer at that artifact.
Locally the same tool works windowed (`WAR_SHOT_DIR=… WAR_SAVE_PATH=… godot --path client
res://tools/frame_capture.tscn`); a **headless run renders nothing**, and the tool refuses to run
headless rather than emit a blank frame. Its vantages are fixed on purpose: evidence is only
comparable across commits if the camera does not move, and one flattering angle hides a regression
that another exposes.

**The tells that the bar is being missed** — all four were true of the first foliage pass, and are
the concrete evidence behind this section:

1. **Engine primitives standing in for art** — a sphere as a shrub, a box as a bone pile.
2. **Flat single-colour materials** — one `albedo_color`, no texture, normal, roughness or
   alpha-cutout detail.
3. **Uniform random scatter** where a real world has clustering, ecotones, variation and
   deliberate composition.
4. **No second-order life** — no wind or sway, no wear, decals, LOD, or silhouette interest.

**Scaffolding is still allowed; it just may not pose as finished.** A deterministic library, a
server system, or a data schema may land while its art matures — that is how this project is built,
and it stays correct. But **player-visible placeholder art does not ship default-on**: it stays
behind a default-off flag (product law 2) or stays out of the world until it clears the bar, and the
PR says plainly that it is below bar and what is missing. Shipping it quietly as though it were done
is the specific failure this section exists to stop.

**Taste is the maintainer's call — and that is not licence to aim low.** Phase 0 is his taste gate
and agents do not self-certify taste. Agents are nonetheless expected to *aim at* the AAA bar, to
judge their own output honestly against it, and to say when they know it falls short — rather than
shipping the first thing that renders and leaving the judgement entirely to him.

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
policing them after the fact — economic corruption, once loose, cannot be recalled without the
reset the game forbids.

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
- **🔴 The MULTI-TARGET (telegraph area) economy is a BALANCE REVIEW, never a CI guard** (maintainer
  direction 2026-07-18, #82 option C). `ability.gd` bounds the *single-target* economy mechanically —
  frozen per-cast power budget per `(role|effect)`, a frozen cast+cooldown cycle floor (so throughput
  is capped at budget/floor), a new category's opening scale bounded against those already shipped,
  plus no-strict-dominance and the append-only ledgers. A cone's wedge became authorable data in #159
  (`cos_half_scaled`), and #163 holds **half** the area problem: a **shipped** cone's wedge may never
  widen (CI compares it against the base revision, and monotonicity composes).
  **What is left unbounded is a NEW cone's opening width** — the one value with no already-shipped
  anchor to measure against. Bounding it means inventing an area-vs-magnitude exchange rate and
  freezing it permanently under the no-resets law, so it stays a **balance review**: choosing a new
  cone's width, or otherwise increasing how many targets one cast reaches, means stating the reach in
  the PR and letting the maintainer approve it. Choosing a new category's scale is his too. **Green CI
  proves only that you did not widen something already shipped — never that a new number is balanced**;
  do not build a guard for the opening width without fresh direction superseding this.
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

The standard this gate judges against is the **[Quality bar](#quality-bar--it-has-to-resemble-a-aaa-game)**
— AAA resemblance. Phase 0 asks whether *generated* art can reach it; the quality bar is what
everything shipped afterwards is held to.

## Maintenance

- **Editor-only scenes are NOT dead code.** Two scenes are deliberately unreferenced by the running
  game and exist as **editor surfaces**: `client/scenes/recipes.tscn` (the character taste gate,
  documented in `recipe_gallery.gd`) and `client/scenes/cave.tscn` (the cave-generation preview
  harness, documented in `cave_system_gen.gd` — a `@tool` rig for judging cave interior/exterior work
  by eye, #124). A repo-wide "no references, therefore dead" sweep will flag both; check the owning
  script's docstring before proposing a deletion, and retire such a scene only when the work it
  supports is finished — saying so in the same change. Anything unreferenced **without** such a
  marker is genuine scaffolding and should go (as `scenes/character.tscn` did in #116).
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
  the seam the replication layer consumes, with its own cross-platform golden) and the
  **replication snapshot** built on it (`server/sim/snapshot.go` — per-observer state plus the
  minimal spawn/update/despawn delta, its own golden pinning the state stream) and the
  **versioned wire codec** that frames that payload (`server/wire/` — transport-agnostic binary
  encoding, fail-closed decode, committed hex goldens pinning the byte layout for the future
  client-side decoder), with the socket transport settled by ADR as **WebSocket over TLS**
  (`docs/design/zone-transport.md` — one codec message per binary frame) and the Agones/Nakama
  layers arriving as later children of the server-foundation epic (#4); `deploy/` (platform manifests) arrives later per the roadmap.
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
- **Adding a test needs NO `ci.yaml` edit:** name the scene `<name>_test.tscn` and put it directly
  under `client/tests/` — CI's "Regression tests" step auto-discovers `client/tests/*_test.tscn`
  (issue #50; the old hardcoded list forced every parallel test-adding PR to collide on one line).
  Each scene must print a `TEST PASS` marker on success and run within the 180 s per-test timeout.
  Two exclusions: `save_fixture_guard_test` runs in its own dedicated named step (the product-law
  surface, kept loud/separate), and a test can be temporarily skipped by adding its basename (no
  `.tscn`) on its own line in the optional `client/tests/ci-skip.txt` (blank/`#`-comment lines
  ignored) — a rarely-edited escape hatch, so the run line itself stops changing per-test.
- **Boot tests isolate the save via `WAR_SAVE_PATH`:** a test that boots `main.tscn` to exercise the
  first-run character creator would otherwise run against the player's real `user://character.json`.
  It must NOT clear-and-restore that file (a run killed mid-test strands the only copy — no-resets
  law). Instead the game resolves its save location through `CharacterStore.save_path()`, which
  honours the `WAR_SAVE_PATH` env override (unset in production — the seam is inert). Boot tests use
  the `SaveIsolation` helper (`tests/save_isolation.gd`) to point the game at a throwaway
  `user://*_boot_probe.json` before instantiating the scene, then assert the real save stayed
  byte-identical; `tests/save_path_seam_test` pins the seam contract itself. A developer running the
  suite on a machine with a played save can also `export WAR_SAVE_PATH=/tmp/probe.json` to keep it
  fully out of reach.
- **Validate the server before every PR:** from `server/`, `gofmt -l .` (must print nothing),
  `go vet ./...`, `go test -race ./...` (includes the tick-determinism and golden-hash tests), and
  `go build ./...`. The `Server CI (Go)` job runs exactly this and feeds the `CI - Required Checks`
  aggregate. Simulation determinism is a product-law requirement: the sim is integer-only with no
  wall-clock or unseeded randomness in the authoritative path, and changing the committed golden
  hash (`server/sim`) is a deliberate, reviewed act — never a rubber-stamp.
- **Determinism:** world generation is seeded (`WorldGen.WORLD_SEED`) — the same world every boot.
  Never introduce wall-clock or unseeded randomness into generation; differences between builds
  must be attributable to code.
- **Player-visible work is judged on the frame, not the suite:** before calling a player-visible
  change ready, render or play it, look at it, and judge it against the
  **[Quality bar](#quality-bar--it-has-to-resemble-a-aaa-game)** (AAA resemblance). The PR must
  carry **evidence a reviewer can inspect** — an attached screenshot, captured frame or short clip
  of the actual change — together with the **named AAA reference** and the **remaining gap**. A
  claim with no attached frame is self-attestation, not evidence, and does not satisfy this.
  Below-bar player-facing work does not ship default-on.
- **Dev log is a contract:** every player-visible change adds a `DevLog.ENTRIES` entry (newest
  first) in the same PR — the maintainer watches progress by playing, and the dev log is that
  surface. Write the entry's `version` as the version the change will ship in (the next
  semantic-release bump implied by your commit type). **Do NOT hand-edit `DevLog.VERSION` or
  `config/version` in `project.godot`** — release builds are stamped from the release tag (below),
  so a hand-bump only drifts from the real version.
- **CI, CD and releases:**
  - `ci.yaml` (`pull_request` + `merge_group`) lints, tests and analyses. It is the gate on a
    change. Its macOS export job is **build verification** — proof the project still exports and
    the exported app boots — not a distribution channel; that artifact has no version identity.
  - `release.yaml` (`push` to `main`) calls the shared
    `devantler-tech/actions/.github/workflows/create-release.yaml`, which runs **semantic-release**
    against the root `.releaserc`. Conventional-Commit types decide the bump (`fix:` → patch,
    `feat:` → minor, `type!:` or a `BREAKING CHANGE:` footer → major; `chore:`/`docs:`/`ci:` cut
    nothing). **The `type!:` form only works because `.releaserc` configures it**
    (`parserOpts.breakingHeaderPattern` + a `breaking: true` release rule): semantic-release's
    default Angular preset recognises only the `BREAKING CHANGE:` footer, and a bare config gives
    `feat!:` **no release at all** — a breaking change would ship silently unversioned. Do not
    "simplify" that block away. The `conventionalcommits` preset would handle `!` natively but is
    **not** an option: it needs `conventional-changelog-conventionalcommits`, which the shared
    `create-release.yaml` (`npx semantic-release@25.0.3`, no install step) does not provide. It tags
    `vX.Y.Z` **and** creates a GitHub Release (as a draft — see below). It runs under a GitHub App
    token, not `GITHUB_TOKEN` — that is what lets the pushed tag trigger a downstream workflow at
    all; a `GITHUB_TOKEN` push never starts another workflow run.
  - **Releases are cut as DRAFTS, and CD is triggered by the TAG — both forced, not stylistic.**
    Two independent constraints pin this down, and each was learned by getting it wrong:
    1. **Immutable releases.** Once a release is published its assets are frozen and
       `gh release upload` fails with `HTTP 422: Cannot upload assets to an immutable release`. So
       the order must be build → attach → publish, and the release must still be a **draft** while
       CD runs — hence `.releaserc`'s `draftRelease: true`. The original `release: published` →
       attach design failed on the very first release (v0.2.0 shipped asset-less as a result).
    2. **Actions ignores draft release events.** `on: release: types: [created]` is the obvious
       pairing for (1), but the GitHub Actions docs state: *"Workflows are not triggered for the
       `created`, `edited`, or `deleted` activity types for draft releases."* A draft would sit
       unpublished forever. Note this is an **Actions-specific** restriction — the underlying
       *webhook* does fire for drafts, so the webhook docs alone will mislead you here.

    `push: tags` is the only trigger that both fires and leaves the release a draft, which is
    exactly why every other repo in the org uses it. **Do not "simplify" the trigger to a release
    event.** CD publishes the draft as its final step. Because semantic-release pushes the tag
    *before* creating the draft, CD polls for the draft (after the build, so it has normally
    appeared long since) and fails closed if it never does.
  - `cd.yaml` (`push: tags: v*`) production-builds the macOS client, **stamps the release
    version** into `config/version` and `DevLog.VERSION` at build time, verifies the exported app
    boots reporting `BOOT_OK v<version>` (the proof the stamp reached the shipped binary), and
    attaches the zip to the Release. `workflow_dispatch` with a `tag` input re-runs it for an
    existing release.
  - **GHCR is the origin of record for updates** (maintainer direction 2026-07-18, closing the open
    host decision in `docs/design/distribution-and-self-update.md`). CD publishes the released
    client to `ghcr.io/devantler-tech/world-at-ruin/client` as an **OCI artifact**, tagged with the
    bare version plus `latest`, and **cosign-signs it by digest** (keyless, GitHub OIDC). The
    **digest** is what the updater pins — never the mutable tag. OCI is required rather than merely
    preferred: GitHub Packages has no generic/raw-file registry, so an OCI artifact is the only way
    a `.app` zip enters it. The GitHub Release asset remains the *install* download; GHCR is the
    *update* origin.
  - **The release publishes LAST, after the artifact jobs.** `publish-release` depends on both
    `publish-macos` and `publish-ghcr`, so the draft goes public only once the build is attached
    *and* the GHCR origin exists and is signed. Publishing earlier would leave a public, immutable
    release whose update origin does not exist — unrepairable, since releases are immutable. If an
    artifact job fails the release simply stays a draft, which is the safe state; fix the cause and
    re-run CD via `workflow_dispatch` with the tag.
  - **GHCR packages are private by default**, and that failure is invisible from the publishing
    side — the push succeeds and only the *player* gets a 401. `verify-ghcr-public` therefore checks
    reachability with a **credential-free** request (no `docker login`, no token, `permissions: {}`):
    every step in `publish-ghcr` runs authenticated and so proves nothing about public access.
    **Never "fix" a failure here by making the check authenticated** — that restores a guard that
    passes vacuously.
    It is deliberately **non-blocking**: it is not a dependency of `publish-release` (maintainer
    direction 2026-07-18), because nothing consumes GHCR yet — the in-client updater is not wired to
    it — so a private package harms no player today while blocking every release on it would. The
    job going red is the signal; the release still ships. **Make it blocking the moment the updater
    actually resolves against GHCR**, at which point an unreachable origin is a real defect (tracked as #141).
  - **Homebrew cask** — CD renders `Casks/world-at-ruin.rb` and opens/updates ONE evergreen PR on
    `devantler-tech/homebrew-tap`. It runs **after** `publish-release`, because the cask's `url`
    points at the release asset and a draft release's asset URL 404s for `brew install`.
    **`auto_updates` is deliberately ABSENT**: it tells Homebrew "this app updates itself, do not
    upgrade it", and there is no working in-client updater yet (`update_decision.gd` is pure
    decision logic). Declaring it now would make `brew upgrade` skip the cask and strand players on
    the version they installed. Add it only once the self-updater ships (#106). The `postflight`
    quarantine strip is **mandatory, not cosmetic** — the build is ad-hoc signed
    (`codesign/codesign=1` with an empty identity), so Gatekeeper blocks it otherwise.
    No `verified:` on the `url`: `brew audit --strict` rejects it when the download and homepage
    domains match, which they do here.
  - The version is therefore **derived, never maintained**. The in-tree constants are dev values;
    only a released build carries a real version.
  - **`CI - Required Checks` is the repo's single required status context.** Renaming or removing
    that job wedges every PR in the repo — treat its name as load-bearing.
- **Scripting:** GDScript in the Godot project; **bash or Go everywhere else — never Python**
  (portfolio constitution). The Phase-0 Blender pipeline is the sole, explicitly-settled exception
  (`bpy` is Python by nature); keep it isolated under `tools/artgen/` when it lands.
- **Security scanning — GDScript is NOT CodeQL-analysable, and no configuration changes that.**
  CodeQL supports a fixed extractor set (C/C++, C#, Go, Java/Kotlin, JS/TS, Python, Ruby, Rust,
  Swift, GitHub Actions). GDScript is not in it, and language support is a property of the
  extractors, not of configuration — an advanced setup cannot add one that does not exist. So the
  repo's dominant language is permanently outside CodeQL's reach; this is **not** a
  misconfiguration, and it does not need re-researching. What *is* covered: the repo runs CodeQL
  **default setup** over `actions`, `go` and `python` (`tools/artgen`), extended suite. **Prefer
  default setup over an advanced-setup workflow here** — the two are mutually exclusive, and
  default setup emits both code-scanning *and* code-quality results, which this repo's rulesets
  both require; replicating that from advanced setup needs `analysis-kinds`, an input
  `codeql-action` documents as internal and subject to change.
  **Before adding a language, scan it locally first.** `Require code quality results` is set to
  `severity: all` and `Require code scanning results` to `alerts_threshold: all`, so a *single*
  finding of any severity blocks every open PR in the repo. Preview with
  `codeql database create <db> --language=<lang> --source-root=<dir>` then
  `codeql database analyze <db> ... codeql/<lang>-queries:codeql-suites/<lang>-code-quality.qls`
  (and `-security-extended.qls`), fix what it finds, and only then enable. Enabling `python`
  without this would have frozen the repo on three `tools/artgen` findings. Note also that
  adding a language leaves existing PRs blocked until each re-runs with the new analysis — that is
  expected, and a push (or a merge of `main`) clears it.
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

- **P0 — product law:** any change that could wipe/strand/devalue player state — a destructive
  migration, save-format break, or non-backward-compatible protocol change **not gated behind an
  announced, player-visible deprecation** — or that introduces power/wealth inflation, ships an
  unsettled/experimental feature **not default-off behind an opt-in flag**, or adds
  GPL/AGPL/commercial-licensed content.
- **P1 — correctness:** unseeded/non-deterministic world generation, client-authoritative gameplay
  state (once networking exists), physics entering the authoritative path, or a player-visible
  change with no dev-log entry.
- **P1 — quality bar:** any **player-facing** surface — art, world composition, lighting, VFX,
  animation, audio, UI/UX, camera, game feel, or the design itself — that ships **default-on** while
  still reading as placeholder (engine primitives as art, flat untextured materials, uniform
  scatter, no second-order life, and the equivalents of those outside art). **Separately P1 on its
  own:** a player-visible PR carrying **no inspectable frame evidence, or no named AAA reference and
  stated gap** — including one that simply *omits* any readiness judgement, not only one that argues
  from green tests. See **[Quality bar](#quality-bar--it-has-to-resemble-a-aaa-game)**.
