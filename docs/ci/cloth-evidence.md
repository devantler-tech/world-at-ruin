# Cloth capture evidence

The required **Frame capture (cloth evidence, mode)** matrix runs each of its
four fixed modes on a separate native macOS runner, alongside
**Frame capture (evidence)** rather than after
its other scenarios. Both use the same visual-change decision. A change to the
capture script or macOS installer triggers capture even without a client edit.
The stable **CI - Required Checks** aggregate requires the new job's result as
well as the remaining source and exported capture results. Every matrix worker
must succeed; fail-fast is disabled so one failed mode does not cancel the
other modes' evidence. Missing, duplicated or excluded modes fail the workflow
contract tests. Each worker retains the 15-minute bound.

## What must stay complete

`tools/capture-cloth-evidence.sh` runs the existing windowed Metal scene with
detail and drape off, detail only, drape only, and both enabled. Every mode has
front, rear, profile and gameplay views, each with ten comparison arms. The
result is **160 PNGs and 160 caption files**. All must be nonempty.
With no argument the helper captures all four modes for local use; CI passes
exactly one of `off`, `on`, `drape` or `both` to each worker. Unknown, empty or
extra arguments fail before starting the engine. Each worker verifies all
40 images and 40 captions belonging to its mode.

Each mode directory must be absent before capture. Atomic creation refuses reused
directories, files and symlinks before starting the engine, preserving the previous
capture instead of deleting it. Choose a fresh `RUNNER_TEMP` for another local run.
The stable client proof gate requires a successful matrix result when visual
capture is selected; it accepts a skipped result only when capture was explicitly
not selected. This check is independent of the shared aggregate's skip policy.

Every mode must also emit its exact capture, refinement and boot verdicts.
Engine failures and script, shader or rendering errors fail the job even if a
pass marker appeared earlier. The existing recovered Metal fence-message filter
is unchanged. Each mode keeps separate temporary save, vault and recovery paths.
The job does not use a headless renderer as a substitute for rendered evidence.

The checkout uses the tested integration revision, full history and no persisted
credentials. `tools/install-ci-macos-godot.sh` downloads the workflow-pinned
engine, verifies its pinned SHA-512 before extraction, then installs its wrapper.
A headless editor import prepares the class-name cache before windowed capture.

Each artifact is `cloth-frames-<mode>-<tested integration SHA>`, containing its
40 images, 40 captions and mode log. All four mode artifacts and the remaining
source-frame artifact must be read together when reviewing a visual change.
Other source-frame artifacts retain their non-cloth scenarios; exported-frame
evidence is unchanged.

## Validate a change

Run `bash tools/cloth-capture.test.sh` for the actual capture script's synthetic
complete-set and refusal controls, the installer's checksum-before-install
controls, real Git change-routing fixtures and parsed required-job wiring.
Run `bash tools/client-proof-workflow-guard.test.sh` for the complete aggregate's
omission, skip and error-masking controls. These local tests validate enforcement;
they are not proof that real Metal rendered correctly.

Before promotion, inspect the complete hosted run at the proposed head: all
cloth modes must succeed, their four artifacts must contain all 320 evidence files, and
all other required jobs must remain green. Record source-frame, cloth and overall
feedback times, including setup and runner waits. The cloth job has a 15-minute
bound. Splitting it is not proof that the entire workflow meets the portfolio's
15-minute feedback objective; remaining critical paths stay tracked separately.
