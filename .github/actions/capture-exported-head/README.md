# Capture exported HEAD

World at Ruin's selected native CI worker uses this internal component to
photograph the exact macOS archive produced by the same run. It is not a
general-purpose publisher or an install source.

The caller supplies an immutable integration checkout, the built archive at
`build/WorldAtRuin.zip`, and the existing `1024x576` capture resolution. The action
refuses a wrong archive digest, dirty or mismatched source, and stale capture
state. Its control code is pinned independently of the workspace and must match
the local tested implementation. Completion is acknowledged only after all
evidence uploads successfully.

| Interface              | Meaning                                                   |
| ---------------------- | --------------------------------------------------------- |
| `archive-sha256` input | Required SHA-256 emitted by the native export producer    |
| `captured` output      | `true` only after the complete capture and upload succeed |

Start with the [owning CI workflow](../../workflows/ci.yaml) and
[capture contract](../../../docs/ci/exported-head-evidence.md). Fast fixture tests
cover admission and failure propagation; hosted macOS capture and image review
establish native behavior.
