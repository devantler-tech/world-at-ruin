# ADR 0003: Pin required regressions outside candidate control

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
a source repository, workflow path and exact source commit, and runs the source
workflow for pull-request and merge-group events.

## Decision

The repository ruleset `Require workflow - World at Ruin trusted regressions`
requires `.github/workflows/required-regressions.yaml` at one exact reviewed
commit SHA. The source workflow is disabled for ordinary repository event
dispatch; its ruleset invocation is the required authority.

The workflow checks out two trees:

1. the candidate merge or merge-group commit, which supplies product code;
2. `github.workflow_sha`, which supplies the selector, every trusted
   `client/tests/*_test.tscn` scene and fixture, and
   `tools/run-client-test.sh`.

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

The ruleset source uses a commit SHA, never a moving branch. A source rotation
is complete only when the replacement workflow, controller and harness are on
the default branch, their local contract and exact-head review are green, a
live candidate-deletes-scene control fails as expected, and the active ruleset
readback names the replacement SHA. The previous SHA remains active until all
of those conditions hold.

## Consequences

A candidate can no longer make a required scene disappear, substitute its own
test harness, alter the pass marker rules, or replace the aggregate job that
the ruleset requires. Ordinary `ci.yaml` discovery remains useful for new and
candidate-authored tests, but it is not the immutable product-law boundary.

The trusted snapshot advances deliberately. A change that needs a different
regression contract must preserve compatibility with the active snapshot while
the replacement is reviewed and activated; feature-flagged expand-first
delivery is the normal path. The ruleset rotation is an explicit deployment
step and its exact-SHA readback is release evidence, not repository prose.

The required workflow duplicates the client regression execution on proposed
changes. That runner cost is accepted because the second execution establishes
an independent selection and verdict boundary; reusing the candidate job would
restore the authority collision this decision removes.
