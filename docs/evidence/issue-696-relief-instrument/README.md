# Which instrument resolves a shader-relief change (#696)

Evidence for the rule in [`AGENTS.md`](../../../AGENTS.md) that a change to the
plate/crack **relief** term is measured with `client/tools/relief_read.gd` and an
ablation, not with the committed frame-capture vantages.

Two separate measurements are recorded here. The first is quoted from
[#696](https://github.com/devantler-tech/world-at-ruin/issues/696) and was taken
on 2026-08-01; the second was taken first-hand on 2026-08-04. They are kept
apart because they were run on different days by different runs, and merging
them into one table would misstate what was observed together.

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
tool would need the across-builds figure first, which nothing here supplies
(tracked in #715).

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
`client/shaders/terrain_surface.gdshaderinc` to a value whose effect cannot be
subtle, re-running, and checking that the reading moves by orders of magnitude.
Restore the file afterwards.
