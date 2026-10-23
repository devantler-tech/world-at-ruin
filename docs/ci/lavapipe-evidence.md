# Advisory volumetric evidence

`.github/workflows/lavapipe-capture.yaml` owns the Linux/llvmpipe volumetric
capture. It runs independently of `CI`, with eight isolated view jobs and a
complete-union collector. Each view has a 15-minute job budget. Its failures remain visible on the pull request;
it is absent from `CI - Required Checks`. The required macOS frame captures,
their selection job and the independent trusted regressions retain their gates.

The selector runs on pull requests. Merge-group events produce no capture,
matching the visual-selection policy in CI. It verifies that the checkout is
the exact `GITHUB_SHA` integration commit and that its second parent is the
event's PR head. Missing or conflicting source identity fails the selection.
Every worker checks out GitHub's immutable event SHA directly, never a candidate
job output. The render and collection jobs repeat identity verification against
the selector's recorded SHA before accepting results or installing the runtime.

The source paths are `client/scripts/{volumetrics,hollow_fog,main}.gd` and
`.github/workflows/ci.yaml`. Changes to the independent workflow, its selector,
base resolver, engine installer, frame-capture implementation, capture guard or
union collector also select a capture. The
base resolver uses the integration's current main parent, avoiding unrelated
main changes in a PR's visual diff. Changes to selection machinery are checked
against the frozen event base before executing the resolver. An unavailable or
failed path observation conservatively selects capture, including a command
that prints plausible partial paths before failing.

The capture retains the pinned Godot version/checksum, read-only repository
permissions and credential-free checkout,
explicit Vulkan/llvmpipe checks, isolated save paths, fog/pool/verdict checks and
PNG/conditions artifact. The artifact name is
`lavapipe-volumetric-frames-<integration-sha>`: it identifies the checked-out
integration, rather than only the PR branch tip. Its pixels are an independent
Linux baseline and do not establish a macOS pixel comparison.

## Runtime preparation

`tools/install-ci-lavapipe.sh` refreshes authenticated APT metadata and resolves
one exact `mesa-vulkan-drivers` amd64 archive with SHA-256. The recognized Ubuntu
source and bounded package filename determine the canonical Ubuntu HTTPS-origin
download; metadata cannot supply an arbitrary download destination. The complete
byte size and digest must match before APT can execute the archive. A private APT
archive cache retains that exact package under its canonical filename. Normal APT
resolution downloads Vulkan tools, X authentication and virtual-display dependencies;
the Mesa bytes are rechecked before a download-disabled installation phase.
No installed-package state, test verdict or rendered image is cached.

Failed or ambiguous planning, partial downloads, unsupported origins/architecture,
weak hashes and wrong bytes refuse before package execution. Logs record archive
identity, download time and total preparation time. The workflow then retains its
independent ICD selection and real llvmpipe-device proof.

## Complete rendered evidence

The five fixed outdoor views and three derived cave views run on independent
standard hosted runners. `WAR_WORLD_VANTAGE` selects one exact view; an unknown
or ambiguous value refuses to capture. An unset value retains the complete
ordinary capture used by the macOS jobs. Every cell keeps the 150-frame warmup,
120-frame camera settling, image/luminance checks and applicable contribution
controls. Even the mouth-only cell validates both interior ray/cull directions
before accepting the inverse exterior check; it does not silently assume them.

Per-view artifacts bind the integration SHA, exact view and measured capture
duration, preserving separate PNG, note, conditions and log files. The collector
requires every successful matrix result and exactly the eight source-bound
artifacts. Missing, duplicated, mixed-source, symlinked, empty or failed evidence
cannot produce the final artifact. The established complete-artifact name remains
unchanged; each per-view log and conditions file keeps its own name.

A 15-minute timeout is a refusal bound, not performance proof. Record full native
run/queue timings and representative repeats before declaring the whole-feedback
target in #1495 met.

Use `bash tools/select-lavapipe-capture.test.sh` for real-history and failed-read
controls, `bash tools/lavapipe-workflow.test.sh` for parsed routing/permission
mutations, `bash tools/lavapipe-capture-guard.test.sh` for render refusals, and
`bash tools/lavapipe-partitions.test.sh` for complete-union refusal controls.
`bash tools/install-ci-lavapipe.test.sh` exercises real-byte archive refusal and
failed-producer controls without installing host packages; the workflow test
also runs it and rejects a missing installer callsite.
The real Godot scene `tests/world_capture_plan_test.tscn` checks the complete
plan, every disjoint partition and invalid selections.
Run ShellCheck and actionlint for the affected shell and workflow files.

To verify independent retry admission, retain both runs' IDs, workflow paths,
integration/source SHAs and attempts. After CI finishes, rerun the actual
required job while this workflow is still active, then read the rerun source
and result back. A successful-job rerun proves rerun admission only. Mark
failed-required-job recovery complete only after observing an actual failed
job's retry and result. GitHub documents that reruns retain the original
[`GITHUB_SHA` and `GITHUB_REF`](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs);
the runtime readbacks remain necessary to bind a particular observation.
