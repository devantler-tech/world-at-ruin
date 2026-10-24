# World product admission

This is the product-owned interface for the shared reviewed-base PR admission
runner. It accepts one input, `candidate-sha`: GitHub's immutable PR integration
or merge-group commit, never a branch name. The shared workflow checks out the
product base before loading this action.

The entrypoint verifies the canonical shared workflow origin and uses the existing
reviewed event resolver, then verifies unchanged reviewed-base files. Candidate
bytes are fetched anonymously into private state and executed only by the existing complete contained regression
controller. The pinned host Go toolchain builds the controller; Godot and its
package/archive checks belong to the reviewed contained runtime. Cleanup and
unknown outcomes retain their existing fail-closed behavior.

For pull requests, the fetched integration commit must have exactly two ordered
parents matching the event's immutable base and head. This uses the raw Git object,
including after a depth-one fetch. The payload's `merge_commit_sha` can describe a
different integration snapshot and is not the witness for the commit GitHub selected
for this run. A missing checkout, different head or base, reversed or extra parents
fails before candidate execution. The older local controller's resolver interface
retains its existing behavior.

The closed `.github/pr-admission.json` contract gives the additive consumer a
15-minute outer bound. An exceeded deadline fails the new gate; it cannot count
as complete evidence. This setting is not a successful runtime measurement.
The existing required source remains unchanged through adoption proof.

Source presence does not activate enforcement. Organization enrollment,
passing/tampering overlap controls and retirement of the old required source
are managed separately in [the shared migration](https://github.com/devantler-tech/.github/issues/693).
Existing protection must remain active until those gates pass.

Validate with `bash tools/shared-product-admission.test.sh` and the existing
trusted workflow, lifecycle, deadline and containment tests. Native consumer
execution remains a separate adoption requirement.
