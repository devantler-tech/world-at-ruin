# World product admission

This is the product-owned interface for the shared reviewed-base PR admission
runner. It accepts one input, `candidate-sha`: GitHub's immutable PR integration
or merge-group commit, never a branch name. The shared workflow checks out the
product base before loading this action.

The entrypoint verifies the canonical shared workflow origin, event identities
and unchanged reviewed-base files. Candidate bytes are fetched anonymously into
private state and executed only by the existing complete contained regression
controller. The pinned host Go toolchain builds the controller; Godot and its
package/archive checks belong to the reviewed contained runtime. Cleanup and
unknown outcomes retain their existing fail-closed behavior.

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
