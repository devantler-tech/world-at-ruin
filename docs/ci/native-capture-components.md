# Native capture components

These repository-owned actions expose complete native capture operations. They
are prepared for a separately reviewed caller activation; the current workflow
still executes its existing inline recipes.

| Action                  | Required input                                                                      | Complete operation                                                                                                                     |
| ----------------------- | ----------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `capture-source-head`   | `group`: `world` or `activity`; closed `first-run`, `gpu-gated`, `visual` decisions | Checkout, toolchain, input admission, verified engine installation, import, every selected source capture, sealed inventory and upload |
| `capture-source-base`   | Caller environment described below                                                  | Independent checkout, toolchain, verified installer, base render, explicit success/failure inventory and upload                        |
| `capture-cloth-mode`    | `mode`: `off`, `on`, `drape` or `both`                                              | Checkout, verified installer, import, all four views and ten arms, complete mode artifact                                              |
| `capture-exported-base` | Caller environment described below                                                  | Independent checkout, verified engine/templates, base export/render, source/run/attempt outcome record and upload                      |

Callers provide the workflow's pinned Godot version and checksums, `BASE_SHA`,
`FIRST_RUN`, `GPU_GATED` and, for exported evidence,
`EXPORTED_CAPTURE_RESOLUTION`. Use the standard `macos-15` native runner. Source
HEAD input decisions and inherited environment must describe the same selection.
The source validator refuses an unknown decision, a checkout differing from
`GITHUB_SHA`, or an existing evidence directory before rendering.

Every invocation keeps its complete recipe, including checkout and installation;
co-location is not permission to reuse a prior result. Native source HEAD,
source BASE and exported BASE use separate runner-temporary output paths. Cloth
modes use distinct save and image paths, and a reused mode directory is refused.
Completed evidence must upload before a subsequent checkout cleans the workspace.

A caller must retain each operation's fifteen-minute phase bound. Source BASE
installation/render failures and exported BASE installation/render failures retain
their explicit advisory outcome records; failed transport or incomplete evidence
is never a successful observation. `capture-exported-base` emits `recorded=true`
only after that complete outcome artifact uploads, not as a claim that BASE
rendering succeeded.

The separately pinned `capture-exported-head` action and its producer/archive
contract are unchanged. Source preparation grants no activation, trusted-gate
enrollment, visual-quality approval or complete-feedback budget pass.
