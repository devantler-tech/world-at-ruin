# Capture source evidence

This owner-local composite action renders one complete group of World at Ruin
editor evidence on a native macOS CI worker. It is not a cross-repository API.
The `frame-capture-head` job calls it for both groups and publishes only sealed
evidence for the required collector.

| Input       | Meaning                                                                |
| ----------- | ---------------------------------------------------------------------- |
| `group`     | Required: `world` or `activity`; unknown groups fail before rendering. |
| `visual`    | Exact visual-selector decision; must be `true` to capture.             |
| `first-run` | Exact first-run-selector decision, `true` or `false`.                  |
| `gpu-gated` | Exact GPU-selector decision, `true` or `false`.                        |

The caller checks out the event integration SHA with full history and no
persisted credentials. The action verifies that checkout, compares GitHub's
loaded action metadata with the candidate component, and refuses existing
or linked output state. It installs checksum-verified Godot, imports the actual
project and runs the complete selected capture commands with their original
renderer, flags and guards. Each group needs a separate native runner and
private temporary directory; do not invoke both against the same state.

See [source evidence](../../../docs/ci/source-evidence.md) for collection,
advisory BASE semantics and validation. Run
`bash tools/source-evidence-component.test.sh` after changing this component.
