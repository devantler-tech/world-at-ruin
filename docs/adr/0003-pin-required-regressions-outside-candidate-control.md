# ADR 0003: Host required regressions outside candidate control

- Status: Accepted
- Date: 2026-08-20
- Decision issue: [#733](https://github.com/devantler-tech/world-at-ruin/issues/733)

## Context

Pull-request and merge-group checkouts contain the workflow, selector, test
scenes, fixtures and runner that ordinary CI executes. A required status name
does not make those bytes independent: a proposed change can edit the job that
produces the status and the harness that the job invokes.

The product-law regressions protect forward-only player state, recovery and
combat economy. Their selection and aggregate verdict therefore need an
authority outside the candidate checkout while still exercising the candidate
product tree. GitHub ruleset workflows provide that authority: a ruleset names
a source repository, workflow path and source ref, and runs that workflow for
pull-request and merge-group events.

## Decision

The organization ruleset `Require workflow - World at Ruin trusted regressions`
is managed declaratively in `devantler-tech/.github`. It targets only World at
Ruin's default branch, declares no bypass actors, and requires
`devantler-tech/actions/.github/workflows/world-at-ruin-required-regressions.yaml`
at `refs/heads/main`. The World repository does not carry a second copy of that
workflow.

The workflow checks out two trees:

1. the candidate merge or merge-group commit, which supplies product code;
2. the GitHub-supplied pull-request or merge-group base SHA, which supplies
   every trusted `client/tests/*_test.tscn` scene and fixture,
   `tools/required-regression-control.sh`, and `tools/run-client-test.sh`.

The ruleset workflow and its trusted-base resolver come from the reviewed
Actions source. `github.workflow_sha` identifies the exact Actions revision
executing one run; it is not candidate-controlled.

`tools/required-regression-control.sh` copies the candidate into a throwaway
evaluation root, excludes repository metadata, replaces the candidate's
`client/tests/` directory with the trusted snapshot, imports the resulting
Godot project, and runs every trusted scene through the trusted runner. The
workflow job is the aggregate verdict. It has read-only repository permission,
uses a checksum-verified Godot binary, persists no checkout credentials, and
runs under the hardened runner's egress audit.

`tools/required-regression-control.test.sh` is the local contract proof. Its
candidate deletes one trusted scene, weakens another and lists the deleted
scene in `ci-skip.txt`; both trusted scenes must still execute with trusted
harness bytes against candidate product bytes. Separate arms require a runner
failure to fail the aggregate and an empty trusted suite to fail closed.

provider-upjet-github v0.19.1 exposes the required workflow's repository, path
and branch/tag `ref`, but not GitHub's immutable workflow SHA selector. The
strongest declarative binding available to this deployment is therefore the
reviewed Actions `main` branch. Changes to the external workflow require an
exact-head-reviewed Actions PR, compatibility with the World base controller
and harness, the local contract proof, and live positive and negative controls.
Changes to the rule require a reviewed `.github` PR, a released signed manifest
bundle, successful reconciliation, and a live ruleset readback.

## Consequences

A candidate can no longer make a required scene disappear, substitute its own
test harness, alter the pass marker rules, or replace the aggregate job that
the ruleset requires. Ordinary `ci.yaml` discovery remains useful for new and
candidate-authored tests, but it is not the immutable product-law boundary.

The trusted snapshot advances with the World base branch, while its externally
hosted selector prevents the candidate under evaluation from choosing a weaker
snapshot. A change that needs a different regression contract must preserve
compatibility with the active base while the replacement is reviewed and
activated; feature-flagged expand-first delivery is the normal path. The live
ruleset readback and canaries are release evidence, not repository prose.

The required workflow duplicates the client regression execution on proposed
changes. That runner cost is accepted because the second execution establishes
an independent selection and verdict boundary; reusing the candidate job would
restore the authority collision this decision removes.
