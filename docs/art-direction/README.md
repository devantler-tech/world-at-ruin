# Art direction — the target every player-visible change is judged against

`AGENTS.md`'s [Quality bar](../../AGENTS.md#quality-bar--it-has-to-resemble-a-aaa-game) requires every
player-visible PR to name the reference it was judged against and state the remaining gap. This
page is that reference set. Before this existed the requirement could not be met, so each agent
judged its own work against a private idea of the target — which is how a cave one agent called
"good indie" reached the Phase 0 gate and was rejected.

**The bar is AAA; the reference need not be.** Our output must look like it belongs in a shipped AAA
title — that is unchanged and non-negotiable. But "AAA" is a funding-scale label, so it was never a
sensible filter on *citations*: none of the maintainer's own three anchors would pass it. The
distinction is settled below.

Use it two ways: **pick the target before you build**, and **name the specific reference plus your
gap in the PR** when you are done.

**How references are named.** No copyrighted image is committed here, and a link to a game's home
page does not show you the target — those games each span many incompatible art styles. So each
reference names a **specific zone, screen or asset set** you can find and look at (in official media
or in the game itself), with a link to the title's official page for identification only. When you
cite one in a PR, say which specific reference you used, not just the game.

**Scope.** The quality bar covers every player-facing surface. This page's **visual** targets carry
the maintainer's own three anchors, because that is what the failed gate was about and what his
verdict specified.

