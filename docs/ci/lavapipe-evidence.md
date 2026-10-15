# Advisory volumetric evidence

`.github/workflows/lavapipe-capture.yaml` owns the Linux/llvmpipe volumetric
capture. It runs independently of `CI`, so its 45-minute render budget does not
keep a required CI run open. Its failures remain visible on the pull request;
it is absent from `CI - Required Checks`. The required macOS frame captures,
their selection job and the independent trusted regressions retain their gates.

The selector runs on pull requests. Merge-group events produce no capture,
matching the visual-selection policy in CI. It verifies that the checkout is
the exact `GITHUB_SHA` integration commit and that its second parent is the
event's PR head. Missing or conflicting source identity fails the selection.
The render job checks out that same immutable integration SHA and repeats the
identity verification before installing its runtime.

The source paths are `client/scripts/{volumetrics,hollow_fog,main}.gd` and
`.github/workflows/ci.yaml`. Changes to the independent workflow, its selector,
base resolver, engine installer or capture guard also select a capture. The
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

Use `bash tools/select-lavapipe-capture.test.sh` for real-history and failed-read
controls, `bash tools/lavapipe-workflow.test.sh` for parsed routing/permission
mutations, and `bash tools/lavapipe-capture-guard.test.sh` for render refusals.
Run ShellCheck and actionlint for the affected shell and workflow files.

To verify independent retry admission, retain both runs' IDs, workflow paths,
integration/source SHAs and attempts. After CI finishes, rerun the actual
required job while this workflow is still active, then read the rerun source
and result back. A successful-job rerun proves rerun admission only. Mark
failed-required-job recovery complete only after observing an actual failed
job's retry and result. GitHub documents that reruns retain the original
[`GITHUB_SHA` and `GITHUB_REF`](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs);
the runtime readbacks remain necessary to bind a particular observation.
