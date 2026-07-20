# Frame evidence for GPU-gated rendering

> Status: **accepted** · 2026-07-20 · delivers #232 (Part of the quality-bar epic #123). The draft
> PR is the steering surface — the maintainer redirects there.
>
> This is an architecture decision record. It settles *how a change to GPU-probe-gated rendering
> gets inspectable frame evidence* when the required capture runner cannot render the gated path.
> It does not build the software-rasteriser lane: the child that follows cites this document and
> implements it.

## The problem, stated precisely

`Frame capture (evidence)` is a required check. It renders the game on a hosted `macos-latest`
runner and publishes the frames, so a reviewer judges player-visible work on a picture instead of a
written claim.

Godot's froxel volumetric fog allocates an **R32_Uint atomic storage image**. That runner's
virtualised Apple adapter does not support that format for that usage, so `Volumetrics.probe()`
returns false and the fog never initialises. Every frame in every artifact therefore shows the
**height-fog fallback**.

Two merged changes already sit in that position: volumetric fog (#158/#209) and the hollow ash
pools built on it (#211/#218 — where the capture photographs a world containing zero `FogVolume`
nodes). The Codex reviewer raised it as a P1 on #218.

The consequence is not "weaker evidence". It is that a **green required check certifies frames
that cannot contain the change under review** — a regression in the enabled path merges unseen, and
the evidence rule quietly degrades back to prose, which is the self-attestation the quality bar
exists to stop.

## Options

### 1. A self-hosted runner with a real GPU — **rejected**

This repository is **public**. GitHub's own guidance is that self-hosted runners should almost
never be used with public repositories: anyone can open a pull request, a workflow in that pull
request can target the runner, and a self-hosted runner carries no guarantee of running in an
ephemeral clean machine — so it can be **persistently compromised** by untrusted code.

The rejection is sharper than the general guidance, because of *which* machine would serve. The
only machine on hand that passes the probe is the **agent host** — the same machine that runs the
autonomous engineers and holds the portfolio's credentials. Attaching a public repository's runner
to it would place arbitrary pull-request code next to every credential the suite has, inverting the
host's least-privilege posture for a picture of some fog.

The standard mitigations (require approval for outside collaborators, ephemeral runners, runner
groups) reduce the risk but do not restore the property, and each one is a standing obligation that
rots quietly. This option is declined on security grounds, not on cost — so no runner is added and
the ownership question it would raise does not arise.

### 2. A software-rasteriser lane — **viable, and now measured**

Mesa's **lavapipe** is a CPU Vulkan implementation. Whether it advertises R32_Uint as an atomic
storage image is not stated in Mesa's llvmpipe documentation, the lavapipe extension changelogs, or
`vulkan.gpuinfo.org` — so this could not be decided from prose. It was **measured** instead, by a
throwaway CI job that ran this repository's own `Volumetrics.supported()` against lavapipe and was
deleted once it had answered:

```
Vulkan 1.4.318 - Forward+ - Using Device #0: llvmpipe (LLVM 20.1.2, 256 bits)
PROBE_ADAPTER          llvmpipe (LLVM 20.1.2, 256 bits)
PROBE_RD_PRESENT       true
PROBE_R32UINT_ATOMIC   true
```

`ubuntu-24.04`, `mesa-vulkan-drivers`, ICD `/usr/share/vulkan/icd.d/lvp_icd.json`, under `xvfb`.
**Lavapipe supports the format.** A Linux lane can therefore run the *enabled* volumetric path that
the macOS runner structurally cannot.

Two findings from the measurement itself are worth carrying forward, because both produce a
confident wrong answer rather than a failure:

- The ICD filename must be resolved by glob. Guessing `lvp_icd.x86_64.json` (the package ships
  `lvp_icd.json`) makes the Vulkan loader error, Godot fall back to OpenGL, and the probe return
  false for a reason that has nothing to do with lavapipe.
- `--rendering-driver vulkan` is required. Without it Godot selects the GL Compatibility renderer,
  which has **no `RenderingDevice` at all**, so the probe returns false trivially.

What is **not** yet known, and is the child's job: whether a full capture (150 warm-up + 120 settle
frames across four vantages, plus volumetrics) completes on a CPU rasteriser inside a sane timeout,
and whether the frames are useful to a reviewer. A different rasteriser produces different pixels,
so such a lane is **additive** — its frames are comparable to each other across commits, never to
the macOS runner's. It does not replace the required job.

### 3. State the degradation and enforce that it stays known — **adopted now**

Needed regardless of option 2, and independently of when that lands.

## Decision

1. **No self-hosted runner.** Declined on security grounds; revisit only if the repository stops
   being public *and* the runner is not the agent host.
2. **Pursue the lavapipe lane** as an additive, probe-gated-only capture, in its own child issue,
   on the measurement above.
3. **Until then, the degradation is stated rather than assumed.** **Both** capture jobs — the
   editor-project `Frame capture (evidence)` and `Frame capture (exported client)` — now:
   - parses the probe verdict from the capture log and **fails closed when it is absent** — an
     unknown verdict is a failure, not a default. Before this the verdict lived only in a CI log
     nobody downloads, and removing the print would have made the degradation *unknowable* rather
     than merely invisible;
   - writes `capture-conditions.txt` **into the artifact**, beside the frames, so a reviewer
     opening them next week knows which path they show;
   - repeats the verdict in the job summary; and
   - and, **once per run** rather than per job, when a pull request touches probe-gated code **and**
     the capture ran with the probe off, say plainly — in the log and the summary — that these frames
     cannot evidence that change. The warning is emitted by `Frame capture (evidence)` only: the flag
     is a property of the pull request, not of a job, so repeating it in the exported job would add
     noise without adding information. Both artifacts still carry their own conditions file, because
     that one *is* per-job — the two jobs could in principle probe differently.

The marker is a contract, not a log pleasantry: `Volumetrics.marker()` owns the string, `main.gd`
prints it, and `volumetrics_test` pins its shape, so the workflow's parse cannot silently drift.

### What this deliberately does not do

The gated notice **warns, it does not fail**. Blocking would stop the entire volumetric lane on a
runner limitation while adding no evidence, and the frames remain valid evidence for everything
else in the diff. The obligation it raises — attach a locally-rendered frame of the enabled path —
is already a **P1 review blocker** in `AGENTS.md`, and #139 established that CI cannot verify an
attached image because GitHub exposes no API for one. So the honest split is: CI enforces what CI
can *know* (the verdict is always recorded), and review enforces what only a human can *see*.

Calling that "enforced by CI" would be the same self-attestation one layer up.