**Audio, camera and game feel have anchors too**
([#234](https://github.com/devantler-tech/world-at-ruin/issues/234)), so no player-visible PR is left
with nothing to cite. They are **extensions of references the maintainer already chose**, not new
titles picked by an agent — deliberately, because inventing fresh targets is how one agent's taste
becomes the standard everyone is judged against, which is the failure #221 exists to end.

| Surface | Anchor | What to take from it |
|---|---|---|
| **Audio** | WoW and Guild Wars 2 zone ambience; Fatekeeper for combat and interiors | Ambience that states the biome before the UI does; impact sounds with weight and material (stone, iron, cloth read differently); salvaged tech that hums wrongly rather than beeping cleanly |
| **Camera** | WoW and Guild Wars 2 third-person | Framing that keeps the character readable while showing the world; predictable collision behaviour indoors and in caves; no fighting the player for control |
| **Character motion** | [Kingmakers — Official Announcement Trailer](https://www.youtube.com/watch?v=OvezgDni8z4&t=66s), 1:06–1:10 | A continuous third-person sprint: the full-body stride stays readable and the follow-camera tracks without hiding the body motion. Borrow the locomotion/camera relationship only, never the modern protagonist's look. |
| **Game feel** | Guild Wars 2 and WoW for MMO combat rhythm; Fatekeeper for melee weight | Telegraphed windups readable at a glance (already the settled combat design), committed animations with recovery, hits that land with weight rather than registering as numbers |

The character-motion row is a bounded locomotion anchor, not a universal answer for every animation.
A motion PR must cite a linked **moving artifact**, an exact start–end time range, and the cue it is
judging (for example stride, idle, windup, recovery or camera tracking). A still frame or a whole-title
reference cannot establish motion quality. When 1:06–1:10 does not show the changed cue, cite another
moving artifact from the approved titles rather than stretching this sprint beyond what it proves.

**🔴 Naming the game is NOT a citation here either — the same rule applies.** The rows above name a
*title and what to take from it*, exactly as the visual anchors do; they are not themselves
references. "Judged against WoW zone ambience" spans two decades of content and puts an agent right
back to picking privately. So an audio, camera or game-feel PR **cites a specific, inspectable
artifact and links it**: a named track or a named zone's ambience, a specific encounter, or a clip at
a stated timestamp. A reviewer must be able to hear or watch the same thing.

This page deliberately does not pre-select those artifacts, for the same reason it does not pin
visual plates: **no agent here has heard or played this media**, and naming a track to satisfy a rule
about evidence would fabricate the evidence. The citing PR does the selecting, and carries the link.

**Marked plainly: these three are agent-proposed, unlike the maintainer's three visual anchors.** They
are extrapolated from titles already settled as this project's style references, and they hold until
he says otherwise. If he redirects, this table changes and the PRs that cited it do not become
retroactively wrong.

The rule binds changes that alter the **player-facing result**. Refactors, infrastructure, tooling and
tests on those subsystems are untouched, being not player-visible changes in the first place.

---

## The one-line style

**A medieval world that outlived a technological age and is scavenging the wreckage.** Medieval
wins every tie. Technology appears as relic, salvage and artefact — forged, scavenged,
half-understood — never as clean manufactured sci-fi.

Two axes, from [`AGENTS.md` → Setting & story](../../AGENTS.md#setting--story--a-medieval-futuristic-world-at-rebirth):

- **Medieval is the baseline.** Worked materials, hand-craft, wear, weight.
- **Futuristic is the ceiling, and it is rationed.** [WildStar](https://en.wikipedia.org/wiki/WildStar)
  marks the furthest the sci-fi side may go, and it is a limit rather than a destination. Its
  servers closed in 2018, so reference material is archival.

A frame passes the setting test when a stranger reads it as fantasy-medieval first, and reads any
technology in it as **handcrafted or salvage-derived** — forged, scavenged, half-understood — rather
than as clean manufactured sci-fi.

**The test is how it reads, not where it came from.** `AGENTS.md` permits technology outright, up to
laser swords and blasters, and asks only that it still feel medieval; "forged, scavenged,
half-understood" is its when-in-doubt default. So a smith reforging inherited machinery into a relic
weapon **passes** — the object is newly built and that is fine, because its construction reads
hand-worked and salvage-derived. What fails is the factory finish: injection-moulded panels, seamless
composites, machined repetition.

## The maintainer's named references — these three anchor everything below

Given directly on #221, one per surface. **These outrank any reference an agent picks**, including
the per-surface comparables further down this page, which are supporting analogues rather than the
target itself.

**🔴 A title is not a reference — cite the exact image you used.** Each of these games spans many
looks, so "judged against Fatekeeper" is very nearly as private a target as naming nothing: two
agents can pick unrelated scenes and both believe they complied. This page deliberately does **not**
pick one canonical frame per anchor, for a reason worth stating — no agent here has viewed this
media, and inventing a plate number or a trailer timestamp would be fabricating evidence to satisfy a
rule about evidence.

The fix is on the citing side, and it is enforceable: **a PR names the anchor *and* links the
specific image it compared against** — a direct URL to one screenshot in the game's official media
gallery, one Steam store screenshot, one illustration, or one trailer frame at a stated timestamp. A
reviewer can then open the same image. **A citation naming only the title is incomplete and a
reviewer should treat it as no reference at all.**

Where to find each anchor's media, so the citation is easy: Numenera's illustration plates in its
corebook and art-book spreads; Kingmakers' screenshot set on its Steam store page; Fatekeeper's
gallery and trailers on its official site. For the character look the maintainer also pointed at a
**Google Images search for "futuristic medieval"** as the look he wants — cite the individual image,
not the search.

| Reference | Anchors | Why it is the right anchor |
|---|---|---|
| **[Numenera](https://numenera.com/)** — Monte Cook's Ninth World | **the world** | A far-future Earth whose people live medievally amid the incomprehensible remnants of prior civilisations, treated exactly as magic is treated in a fantasy setting. That *is* the one-line style above, already written down by someone else and illustrated. Its native tech level is medieval and its technology reads as inherited and half-understood rather than factory-made — which is the setting test above. |
| **[Kingmakers](https://store.steampowered.com/app/2109770/Kingmakers/)** | **character look** | Its knights carry a **legible armour tier ladder** — steel, hardened steel, then a gold titanium alloy — where the tier is readable from the surface itself rather than from a stat sheet. That is precisely what #222's equipment slots need, and its futuristic-against-medieval juxtaposition on a single figure is the clash this game has to sell. |
| **[Fatekeeper](https://fatekeeper.thqnordic.com/)** (THQ Nordic, 2026) | **the visual target** | Dark-fantasy art direction carried by materials and light: damp stone, weathered wood, rusted armour, dramatic key lighting, and magic that acts as a real light source rather than an overlay. Its gear reads Viking-derived amid statuary from other cultures, so the world feels mythically layered rather than one consistent period — the same "many prior ages" read the Ninth World needs. |

**Read Numenera as concept art, not as screenshots.** It is a tabletop game, so its references are
illustration plates and art-book spreads. That makes it the right anchor for *what the world is* —
silhouette, scale, the strangeness of the relic — and the wrong one for real-time material or
lighting technique, which is Fatekeeper's job.

**🔴 Cite an execution reference alongside any conceptual anchor.** Numenera is a tabletop product,
so a Numenera plate can show *what the world is* but cannot show how it must look rendered in real
time. Where the primary anchor is conceptual, the PR therefore cites **two** references: the
conceptual anchor for *what to build*, and a **shipped real-time comparable for how it must be
executed** — from that section's supporting analogues (for the world: WoW's Outland, Guild Wars 2's
Crystal Desert, Elden Ring's Caelid), or another shipped title that fits better.

**The Ninth World has been shipped as a game once — use it.**
[*Torment: Tides of Numenera*](https://en.wikipedia.org/wiki/Torment:_Tides_of_Numenera) (inXile,
2017) is set in exactly this setting and won Game Informer's 2017 **Best Setting** award, so it is
the one existing example of somebody else solving *our* problem: rendering inherited hyper-technology
as a lived-in medieval world. Cite it for **what a Ninth World location contains and how strangeness
is staged** — the scale of the relic, what people build against it, how alien tech reads as
furniture rather than as sci-fi.

Two limits, so it is used for the right thing: it is an **isometric** RPG, so it says nothing about a
third-person camera or character read at our distance; and its 2017 rendering is **below** our
fidelity target. It is a *setting* execution reference, not a fidelity one — that job stays
Fatekeeper's.

### None of the three anchors is a AAA production — and that is fine, now stated as fact

Earlier revisions of this page danced around this because no agent had checked. Checked now:

| Anchor | What it actually is | AAA? |
|---|---|---|
| **Numenera** | Tabletop RPG (Monte Cook Games). Its video-game adaptation is *Torment: Tides of Numenera* (inXile, 2017). | No — not a video game |
| **Kingmakers** | Redemption Road Games, published by tinyBuild (independent). **Still unreleased** — Early Access slipped from 2025. | No |
| **Fatekeeper** | Paraglacial — a **13-person** German studio, debut original title, THQ Nordic published. Steam Early Access since 2026-06-02. | No |

["AAA" is an informal budget-and-publisher-scale label](https://en.wikipedia.org/wiki/AAA_(video_game_industry))
with no certifying body; 2024–25 greenlights averaged ~$200M. It describes **how a game was funded**,
not how it looks — so demanding that citations be AAA imports a finance criterion into an aesthetic
judgement, and would reject all three of the maintainer's own choices.

**So `AGENTS.md` now reads the way he plainly meant it:** the **AAA bar applies to our output**, and a
citation is valid when it shows the **right look** — whatever the studio's size. That is settled
([#234](https://github.com/devantler-tech/world-at-ruin/issues/234)), and it is not a relaxation: the
quality bar and the P1 blocker are untouched.

**Stated precisely, because the looser version overstates it.** A *visual* PR was never wholly stuck:
this page has always carried supporting analogues that would pass even a strict AAA reading — WoW,
Guild Wars 2, Diablo IV, Elden Ring, Horizon — so one of those could be cited alongside the primary
anchor. Two narrower things were broken, and they are what changed:

- **The maintainer's own three anchors did not qualify**, so citing *the actual named target* as the
  primary reference was a violation, and compliance depended on bolting on a second title purely to
  satisfy a funding criterion.
- **Audio, camera and game feel had no reference at all** — genuinely unsatisfiable, and the reason
  this issue was filed.

**One practical consequence when citing.** Kingmakers is unreleased, so its only public media is
**pre-release marketing** — trailers and store screenshots, which are lit and framed to sell. Treat it
as a reference for *armour tiering and silhouette*, and do not read its screenshots as evidence of
achievable real-time fidelity.

**Take Kingmakers' armour, not its protagonist.** Its player character is a modern military
operator, which is emphatically not this game's look. What transfers is the knights: tiered plate,
material-readable rank, and the sight of hard technology beside hand-forged steel.

### ⚠️ Fatekeeper sits above the fidelity ceiling this page argues for — say so in PRs

This is a genuine tension and it should not be quietly averaged away. The ceiling below argues for
stylised-realistic (WoW / Guild Wars 2 with Diablo IV's grime); Fatekeeper is near-photoreal PBR,
closer to the Horizon end the ceiling rules out.

**The gap has at least two distinct components, and conflating them misdirects work.** An earlier
framing implied pure scale — big-budget fidelity we cannot match. That is not right either:
Fatekeeper is **13 people**. But "so it is only the engine" over-corrects, so both parts are named:

1. **An engine gap.** Fatekeeper runs Unreal Engine 5.6 leaning directly on **Nanite, Lumen and
   Virtual Shadow Maps**; Godot 4.7 Forward+ has no equivalent of any of the three. Micro-detail
   preserved by virtualised geometry, and bounce light resolved in real time, are not reachable here
   by trying harder.
2. **An authoring-model gap, which is the project's actual bet.** Those 13 people are **human artists
   hand-authoring assets**. Our constraint is stricter by design: `AGENTS.md` requires all art be
   **authorable as code** — the reason Unreal was rejected at all is that its assets are binary —
   and it says plainly that photorealism is unreachable without a human sculptor. So a hand-sculpted
   result is not evidence that the same result is procedurally reachable. That question *is* the
   unproven bet, and this page must not quietly answer it.

**What this does rule out:** "we are too small" as a bare excuse. Team size alone does not explain the
gap, since 13 people cleared it. What may legitimately be cited is the **authoring model** — and then
specifically, naming which part of the look resists procedural authoring, rather than as a general
shrug.

**Where the result is reachable regardless:** authored material response, baked and hybrid lighting,
deliberate composition, silhouette and value control. None of these need Nanite or a sculptor, and
they are most of what separates the Phase 0 frames from the target.

So treat Fatekeeper as a **direction-of-travel target for art direction and material behaviour** —
dark-fantasy composition, weathered named substances, light doing the dramatic work — and **not** as
a fidelity-parity target for texel density or real-time GI.

**The engine-feature diagnosis is researched fact; where to set the ceiling remains his call** — he
named the reference and did not rule on the ceiling. If the intent is that the ceiling itself should
move, that is his call
to make and this section should be rewritten to match.

## The fidelity ceiling — stylised, and that is an advantage

We render in Godot 4.7 Forward+. There is no Nanite, no Lumen, no commercial Megascans-scale scan
library and no art team. Chasing photorealism with those constraints produces a worse-looking game,
not a more ambitious one.

**Be precise about the scan question, because it cuts the other way.** `AGENTS.md` sanctions the CC0
libraries **Poly Haven** and **ambientCG** as approved inputs, so scanned source data is not
forbidden — it is simply **not wired into the pipeline today** (those names appear nowhere in the
tree outside `AGENTS.md`; there is no downloader, import step or provenance record). So material work
is free to reach for them, and doing so is a legitimate route to closing #223. What we lack is the
breadth and per-asset authoring budget of a commercial library, not permission to use scans.

So the target is **stylised-realistic**: [World of Warcraft](https://worldofwarcraft.blizzard.com/)
and [Guild Wars 2](https://www.guildwars2.com/) territory, with
[Diablo IV](https://diablo4.blizzard.com/)'s grime on the materials — not
[Horizon Zero Dawn](https://www.playstation.com/en-us/games/horizon-zero-dawn/)'s surface fidelity.

This is the strategically right call for a game whose art is generated by code, not just the
affordable one. **Stylisation is a set of explicit rules; photorealism is measured data.** Painted
stylisation says *darken the crevices, brighten the worn edges, keep the palette disciplined, put
detail where the eye lands* — every one of those is arithmetic a shader can do. Photorealism asks
what this specific granite actually reflects, and the honest answer only comes from a scan we do
not have.

**That is a bet, and it is still unproven — do not write it up as a fact.** `AGENTS.md` calls
generated art reaching the AAA bar the project's *"one unproven bet"*, and Phase 0 exists precisely
to test it. Nothing here settles that. What this page claims is narrower and defensible: **if**
generated art can reach the bar at all, the stylised target is the reachable direction to aim it,
because its rules can be written down and the photoreal ones cannot. Aiming at photorealism instead
would guarantee the uncanny middle we are currently sitting in — which is an argument about
*direction*, not evidence that the destination is reachable.

## Why the current output misses — the thing to actually fix

The Phase 0 frames do not fail on resolution or polygon count. They fail because **the world in them
— ground, rock, cave — is a smooth interpolation of noise, so nothing on screen looks like anyone
decided it.**

That is the whole diagnosis, and it reframes every gap issue below. The fix is not more octaves of
the same thing.

**To be precise about what is being blamed — name the real generators, or the fix aims at the wrong
code.** The terrain is **Simplex FBM** (`world_gen.gd:105-108`: `TYPE_SIMPLEX`, `FRACTAL_FBM`, 4
octaves), and the cave is a **smooth-minimum SDF field** with Simplex-FBM wall perturbation
(`cave_system_gen.gd:145-151`, blended by `_smin` at 168-179). Neither is value noise — value noise
appears only inside the material shaders, and shader breakup cannot explain the cave's wet-clay
*geometry*.

What the two share, and what is actually being blamed, is that both are **smoothly interpolated and
therefore edgeless by construction**: gradient noise is C¹-continuous, and a smooth-min is explicitly
designed to round away the crease where two fields meet. That is a property of the blend, not of
procedural generation as such. Procedural technique is the **route** here, not the problem. Cellular/Worley
noise, thresholded fields, domain partitioning, masks, and Voronoi fracture all produce hard
boundaries and genuinely distinct regions, and those are exactly the tools the gaps below want.
Read "stop using noise" nowhere in this page; read "stop using *only smooth interpolated* noise".

Authored art has edges, named substances, deliberate contrast and a focal point. The work is making
the generator **produce decisions**, not smoother gradients.

Concretely, authored-looking output has four properties that smoothly interpolated fields — gradient
noise or smooth-min SDFs alike — do not produce on their own:

1. **Edges.** Rock fractures along planes and breaks at angles. Smooth signed-distance blobbing
   reads as wet clay, which is exactly how the cave currently reads.
2. **Named substances.** A viewer can point at a surface and say what it is made of. If two
   surfaces differ only by albedo tint, they are one material in two paints. The captured cave and
   terrain are **not** quite that — their shaders do vary roughness and perturb normals (see the
   ⚠️ under Materials below) — but the variation is too small in magnitude to read, so the frame
   lands in the same place a tint would. Fix the magnitude and character, not the absence.
3. **Deliberate contrast.** Value and hue range are composed, not averaged. The cave frame occupies
   a narrow band of one orange, so fog and material and rock all collapse into the same wash.
4. **Composition.** Something is the subject. Landmarks, focal lighting and silhouette give the eye
   somewhere to go.

## Per-surface targets

Each block names the target, the reference to look at, and tells you can check on a rendered frame.

### Materials and texture — the highest-leverage gap (#223)

**What actually ships today — the inventory, because #223's "no textures at all" is too broad.**
Committed skin textures exist (`client/assets/characters/humanoid_kit/skins/*.png`, loaded as
`albedo_texture` in `character_factory.gd`), and `foliage_art.gd` generates leaf, blade and stone
`ImageTexture`s at runtime. **Debris is textured too** — `debris.gdshader:34` samples `albedo_tex`,
which `foliage_art.gd:93-101` fills with generated stone textures for bone piles and rubble.

What is arithmetic-only is **the ground, the cave rock and the masonry** — `terrain.gdshader`,
`cave_rock.gdshader` and `masonry.gdshader` compute colour from noise with no texture at all. That
is the surface area this gap covers; say "the ground, cave rock and masonry have no textures", not
"the game has none", and do not scope #223 to include the already-textured debris.

**The masonry was a third category until #263, and the omission mattered.** Ruins and the shrine
were neither textured nor arithmetic: every column, lintel, monolith and pedestal shared one
`StandardMaterial3D` with a single `albedo_color` and a single roughness scalar — a constant, not
even noise. An inventory split only into "textured" and "arithmetic" had nowhere to put that, which
is how the most-looked-at surfaces in the game went unlisted while #223 pointed at the two surfaces
that had *already* been given normal and roughness. When taking a slice of this gap, check what a
surface actually carries rather than inheriting the split above.

**Target.** Every surface reads as a named substance: ash, fractured granite, rusted iron, tanned
leather, coarse woven cloth. Substance shows up in three separable channels:

- **Colour pattern**, not tint — veining, mineral streaks, dye unevenness, stains.
- **Grain at two or more scales** in the normal — metre-scale form, centimetre-scale bite. Grazing
  light catching grain is the single strongest cue that a surface has substance.
- **Roughness variation** — polished where hands and boots touch, matte where dust settles. Uniform
  roughness is what makes two different materials light identically.

**Reference — primary: [Fatekeeper](https://fatekeeper.thqnordic.com/).** This gap is exactly what
it is the named target *for*. Look at its damp stone, weathered wood and rusted metal: each is a
named substance carrying colour pattern, multi-scale grain and varying roughness, which is the
three-channel test above. Aim at that behaviour, not at its texel budget (see the ceiling note
above).

Supporting analogues: WoW's **Outland / Hellfire Peninsula** is the closest painted analogue to
Ashfall Reach — a shattered orange wasteland that still separates rock from ground from sky; Diablo
IV's **Dry Steppes** for how far to push grime, rust and wear without losing readability.

**⚠️ The channels are not simply missing — check before you file that as the gap.**
`terrain.gdshader` already perturbs `NORMAL` (its final `NORMAL =` assignment, at the end of
`fragment()`) and varies `ROUGHNESS` by slope and grain (the `ROUGHNESS = clamp(mix(ash_roughness,
…))` assignment above it), and mixes ash against rock by slope. Named by symbol rather than by line
number on purpose: the line numbers this used to carry (117 and 131) had drifted hundreds of lines
into the noise helpers, pointing anyone following this guidance at unrelated code. All three
channels are being touched, and the
result still measures flat. So the gap is **the magnitude and character of the variation, not its
absence** — the same trap as the torch below, where the layers exist but do not read.

**What genuinely is absent, and it is the cheap win.** Painted AAA art bakes light into the surface:
crevices darken, raised and worn edges brighten. In a procedural shader that is **curvature-driven
darkening plus convexity-driven edge wear** — two terms derivable from geometry already available.
A grep for curvature, cavity, occlusion or edge-wear terms across all four shaders returns nothing
but one prose comment, so this is a real absence rather than an assumed one. It is most of what
separates "hand-painted" from "noise-tinted".

**Checkable tells — inspect the channels, do not desaturate.** Desaturation cannot tell tint from
substance and gets it wrong in *both* directions: two albedo tints at different values survive
greyscale and look like variety, while two genuinely different materials at equal luminance collapse
and look identical. Instead:

- **View albedo, normal and roughness separately.** A surface with a flat normal and a constant
  roughness is a tint, whatever its colour does.
- **Or move the light.** Rotate the key through a few angles: real grain and roughness variation
  change how the surface reads; a tint looks the same from every angle.
- **Then name every substance in the frame.** Anything you cannot name is not finished.

### World and terrain (#226)

**Target.** A zone you can navigate by memory. Regions of distinct character — ash flat, ravine,
mesa, the first returning greenery — placed as *regions* with transitions between them, not one
fractal blended everywhere. At least one landmark readable from most of the zone.

The settled fiction demands this directly: a world at rebirth is *"a deliberate mix of wasteland and
lush, vibrant zones."*

**That mix is a property of the world, not of every zone.** A deliberately barren opening wasteland
is exactly what the settled sentence asks one half of the world to be, so do not read this as a
licence to push greenery into Ashfall Reach. What a single wasteland zone still owes is everything in
the target above — distinct regions, transitions, a readable landmark, composed value and hue — and
that is what the current biome fails. Judge a zone on variation, landmarks and composition; judge the
wasteland/lush balance across the world.

**Reference — primary: [Numenera](https://numenera.com/).** The Ninth World is the named anchor for
what this world *is*: regions defined by the colossal inherited object sitting in them — a chasm, a
continent-spanning machine, a slab — rather than by terrain noise alone. That is the strongest
available answer to "at least one landmark readable from most of the zone", and it makes the
landmark carry the setting at the same time.

Supporting analogues: WoW's **Elwynn Forest → Duskwood** boundary for how two adjacent zones
announce themselves by palette alone; Guild Wars 2's **Path of Fire / Crystal Desert** for composed
painterly distance in an arid setting; Elden Ring's **Caelid** for a hostile red-orange region that
still reads varied rather than monochrome — the closest comparable to the failure mode measured
below.

**Checkable tells.** From one screenshot, can you say where you are and point toward somewhere
else? Can you tell two locations apart at all?

### Structures, caves and blending (#225)

**Target.** Rock **fractures** rather than curves — planar faces, bedding planes, sharp broken
edges, and scree where the broken material fell. Strata bands read across the formation. Cave walls
carry debris skirts at their base.

Structures **meet** the ground instead of sitting on it: rubble, drifted ash, dirt buildup and
returning vegetation in the seam. A hard silhouette line where mesh meets mesh is the tell that
nothing transitions.

**Reference.** Elden Ring's **Limgrave** ruins and **Siofra River** cavern for stonework that has
settled into terrain over centuries and for cave interiors that are composed rather than tubular;
Diablo IV's **Fractured Peaks** for weathered worked stone.

### Characters, clothing and equipment (#222, #224, #228)

**Target — silhouette first.** An AAA character is recognisable at 30 metres as a black shape.
Smooth cylindrical limbs and a featureless head have no silhouette, which is the current state.

**Progression is part of the look, and it aims the early assets.** The wanderer starts ragged and
messy — From Software's near-naked opening, a scrap of cloth, not a clean T-shirt and slacks — then
earns clothing (socks, underpants, pants, shirt, eyewear), then armour over it (boots, leg, chest,
head, belt, gloves, necklace, 2× rings, 2× trinkets). Eyewear hides when it clips head armour.
**A reference board showing only end-game armour would mis-aim every early-game asset**, which is
why the ragged end of the range is specified here first.

**Materials must differentiate.** Cloth needs folds, thickness and seams; skin needs warmth,
subsurface softness and tonal variation. Right now they share one shading response, which is why
the wanderer reads as a mannequin wearing painted-on clothes.

**Stance and motion (#224).** Weight on one leg, asymmetric arms, a breathing idle. The current
symmetric hands-clasped pose reads as a rig at rest, because that is what it is.

**Motion reference.** The [Kingmakers announcement trailer from
1:06–1:10](https://www.youtube.com/watch?v=OvezgDni8z4&t=66s) anchors a readable full-body sprint and
stable third-person tracking. It does not demonstrate an idle, so #224's breathing-idle work needs a
separate time-ranged moving reference from the approved title set.

**Races are authored identities, not sliders (#228).** WoW and WildStar give each playable race its
own proportions, silhouette, culture and art language — a Tauren is not a tall human. Our creator
instead exposes real-world ethnicity as numeric `phenotype_african / phenotype_asian /
phenotype_caucasian` sliders over one human body, which reads as a taxonomy panel rather than a
character choice — and which is also the mechanism keeping #228's "presets, not races" true.

The direction worth taking to the maintainer: **named peoples of this world's rebirth**, each
art-directed with its own proportions and silhouette, plus an ordinary skin-tone choice like any
character creator has.

**🔴 Change the choice model, never the persisted axes.** Those three phenotype names are shipped
save data — they appear in `golden_recipe_v2.json` and `v3.json`, and `CharacterFactory.validate()`
refuses any recipe naming a blend shape the kit no longer has: *"unknown blend shape … shipped kit
shapes may never be removed"*. Deleting them would fail every existing character and break the
no-resets law outright. So whoever takes #228 **keeps the axes as backward-compatible internal
fields, or ships a versioned zero-loss migration that renders historical recipes identically**, and
changes only what the player is offered. Flagged for the maintainer's steer rather than decided
here — but the compatibility constraint is not a matter of taste, and holds whichever way he steers.

**Reference — primary: [Kingmakers](https://store.steampowered.com/app/2109770/Kingmakers/).** The
named character-look anchor, and it answers the hardest half of this gap: its knights wear a **tier
ladder you can read off the armour itself** — steel, hardened steel, gold titanium alloy — so rank
is visible in the material rather than in a tooltip. That is what makes layered equipment slots
worth having. Take the knights, not the protagonist: he is a modern military operator, which is not
this game's look.

Supporting analogues: [Elden Ring](https://en.bandainamcoent.eu/elden-ring/elden-ring)'s
**starting-class loadouts** (Wretch through Vagabond) for the ragged end of the range and how armour
layers over it — the maintainer named From Software directly for the near-naked start; WoW's
**playable race roster** for identity and silhouette exaggeration across bodies;
[Horizon Zero Dawn](https://www.playstation.com/en-us/games/horizon-zero-dawn/)'s **Nora tribal
gear** for the exact look of *machine salvage worn as ornament by a pre-industrial culture* — the
closest existing match to our brief, though its surface fidelity sits above our ceiling.

**The two anchors bracket the progression.** Elden Ring's Wretch is where a player *starts*;
Kingmakers' gold-titanium tier is the far end they earn. Both ends are now named, which is what
#222's ragged-start rule needs to be checkable rather than a matter of taste.

### Lighting and atmosphere

**Target.** Fog separates depth; it does not paint the picture. The frame needs a key/fill
relationship and a real value range.

**The specific current failure, stated as what was measured rather than as a palette rule:** the
captured cave separates its content on **neither** axis — ~13% of the value range and 6.3° of hue (see
the baseline below). That is the defect to fix, and it can be fixed on *either* axis.

Constant hue is **not** by itself a fault: intensity, direction, occlusion and value separation model
form perfectly well in a monochrome scene, and plenty of shipped night and sandstorm scenes do exactly
that. So the target is **separation, by whichever axis you choose** — not a mandated palette.
Warm-key-against-cool-shadow is one well-worn way to buy it cheaply, and worth trying here precisely
because the value axis is currently doing so little; it is an option, not the rule.

**Checkable tell.** If the frame separates on neither value nor hue, it is flat regardless of how
much geometry is in it.

### VFX

**Target.** Layered, not a single gradient — and the torch shows that *having* the layers is not the
same as their **reading**.

`cave_system_gen.gd` already builds a separate outer flame and hot core (`COL_FLAME_CORE`), attaches
a ranged `OmniLight3D` per torch, and animates both light energy and flame body every frame. So core,
falloff and light-driven flicker **already ship** — do not file them as the gap. Yet in the captured
frame the flame still resolves as a flat opaque triangle, because the layers sit at nearly the same
value and the shape is a hard-edged cone.

So the actual targets are: **soft, non-uniform edges** (alpha falloff rather than an opaque
silhouette), **more value separation between core and outer flame**, and the layers that genuinely do
not exist yet — **drifting embers** and **heat distortion**. This one is worth remembering as a
pattern: a frame can under-read a system that is already there, so check the code before naming a
gap.

### UI and UX (#227)

**Target.** The interface belongs to the world: framed panels, a material (parchment, worked metal,
rune-etched inlay), typographic hierarchy, and icons instead of raw parameter names.

The character creator should present **choices** — named archetypes and portrait presets — with
numeric sliders demoted to an "advanced" section. Thirty-plus programmer-named sliders as the
primary surface is a developer inspector, and the frame shows exactly that.

**Reference.** WoW and Guild Wars 2 character creation.

---

## How to judge a frame

Replaces "I looked at it and it's fine", which is the self-attestation the Quality bar exists to
stop. Run these against your own capture before opening the PR:

1. **Separation** — does the frame separate its content by value, by hue, or by neither? Measurable;
   baseline below.
2. **Silhouette** — render the evaluated subject solid black against a contrasting background, same
   camera and pose. Is it still recognisable as what it is? (Blacking out the *whole* frame just
   gives you a black rectangle — the subject/background boundary is the thing being tested.)
3. **Thumbnail** — shrink to 10%. Is there a focal point, or is it an even field?
4. **Name the substance** — inspect albedo, normal and roughness separately, or move the key light,
   then point at each surface and say what it is made of.
5. **Side by side** — open the named reference next to your frame. State the gap in words, and put
   the **direct link to that exact image** in the PR, not just the game's name.
6. **Three seconds** — shipped game, or tech demo?

Then write the reference and the gap into the PR. **Naming a real remaining gap is the expected
outcome, not a confession** — a PR that claims no gap is usually one that did not run this list.

### Check 1 is measurable on both its axes, and the baseline is recorded

Separation does not have to stay a matter of squinting. A frame can separate its content by **value**
or by **hue**, and both are countable. Measured on the rejected Phase 0 cave frame:

| Metric | Cave frame | Wide-gamut control |
|---|---|---|
| Luminance range (p1→p99) | **12.7%** of 0..1 (p1 0.125 → p99 0.252) | 98.9% |
| Hue span of 90% of coloured pixels (min-90% window) | **6.3°** | 319.4° |

**These are now measurements, not observations.** `client/tools/frame_metrics.gd` computes them and
`client/tests/frame_metrics_test.gd` pins the cave row, so the table above is re-derivable rather
than asserted, and it moves only when the tool does. Every capture prints the same two numbers beside
its frame and writes them into the frame's `.txt` note, so an art PR carries its own reading.

Read each statistic as exactly what it measures, because they cover different populations: **98% of
all pixels** fall between luminance 0.125 and 0.252 (that is what p1→p99 means), while the six-degree
figure covers **90% of the pixels that carry any colour at all** (saturation > 0.05, mid-value).
Neither number licenses the other. The control — a synthetic full hue sweep over a black→hue→white
ramp, built in code by the test — confirms the measurement can tell the difference, so these describe
the frame rather than the method.

**Provenance, so the numbers are checkable rather than asserted.** Source frame is
`docs/phase-0/cave-chamber.png`, in the tree since
[#219](https://github.com/devantler-tech/world-at-ruin/pull/219) merged. Method: point-sample to
320px wide, Rec. 709 luminance for the value figure; for hue, keep only pixels with saturation > 0.05
and luminance in 0.05–0.95, then take the minimum 90% circular window specified below. For a second
reading on the same scale, `cave-walkout.png` measures **15.3%** and **10.3°**.

**What the earlier passes got wrong, recorded because it was nearly repeated.** Two throwaway passes
reported 13.1% and 14.3% of value range, and this page attributed the gap to the resampling filter —
one subsampled, the other downscaled. That explanation did not survive being tested: swapping the
committed tool's point sampling for a bilinear `resize` to the same width reports **12.7% either
way**, identical to three significant figures. The filter was not the cause, and neither throwaway
recorded what else differed. The committed tool point-samples for a different and better reason — a
filtered downscale would make the baseline depend on the engine's interpolation, so a Godot upgrade
could move it with no art having changed.

**What actually differed, found in [#321](https://github.com/devantler-tech/world-at-ruin/issues/321):
the torch flicker.** The question the paragraph above left open — "neither throwaway recorded what
else differed" — has an answer, and it was never the art or the tool. The torches are the cave's only
light, and their energy swings **1.38 → 2.82, slightly over 2×**, on accumulated wall-clock time. A
capture settles a fixed number of *frames* while that phase advances by *delta*, so each run
photographed whatever phase the frame pacing happened to land on. Measured on unchanged `main`, two
consecutive runs:

| Vantage | run 1 | run 2 | drift |
|---|---|---|---|
| cave-chamber | 12.5% / 6.1° | 14.1% / 6.2° | **±1.6pp** value, ±0.1° hue |
| cave-walkout | 16.8% / 10.3° | 20.8% / 10.2° | **±4.0pp** value, ±0.1° hue |
| every outdoor vantage | — | — | reproducible to printed precision |

Only the cave drifted, and only on **value** — dimming a single-hue light changes brightness, not
hue, which is why the hue column held steady while the value column did not. That ±4pp floor was
wider than the effect most cave art passes are asked to demonstrate, so **a cave value delta below
about 4pp was unfalsifiable**, and the 13.1 / 14.3 / 12.7 spread above is that floor rather than a
filter artefact.

`frame_capture` now pins the phase (`CaveSystemGen.freeze_flicker()`) before shooting the cave, so
consecutive runs report identical cave figures; `client/tests/cave_capture_flicker_test.gd` holds it,
including a non-vacuity check so the guard cannot pass against a light that never flickers. In-game
flicker is unchanged — only the evidence path is pinned.

**Cave figures recorded before that fix carry this ±4pp uncertainty and should not be compared
against post-fix ones.** Pinning also re-bases the cave numbers, because they are now read at one
fixed phase instead of an arbitrary one — on the pinned illuminant `cave-chamber` measures **11.0% /
6.0°** and `cave-walkout` **23.2% / 10.2°**. Those are the baseline a later cave pass beats.

The superseded hue pass is kept only so the older figures stay traceable:

- **Original pass (SUPERSEDED — do not implement this):** the 5th-to-95th percentile spread of the
  hues. Wrong on wrapped *and* on asymmetric populations, as measured below.
- **The contract:** the **minimum 90% circular sliding window** specified immediately below.

**🔴 Hue is circular — #230 must not implement the percentile subtraction literally.** Hue wraps at
360°, so a plain p5→p95 subtraction is invalid in general: a nearly monochrome red scene with samples
at 359° and 1° spans 2° of actual colour but reports ~358°, i.e. it would score as almost the whole
gamut precisely when it is at its flattest. The linear form fails *open*, which is the dangerous
direction for a diagnostic.

So the contract #230 implements is the **minimum circular arc containing 90% of the coloured
samples**, computed as a **sliding window**, not as a percentile:

1. Sort the `n` hues ascending.
2. Append a second copy with `+360°` added to each, giving a doubled sequence that can wrap.
3. Let `k = ceil(0.9 * n)`. Take the **smallest** value of `h[i + k - 1] - h[i]` over every start
   index `i` in `0 .. n-1`. That width is the span.

**A percentile spread is not a substitute for this, even after unwrapping at the largest gap** — a
tempting shortcut that is wrong when the outliers are asymmetric. With 90% of samples inside 10° and
the remaining 10% near 100°, unwrapping at the largest gap and taking p5→p95 keeps about half those
outliers and reports ~100°, while the true minimum arc holding 90% is 10°. It fails **open**, which
is the same direction as the original bug and in the same diagnostic this section exists to protect.
Take the sliding-window minimum directly.

**The recorded numbers were re-measured under the new metric — because the obvious argument for
keeping them is wrong.** It is tempting to say the two forms agree whenever the samples do not
straddle 0°. They do not: "no wrap" removes only the *wrap* problem, while the percentile form also
discards 10% from the two tails symmetrically instead of finding the *tightest* 90%. Those diverge on
any asymmetric population, wrap or no wrap — the counter-example above sits entirely inside 0–110°
and still reads **96.0° linear against 9.0° windowed**.

**Both failure modes are now pinned by a test rather than argued about.**
`client/tests/frame_metrics_test.gd` carries each counter-example as a law, and each was RED-proved
by swapping the committed metric for the superseded subtraction and watching that law fail:

| Population | Linear p5→p95 (superseded) | **Min-90% window (the metric)** |
|---|---|---|
| Wrapped — samples at 359°, 359.5°, 0°, 0.5°, 1° | 359.0° | **2.0°** |
| Asymmetric — 90 samples in 0–10°, 10 near 100° | 100.0° | **10.0°** |

Both rows show the superseded form failing **open** — reporting a wide gamut for a population that
has none — which is the dangerous direction for a flatness diagnostic. The earlier throwaway passes
also reported 6.4° linear against 6.3° windowed on the cave frame itself; the two forms happen to
agree there, which is exactly why the synthetic populations above are the ones held under test.

Read them as **diagnostics with a recorded baseline to beat, not a pass/fail gate.** A deliberately
monochrome scene is a legitimate choice — a sandstorm, a night interior — but then *value* has to
carry the separation that hue is not. What condemns this frame is that **neither does**: there is no
axis along which anything separates from anything else, which is why fog, rock, character and
distance all read as one wash.

**Running it.** `client/tools/frame_metrics.gd` is the committed tool, and every `frame_capture` run
already reports through it — the job log prints a `SEPARATION` line per vantage and each frame's
`.txt` note carries the same reading, so an art PR has its numbers without running anything extra.
To measure any other image, call `FrameMetrics.measure(img)` and `FrameMetrics.format(...)`.

## Where the output stands today

Measured against the above, from the Phase 0 frames the maintainer rejected on 2026-07-19
(*"far from futuristic-medieval on all parameters"*) — published by
[#219](https://github.com/devantler-tech/world-at-ruin/pull/219), which lands them in
`docs/phase-0/`:

| Surface | State | Issue |
|---|---|---|
| Texture | Ground and cave rock are arithmetic-only; skins, foliage and debris **do** have textures | #223 |
| World | One biome of smooth Simplex FBM; 90% of coloured cave pixels within 6.3° of hue | #226 |
| Rock and blending | Smooth-min SDF blobs; structures sit on terrain | #225 |
| Character | Mannequin silhouette, shared cloth/skin response | #222 |
| Animation and stance | Static symmetric rig pose | #224 |
| Races | Ethnicity sliders over one body (axes are shipped save data — migrate, never delete) | #228 |
| UI | Debug slider panel | #227 |
| VFX | Torch layers exist but under-read: opaque edges, core and outer at one value | this page |
| Setting | Nothing on screen reads as medieval *or* salvaged tech | this page |

The last row is the one no gap issue covered: the frames miss the setting itself, not merely its
finish. That is the target to move first, because a beautifully textured surface that reads as
neither medieval nor scavenged still fails the gate.
