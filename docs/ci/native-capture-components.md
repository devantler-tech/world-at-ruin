# Native capture components

These repository-owned actions expose complete native capture operations. The
owning workflow invokes source HEAD and cloth recipes at an immutable protected
revision. Five native workers execute the complete operations; independent BASE
steps remain inline with their individual deadlines.

| Action                | Required input                                                                      | Complete operation                                                                                                                     |
| --------------------- | ----------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `capture-source-head` | `group`: `world` or `activity`; closed `first-run`, `gpu-gated`, `visual` decisions | Checkout, toolchain, input admission, verified engine installation, import, every selected source capture, sealed inventory and upload |
| `capture-cloth-mode`  | `mode`: `off`, `on`, `drape` or `both`                                              | Checkout, verified installer, import, all four views and ten arms, complete mode artifact                                              |

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

A caller must retain each HEAD or cloth operation's fifteen-minute phase bound.
Source and exported BASE operations remain inline in the owning workflow: composite action
steps do not support their individual `timeout-minutes` fields. Their installation,
render, outcome-record and upload bounds must remain independently enforced.
Installation/render failures retain explicit advisory outcome records; failed
transport or incomplete evidence is never a successful observation.

The separately pinned `capture-exported-head` action and its producer/archive
contract are unchanged. Workflow activation establishes neither trusted-gate
enrollment nor visual-quality approval or a complete-feedback budget pass.
Those outcomes require their separate hosted evidence and acceptance checks.
