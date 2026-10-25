# Quality bar — it has to resemble a AAA game

> Part of the [AGENTS.md](../../AGENTS.md) contract. The section's opening paragraphs, the
> maintainer's direction and the bar itself, stay in AGENTS.md; this guide holds the rest of it.

**Green tests are not the bar.** Machine verification proves a thing is *correct*; it can never
prove it is *good*. So a player-visible change is judged on the **rendered frame and the felt
experience**, not on the suite: look at it, play it, and compare it against a named reference.
**The reference set is [`docs/art-direction/`](../../docs/art-direction/README.md)** — it names the target
per surface, states the fidelity ceiling, and carries the frame-judging checklist. Pick your
reference there before building, and cite that specific one in the PR.

**"AAA" is the bar for OUR OUTPUT — it is not a filter on which references may be cited.** The
distinction is load-bearing, because reading it the other way made the rule impossible to satisfy.
AAA is an informal *budget and publisher-scale* category with no certifying body (2024–25 greenlights
averaged ~$200M) — it describes how a game was funded, not how it looks. **None of the three anchors
the maintainer chose is AAA by that measure**: Numenera is a tabletop RPG, Kingmakers is
indie-published and still unreleased, and Fatekeeper is a **13-person** studio's debut. They were
chosen for **style**, and they are the target regardless of anyone's budget. So a citation is valid
when it is the *right look*, never because of the studio behind it — while our own output must still
look like it belongs in a shipped AAA title. Resolved on
[#234](https://github.com/devantler-tech/world-at-ruin/issues/234).
**Attach the frame.** A PR carries an inspectable screenshot, captured frame or short clip of the
actual change, the reference it is judged against, and the remaining gap — because a written claim
that "I looked at it and it's fine" is self-attestation, and self-attestation is exactly what let a
field of grey primitives ship. A green suite plus a frame that reads as placeholder is a PR that is
**not ready**.

When the result being judged is movement, the actual-change evidence must be a short clip or captured
frame sequence rather than a single still. The named reference must likewise be a moving artifact
with an exact time range, following the citation contract in
[`docs/art-direction/`](../../docs/art-direction/README.md).

**For locomotion, pick the instrument by what changed.** The `walk`, `run` and `gait_transition`
capture scenarios pose `WalkLocomotion` with the body pinned, so they evidence the pose and nothing
downstream of it. `WAR_SCENARIO=gait_drive` drives the shipped controller with real input at the
fixed physics step and reports the cadence, foot slide and foot lift measured over every controller
step in `gait_drive_summary.txt`, plus how much of the stretch a foot is down and how far a down foot
moves over the ground (its contact line — the one to judge a planted foot by, because the nearest-foot
slide also charges a gait's airtime) — so a change to stride constants, controller wiring, sprint speed
or the follow camera is judged there, not on the fixed-phase frames, which read a stride regression
the same as a correct build. It fails itself if its photographed drive does not reproduce its
rehearsal exactly. The measurements and ablations behind it are in
[`docs/evidence/issue-516-gait-drive/`](../../docs/evidence/issue-516-gait-drive/README.md).

**How to produce that frame.** CI runs `client/tools/frame_capture.tscn` on player-visible PRs and
publishes the rendered vantages as a **build artifact** — so the evidence is reproducible on a known
machine rather than dependent on whoever happened to run the game. Point a reviewer at that artifact.
Locally the same tool works windowed (`WAR_SHOT_DIR=… WAR_SAVE_PATH=… WAR_VAULT_PATH=…
WAR_BOOT_RECOVERY_PATH=… godot --path
client res://tools/frame_capture.tscn` — redirect every save seam, since the capture boots the real
launch path); a **headless run renders nothing**, and the tool refuses to run
headless rather than emit a blank frame. It also proves the terrain actually landed pixels: at one
designated vantage it hides the terrain mesh and fails unless the frame changes where bare ground
was, so a fully transparent or discard-everything material cannot pass off a sky photograph as
evidence. Its vantages are fixed on purpose: evidence is only
comparable across commits if the camera does not move, and one flattering angle hides a regression
that another exposes. The outdoor vantages are fixed as committed constants; the cave vantages are
fixed **per committed seed** — derived deterministically from the cave layout, bit-identical run
over run, moving only when the world itself moves (which `cave_capture_vantage_test` turns into a
named failure and the capture log declares as a `CAVE VANTAGE` coordinate delta, never a quietly
different frame).

**What the vantages cannot resolve: shader RELIEF (#696).** None of the eight committed vantages
discriminates a change to the plate/crack relief term, so "captured before and after, no change" is a
**vacuous** claim for that class — the frames would have matched had the change been wrong. Measured
on the seam-slope ceiling `0.4`→`0.30`, which alters how every seam rakes light: the committed frames
move 0.28% at shrine and 0.13% at crossfield against a **provable no-op's** 0.27% and 0.14%, and on
four of the eight the real change moves *less* than the no-op. Frames are not bit-reproducible either
— `frame_diff.gd`'s own back-to-back table runs from 0.02% to 35.66% on unchanged code — so a
checksum or byte comparison of captures is invalid as well, however reasonable it looks.
For this class the instrument is [`client/tools/relief_read.gd`](../../client/tools/relief_read.gd), which
differences the build against `crack_relief = 0` rather than against another render, and whose
`RELIEF_STRENGTH` repeats to every printed digit across three runs on one machine. Compare on
strength, not coverage: coverage moved a unit in its last digit at 48 m on the third of those runs,
and that figure is runs-on-one-machine anyway — the shape `frame_diff.gd`'s second lesson warns reads
too low — so it is not an independent-build floor and nothing here may gate on it (#715).
**Any "capture before and after" criterion must name an ABLATION alongside the instrument** — a
deliberate wrong build the instrument has to distinguish — because a blind instrument and a correct
change read the same, and only the ablation tells them apart. Both measurements, including the
control that makes the relief reading mean anything, are in
[`docs/evidence/issue-696-relief-instrument/`](../../docs/evidence/issue-696-relief-instrument/README.md).

**What that artifact cannot show you (#232).** Volumetric fog is gated on an R32_Uint atomic storage
image, and the hosted macOS capture runner's GPU does not support it — so **every frame CI publishes
shows the height-fog fallback**, never the volumetric path or the hollow ash pools built on it. The
capture job now states which path it captured: read `capture-conditions.txt` in the artifact, or the
job summary. If you changed probe-gated rendering, CI says so and the frames are not your evidence —
**render the enabled path locally and attach that**. The reasoning, the rejected self-hosted-runner
option and the measured software-rasteriser direction are in
[`docs/design/gpu-gated-frame-evidence.md`](../../docs/design/gpu-gated-frame-evidence.md).

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
and it stays correct. The gate distinguishes the player-visible outcome being changed:

- A **new incomplete player-visible element** — something the default experience did not contain
  before — stays behind a default-off opt-in flag (product law 2) or out of the world until it clears
  the bar. Apply this rule to each introduced element independently: a mixed change cannot classify a
  new element as part of an in-place improvement.
- A **settled in-place improvement to an existing below-bar surface** may remain default-on when it
  makes that already-shipped surface better without presenting it as finished. This exception never
  overrides product law 2: an unsettled or experimental improvement stays default-off. Shipping a
  settled improvement on **requires both the PR and the dev log to state the remaining gap
  explicitly**; the normal inspectable-frame and named-reference requirements still apply.

This distinction does not lower the bar. A new unfinished element must not expand the default
experience, while an in-place improvement should not leave an already-shipped surface in its worse
state. In both cases, unfinished work cannot quietly pose as complete.

**Taste is the maintainer's call — and that is not licence to aim low.** Phase 0 is his taste gate
and agents do not self-certify taste. Agents are nonetheless expected to *aim at* the AAA bar, to
judge their own output honestly against it, and to say when they know it falls short — rather than
shipping the first thing that renders and leaving the judgement entirely to him.

