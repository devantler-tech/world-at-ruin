# ADR 0027: Bind repository protection to a configured verdict publisher

- Status: Accepted; activation is separate
- Date: 2026-10-05
- Updated: 2026-10-09 — reuse the existing organization App
- Decision issue: [#745](https://github.com/devantler-tech/world-at-ruin/issues/745)

## Context

World at Ruin owns its game-specific regression policy. Generic lint, release
and result aggregation remain in the shared catalogue because other products
use the same mechanisms. GitHub required-workflow rules are organization or
enterprise controls. A repository required-status rule identifies a check
context and its publishing App; it does not authenticate an Actions workflow
path. Candidate workflows therefore cannot be the required verdict authority.

## Decision

The default-off `repository-trusted-regressions.yaml` controller is selected
from reviewed World main through `workflow_run`. A completed `CI` run is only
a notification. The controller ignores its conclusion, artifacts and supplied
pull-request list, reads the canonical run and complete current pull-request
census independently, and verifies the integration commit's exact base/head
parents. Queue notifications require a live canonical queue ref and explicitly
reported current-main ancestry.

The evaluation job checks out its own exact workflow source, fetches trusted
base and candidate integration trees anonymously, verifies their identities,
and runs the base-owned suite using the existing non-root, networkless Godot
sandbox. Candidate scenes, skip lists and scripts cannot select the suite or
publish its outcome. The evaluator has read-only credentials and no App key.

A separate job checks out only the exact reviewed workflow source. It reuses
the existing organization App: `APP_CLIENT_ID` and `APP_PRIVATE_KEY` mint the
token, while numeric `APP_ID` binds admission and check readback. The
`world-trusted-gate-publisher` environment must permit deployments from `main`
only; activation requires live branch-policy readback. It requires no separate
App key. The token is requested for World at Ruin only,
with Checks write and Actions, Contents and Pull Requests read. The evaluator
receives no App key. A candidate-authored Actions check has a different App
identity, but another workflow with the shared key and suitable App permissions
can publish the same App/context. App binding authenticates the App, not a
workflow path or the origin of a shared key.

The publisher attaches `World trusted regressions` to the verified pull-request
head, or queue candidate. Before publishing success it re-resolves the entire
identity and refuses changes. It validates the API's create response and fresh
readback, including check name, commit, App, status and conclusion. Missing or
failed observations cannot yield a ready verdict. Loose status policy preserves
the existing merge behavior: a passing head can retain its result after main
advances. Delivery still revalidates the current base immediately before merge.

`WAR_REPOSITORY_TRUSTED_GATE_ENABLED` defaults to unset/off. Enabled execution
requires the existing organization `APP_ID`, `APP_CLIENT_ID` and
`APP_PRIVATE_KEY`. No separate World App, App ID variable or private key is
requested. Source preparation changes no shared permission or credential. The CLI and admission guard test both states; malformed
configuration fails closed. No App token is minted while disabled.

## Activation and recovery

The active organization rule continues to require the catalogue source in ADR
0003. Independent repository enforcement is a separate declarative delivery in
the GitHub configuration owner. Require the exact context and configured App
under an active World/default-branch `RepositoryRuleset` with no bypass actors.
Enable and verify the protected producer first, then require both controls.

Run `go -C tools/trusted-gate run . inspect --app-id <org-app-id>` with an
explicit read token to inspect complete live ruleset inventory and details.
`protection_overlap_verified=true` proves only the declared overlap shape and
is accompanied by `activation_ready=unknown`. It does not prove App permission,
credential confinement, nonzero scene execution or tamper resistance.
Those require separate live positive and negative controls, including a
candidate-created duplicate contexts from Actions and any accessible shared App
key, deleted candidate workflow
and scenes, missing project inputs and changed head/base during evaluation.

A shared key alone cannot establish independent verdict authority. Keep the
established gate until actual credential-boundary and canary evidence supports
the reviewed cutover design; do not infer it from the protected publisher job.

Only after those controls pass may a reviewed configuration release disable
the exact retained organization rule identity. Preserve its managed identity
and Update policy; removing a resource without Delete would orphan an active
rule. Read back independent repository protection afterward. Retire the central
game workflow only when no live rule consumes it. A failed read or canary keeps
the established protection active. Disabling the experimental flag alone is
not recovery once the repository verdict is required: restore established
enforcement and verify it before changing the producer.
