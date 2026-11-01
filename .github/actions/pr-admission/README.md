# World product admission

This is the product-owned interface for the shared reviewed-base PR admission
runner. It accepts one input, `candidate-sha`: GitHub's immutable PR integration
or merge-group commit, never a branch name. The shared workflow checks out the
product base before loading this action.

The entrypoint verifies the canonical shared workflow origin and uses the existing
reviewed event resolver, then verifies unchanged reviewed-base files. Candidate
bytes are fetched anonymously into private state and executed only by the existing complete contained regression
controller. The pinned host Go toolchain builds the controller. Before invoking
it, the action installs the reviewed Godot version with the existing SHA-512
verification script, from a private temporary download directory. The runtime
builder copies that engine into the contained runtime and retains all existing
package/archive checks. Candidate inputs cannot select the installer or pins. Cleanup and
unknown outcomes retain their existing fail-closed behavior.

For pull requests, the fetched integration commit must have exactly two ordered
parents, with its second parent matching the event's immutable head. This uses the
raw Git object, including after a depth-one fetch. Its first parent must equal the
event base or have canonical GitHub comparison evidence that it descends from that
base; a frozen event base can predate GitHub's rebuilt integration. The read uses
the job's existing contents-read token, a fixed repository and a 30-second bound.
Missing credentials, failed reads or inconsistent ancestry fail before candidate
execution, and the credential is cleared before the contained controller starts.
The payload's `merge_commit_sha` can describe a different integration snapshot and
is not the witness for the commit GitHub selected for this run. Missing checkouts,
different heads, reversed or extra parents still fail. The older local controller's
resolver interface retains its existing behavior.

The closed `.github/pr-admission.json` contract gives the consumer a
15-minute outer bound. An exceeded deadline fails the gate; it cannot count as
complete evidence. This setting is not a whole-PR runtime measurement.

The shared required runner is enrolled and native positive/refusal controls passed
both before and after the old World-only rule's managed retirement.
[ADR 0062](../../../docs/adr/0062-retire-unused-app-publisher-after-shared-admission.md)
records that evidence and the retirement of the unused App producer. Future
protection changes remain owned by [the declarative shared migration](https://github.com/devantler-tech/.github/issues/693);
source presence alone never proves live enforcement.

Validate with `bash tools/shared-product-admission.test.sh` and the existing
trusted workflow, lifecycle, deadline and containment tests. Native execution and protection
readback remain required whenever enforcement routing changes.
