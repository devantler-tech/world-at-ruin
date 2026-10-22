# Cloth capture evidence

The required **Frame capture (cloth evidence)** job runs on a native macOS
runner, alongside **Frame capture (player-visible evidence)** rather than after
its other scenarios. Both use the same visual-change decision. A change to the
capture script or macOS installer triggers capture even without a client edit.
The stable **CI - Required Checks** aggregate requires the new job's result as
well as the remaining source and exported capture results.

## What must stay complete

`tools/capture-cloth-evidence.sh` runs the existing windowed Metal scene with
detail and drape off, detail only, drape only, and both enabled. Every mode has
front, rear, profile and gameplay views, each with ten comparison arms. The
result is **160 PNG images and 160 caption files**. All must be nonempty.

Every mode must also emit its exact capture, refinement and boot verdicts.
Engine failures and script, shader or rendering errors fail the job even if a
pass marker appeared earlier. The existing recovered Metal fence-message filter
is unchanged. Each mode keeps separate temporary save, vault and recovery paths.
The job does not use a headless renderer as a substitute for rendered evidence.

The checkout uses the tested integration revision, full history and no persisted
credentials. `tools/install-ci-macos-godot.sh` downloads the workflow-pinned
engine, verifies its pinned SHA-512 before extraction, then installs its wrapper.
A headless editor import prepares the class-name cache before windowed capture.

The artifact is `cloth-frames-<tested integration SHA>`, containing every image,
caption and the four mode logs. Other source-frame artifacts retain their
non-cloth scenarios; exported-frame evidence is unchanged. The two capture
artifacts must be read together when reviewing a visual change.

## Validate a change

Run `bash tools/cloth-capture.test.sh` for the actual capture script's synthetic
complete-set and refusal controls, the installer's checksum-before-install
controls, real Git change-routing fixtures and parsed required-job wiring.
Run `bash tools/client-proof-workflow-guard.test.sh` for the complete aggregate's
omission, skip and error-masking controls. These local tests validate enforcement;
they are not proof that real Metal rendered correctly.

Before promotion, inspect the complete hosted run at the proposed head: all
cloth modes must succeed, its artifact must contain all 320 evidence files, and
all other required jobs must remain green. Record source-frame, cloth and overall
feedback times, including setup and runner waits. The cloth job has a 15-minute
bound. Splitting it is not proof that the entire workflow meets the portfolio's
15-minute feedback objective; remaining critical paths stay tracked separately.
