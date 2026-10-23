# Native source-frame evidence

The required `Frame capture (evidence)` check joins three independent native
macOS captures. All native capture and client-export workers use the standard
Apple-silicon `macos-15` image, keeping HEAD, BASE, exported-client and cloth
evidence on the same supported OS and architecture. The `world` group renders the complete default world, all
registered opt-in previews and the selected first-run UI. The `activity` group
renders moving-light response, replicated population, authoritative mob chase,
breathing, walking, running, the gait transition and controller-driven gait.
The BASE worker renders the PR base using its own committed character recipe.

The owning workflow runs the capture commands directly in the HEAD matrix,
with the same warmup, image/caption checks and feature flags. Each worker
uses its own checkout and runner temporary directory. Rendering remains on
macOS; the Linux join only verifies files, imports the comparison classes and
runs the image-change report. It does not replace a native capture.

## Complete collection

`tools/source-evidence` seals each successful group with a closed file inventory:
relative path, byte size and SHA-256. Its context binds the event integration
SHA, PR base, run ID, attempt and exact first-run/GPU decisions. The terminal job
requires every native worker and downloads the three exact current-attempt
artifacts. It rejects missing, extra, changed, linked, stale or mixed evidence
before publishing any joined directory. Every PNG retains its caption and each
activity scenario must be present. Capture logs retain the existing fail-closed
fog, replication and mob-chase verdict checks.

A recorded BASE installation/render failure remains advisory. Its partial
images are not included in the comparison. BASE installation and rendering have
two- and eight-minute step bounds; toolchain setup, sealing and upload also have
their own bounds, leaving time to record an unavailable comparison inside the
15-minute worker budget. Missing or inconsistent transport
evidence is an operational failure, not an advisory result. The final artifact
retains the established `frames-<PR-head-sha>` name and all source-frame paths.
Its receipt identifies the integration source actually rendered. Input hashes
prove intact transport; they are not a signature or proof of visual quality.
The advisory comparison may annotate captions after collection.

## Validation

Run the source-input, capture-contract and source-workflow tests, then
`go test -race tools/source-evidence/main.go tools/source-evidence/main_test.go`.
Input tests verify the exact checkout, closed flag decisions and fresh output
directory. The component test verifies actual workflow selector routing, then
executes the actual capture guard against successful and failed renderer logs.
The Go controls exercise complete collection,
observed BASE failure and refusal of incomplete or mismatched artifacts.
`tools/cloth-capture.test.sh` also exercises the shipping path detector against
real commits changing each source-capture helper.

Runner selection does not guarantee available capacity. Record queue delay
separately from capture execution and compare repeated complete runs before
claiming a feedback-time improvement. The runner image and version are recorded
in GitHub's job setup logs.

Hosted macOS captures, complete artifact inspection and whole-run timings remain
required evidence. Synthetic files and job timeout settings alone establish
neither visual readiness nor a sub-15-minute feedback loop.
