# Which instrument resolves a shader-relief change (#696)

Evidence for the rule in [`AGENTS.md`](../../../AGENTS.md) that a change to the
plate/crack **relief** term is measured with `client/tools/relief_read.gd` and an
ablation, not with the committed frame-capture vantages.

Separate measurements are recorded here. The first is quoted from
[#696](https://github.com/devantler-tech/world-at-ruin/issues/696) and was taken
on 2026-08-01; the second was taken first-hand on 2026-08-04; the third, the
across-builds floor, was taken for
[#715](https://github.com/devantler-tech/world-at-ruin/issues/715) on 2026-10-24
and repeated on 2026-11-03. They are kept apart because they were run on
different days by different runs, and merging them into one table would
misstate what was observed together.

## 1. The committed vantages do not discriminate (#696, 2026-08-01)

Three builds captured with `WAR_GROUND_PLATES=1` and compared with
`tools/frame_diff`, as changed-pixel fraction:

| Vantage | same code, two runs | a provable NO-OP | seam-slope ceiling `0.4`→`0.30` |
|---|---|---|---|
| shrine | 0.06% | 0.27% | **0.28%** |
| crossfield | 0.04% | 0.14% | **0.13%** |
| cinderreach | 0.03% | 0.12% | **0.13%** |
| sunward | 0.05% | 0.08% | **0.08%** |
| bonepale | 0.03% | 0.08% | **0.12%** |
| cave-chamber | 0.04% | 0.05% | **0.04%** |
| cave-mouth | 0.02% | 0.04% | **0.03%** |
| cave-walkout | 0.02% | 0.02% | **0.01%** |

A 25% tightening of the seam-slope ceiling — which alters how every seam rakes
light — is indistinguishable from a change that provably alters nothing. On four
of the eight vantages the real change moves *less* than the no-op.

## 2. `relief_read` does discriminate it (first-hand, 2026-08-04)

Host: Apple M2 Pro, Metal 4.0 Forward+, Godot 4.7.1, `relief_read` at 1280×720,
shipped world seed. The ceiling is `terrain_surface.gdshaderinc`'s
`grad = grad_len > 0.4 ? grad * (0.4 / grad_len) : grad`.

`RELIEF_STRENGTH` — how much the relief term contributes to the image, by
distance:

| Build | 6 m | 12 m | 24 m | 48 m |
|---|---|---|---|---|
| shipped ceiling `0.4`, run 1 | 0.02416 | 0.02002 | 0.01549 | 0.01678 |
| shipped ceiling `0.4`, run 2 | 0.02416 | 0.02002 | 0.01549 | 0.01678 |
| shipped ceiling `0.4`, run 3 | 0.02416 | 0.02002 | 0.01549 | 0.01678 |
| ceiling `0.30` | 0.02406 | 0.02001 | 0.01549 | 0.01678 |
| ceiling `0.02` — **ablation control** | 0.14249 | 0.01945 | 0.01527 | 0.01669 |

`RELIEF_COVERED` — how much of the crop the seams cover:

| Build | 6 m | 12 m | 24 m | 48 m |
|---|---|---|---|---|
| shipped ceiling `0.4`, runs 1-2 | 0.00471 | 0.01098 | 0.00920 | 0.02781 |
| shipped ceiling `0.4`, run 3 | 0.00471 | 0.01098 | 0.00920 | 0.02782 |
| ceiling `0.30` | 0.00471 | 0.01098 | 0.00920 | 0.02781 |
| ceiling `0.02` — **ablation control** | 0.99780 | 0.01107 | 0.00932 | 0.02788 |

Three things follow, and the third is the reason this file exists.

**The measured quantity repeats — but the tool is not globally bit-stable.**
Across three runs of the shipped build, `RELIEF_STRENGTH` is identical at all
four distances. `RELIEF_COVERED` is identical at 6, 12 and 24 m and moved one
unit in the last printed digit at 48 m on the third run, 0.02781 → 0.02782.

That distinction is the whole reason the comparison below is made on
**strength**: it is the stable quantity, and it is the one the relief term
actually perturbs. It is also worth noting how it was found — two runs looked
like perfect determinism and a third produced the wobble, so "it repeated"
is a statement about the runs taken, not a property proven.

⚠️ These are **runs on one machine**, which is exactly the back-to-back shape
`frame_diff.gd`'s second lesson warns reads too low. This is not an
independent-build floor and must not be quoted as one. It establishes only that
the run-to-run term does not swamp the move measured below; a CI gate on this
tool would need the across-builds figure first, which this section does not
supply. Section 3 measures it.

**It resolves the ceiling change the vantages cannot.** `0.4`→`0.30` moves the
6 m strength by 1e-4 against that zero floor. The signal lives in the near
field: 12 m moves by 1e-5 and 24 m and 48 m not at all, which is consistent with
a ceiling that only binds where seams are wide enough on screen to claim a steep
slope.

**That 1e-4 margin is thin, and on its own it proves nothing.** It is ten units
of the last printed digit. A build whose shader never recompiled would also
report a near-identical number — so "the reading barely moved" and "the edit
never reached the GPU" are the same observation until something separates them.
The `0.02` control is what separates them: it moves the 6 m strength by 0.118
(5.9×) and drives coverage from 0.00471 to 0.99780 (212×). Because that fires,
the pipeline is live, an edit to a `.gdshaderinc` does reach the render without
a re-import, and the `0.30` reading is a measurement rather than a stale frame.

This is why the ablation is mandatory rather than good practice. Without the
control arm, the honest conclusion from the `0.30` run alone is "no information".

## 3. The across-builds floor (#715)

Host for both sittings: Apple M2 Pro, Metal 4.0 Forward+, Godot 4.7.1,
`relief_read` at 1280×720, shipped world seed, all save seams redirected. Not
measured on CI. `terrain_surface.gdshaderinc` and `relief_read` are unchanged
between the two revisions measured.

### 3a. Two independent checkouts (2026-10-24, quoted from #715)

Two fresh checkouts of `main` at `427bd04`, each with its own import cache.

`RELIEF_STRENGTH`:

| Build | 6 m | 12 m | 24 m | 48 m |
|---|---|---|---|---|
| shipped `0.4`, state 1 (10 runs, both checkouts) | 0.02416 | 0.02002 | 0.01549 | 0.01678 |
| shipped `0.4`, state 2 (4 runs, both checkouts) | 0.02417 | 0.02002 | 0.01549 | 0.01677 |
| ceiling `0.30` (6 runs, one checkout) | 0.02406–0.02407 | 0.02000–0.02001 | 0.01548–0.01549 | 0.01677–0.01678 |
| ceiling `0.02` — **ablation control** (2 runs) | 0.02353 | 0.01946 | 0.01527 | 0.01669 |

`RELIEF_COVERED`, which identifies the state of a run:

| Build | 6 m | 12 m | 24 m | 48 m |
|---|---|---|---|---|
| shipped `0.4`, state 1 | 0.00471 | 0.01098 | 0.00920 | 0.02781 |
| shipped `0.4`, state 2 | 0.00470 | 0.01100 | 0.00921 | 0.02774 |

### 3b. A third checkout (first-hand, 2026-11-03)

One fresh checkout of `main` at `7242de6`, with its own import cache. Each line
is one run.

| Build | `RELIEF_STRENGTH` 6 m / 12 m / 24 m / 48 m | `RELIEF_COVERED` 6 m / 12 m / 24 m / 48 m |
|---|---|---|
| shipped `0.4`, run 1 | 0.02416 / 0.02002 / 0.01549 / 0.01678 | 0.00471 / 0.01098 / 0.00920 / 0.02781 |
| shipped `0.4`, run 2 | 0.02416 / 0.02002 / 0.01549 / 0.01678 | 0.00471 / 0.01098 / 0.00920 / 0.02781 |
| shipped `0.4`, run 3 | 0.02417 / 0.02002 / 0.01549 / 0.01677 | 0.00470 / 0.01100 / 0.00921 / 0.02774 |
| ceiling `0.30`, run 1 | 0.02406 / 0.02001 / 0.01549 / 0.01678 | 0.00471 / 0.01098 / 0.00920 / 0.02781 |
| ceiling `0.30`, run 2 | 0.02406 / 0.02001 / 0.01548 / 0.01678 | 0.00471 / 0.01098 / 0.00920 / 0.02781 |
| ceiling `0.02` — **ablation control**, run 1 | 0.02353 / 0.01946 / 0.01527 / 0.01669 | 0.00477 / 0.01106 / 0.00927 / 0.02792 |
| ceiling `0.02` — **ablation control**, run 2 | 0.02353 / 0.01946 / 0.01527 / 0.01669 | 0.00476 / 0.01109 / 0.00927 / 0.02785 |

The third checkout reproduces both states of 3a to every printed digit, and the
`0.30` and control arms to within their 3a ranges.

### What the floor is

**The spread is a two-state flip between runs, not a difference between
builds.** All three checkouts produced both states, so the floor across builds
is the same as within one. For `RELIEF_STRENGTH` it is **one printed unit
(1e-5) at 6 m and 48 m, and zero at 12 m and 24 m**. Section 2's three
identical runs happened to see only one state.

**The `0.4`→`0.30` margin clears it at 6 m, and only at 6 m.** At 6 m the
`0.30` arm sits at least 9 units below the shipped build against a 1-unit
floor, so the reading there is a measurement. At 12 m the gap is 1 to 2 units,
which one run per arm cannot separate. At 24 m and 48 m the arms overlap: no
information.

**Where the instrument stops discriminating.** With one run per arm, a change
must move the 6 m strength by about 3e-5 or more — roughly a third of the
`0.30` move — to be read safely. With three or more runs per arm, comparing
only runs in the same state (`RELIEF_COVERED` tells the states apart), about
2e-5. Below that, use more printed precision or a different crop before
drawing a conclusion. Because the shipped-ceiling margin clears the floor, no
instrument change was needed to close #715.

**The control no longer moves the reading by orders of magnitude.** In August
the `0.02` control moved the 6 m strength to 0.14249 and coverage to 0.99780.
In both sittings here it moves the 6 m strength by about −6.4e-4 (−2.6%) and
the coverage by about +1.3%. That is still about 64 units above the floor, so
the edit does reach the GPU, but the old "orders of magnitude" expectation
would now wrongly read as a dead pipeline. The include holding the ceiling
has not changed since 2026-08-02; the ground shader and the tool have (#866,
#867, #969, #1288). Which change moved the control is not established here.

## Reproducing

The class-name cache must be written first, or the tool refuses with
`no terrain ShaderMaterial under World/Terrain` — a `--import`-only pass does
not write it:

```sh
godot --headless --editor --quit --path client
WAR_SAVE_PATH=/tmp/probe_save.json WAR_VAULT_PATH=/tmp/probe_vault.json \
  WAR_BOOT_RECOVERY_PATH=/tmp/probe_recovery.json \
  godot --path client --resolution 1280x720 res://tools/relief_read.tscn
```

Redirect all three save seams: the tool boots the real launch path. It must run
windowed — a headless run renders nothing, and the tool refuses rather than
report a zero.

Take the control arm by editing the ceiling in
`client/shaders/terrain_surface.gdshaderinc` to `0.02`, re-running, and checking
that the 6 m strength moves far outside the floor in section 3 — about 64 units
(−6.4e-4) at the revisions measured there. Restore the file afterwards. Take at
least two runs per arm, and compare runs in the same `RELIEF_COVERED` state.
