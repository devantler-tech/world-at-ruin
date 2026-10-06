# ADR 0027: Bind repository protection to independent verdicts

- Status: Accepted; activation is separate
- Date: 2026-10-05
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

A separate job checks out only the exact reviewed workflow source. It uses a
dedicated World-only publishing App and the `world-trusted-gate-publisher`
environment. That environment permits deployments from `main` only; the App
key exists only as its environment secret, never as a repository or organization
secret. Its token requests Checks write and Actions, Contents and Pull Requests
read. A candidate-authored Actions check has a different App identity and
cannot satisfy the repository rule's source binding.

The publisher attaches `World trusted regressions` to the verified pull-request
head, or queue candidate. Before publishing success it re-resolves the entire
identity and refuses changes. It validates the API's create response and fresh
readback, including check name, commit, App, status and conclusion. Missing or
failed observations cannot yield a ready verdict. Loose status policy preserves
the existing merge behavior: a passing head can retain its result after main
advances. Delivery still revalidates the current base immediately before merge.

`WAR_REPOSITORY_TRUSTED_GATE_ENABLED` defaults to unset/off. Enabled execution
requires `WAR_TRUSTED_GATE_APP_ID` and the protected environment's
`WAR_TRUSTED_GATE_PRIVATE_KEY`. It must not reuse a general automation App or
an inherited key. The CLI and admission guard test both states; malformed
configuration fails closed. No App token is minted while disabled.

## Activation and recovery

The active organization rule continues to require the catalogue source in ADR
0003. Independent repository enforcement is a separate declarative delivery in
the GitHub configuration owner. Require the exact context and dedicated App
under an active World/default-branch `RepositoryRuleset` with no bypass actors.
Enable and verify the protected producer first, then require both controls.

Run `go -C tools/trusted-gate run . inspect --app-id <dedicated-app-id>` with an
explicit read token to inspect complete live ruleset inventory and details.
`replacement_ready=true` proves only the declared overlap shape; it does not
prove credential confinement, nonzero scene execution or tamper resistance.
Those require separate live positive and negative controls, including a
candidate-created duplicate context from Actions, deleted candidate workflow
and scenes, missing project inputs and changed head/base during evaluation.

Only after those controls pass may a reviewed configuration release disable
the exact retained organization rule identity. Preserve its managed identity
and Update policy; removing a resource without Delete would orphan an active
rule. Read back independent repository protection afterward. Retire the central
game workflow only when no live rule consumes it. A failed read or canary keeps
the established protection active. Disabling the experimental flag alone is
not recovery once the repository verdict is required: restore established
enforcement and verify it before changing the producer.
