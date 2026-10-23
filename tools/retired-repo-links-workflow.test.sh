#!/usr/bin/env bash
# Check the actual wrappers/action YAML, then reject independent routing,
# credential and required-check bypasses. Native CI proves runner execution.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
workflow="$root/.github/workflows/retired-repo-links.yaml"
action="$root/.github/actions/retired-repo-links/action.yaml"
if [[ ! -f "$workflow" ]]; then
  echo 'TEST FAIL -- no retired-link guard workflow can run on main pushes' >&2
  exit 1
fi
if [[ ! -f "$action" ]]; then
  echo 'TEST FAIL -- share the retired-link steps through the repository-owned action, not a singleton workflow export' >&2
  exit 1
fi
yq -o=json '.' "$root/.github/workflows/ci.yaml" >"$scratch/ci.json"
yq -o=json '.' "$workflow" >"$scratch/guard.json"
yq -o=json '.' "$action" >"$scratch/action.json"
jq -s 'if length == 3 and all(type == "object") then {ci:.[0],guard:.[1],action:.[2]}
  else error("require complete single-document workflow/action observations") end' \
  "$scratch/ci.json" "$scratch/guard.json" "$scratch/action.json" >"$scratch/bundle.json"

# admit reads parsed workflow data; it never evaluates a GitHub expression or
# executes fixture-controlled shell. Closed key sets prevent optional filters,
# conditions, inherited secrets and success-on-error settings from hiding work.
# Action revisions are read from the workflow rather than repeated here, so a
# routine version update does not need a matching edit to this file. What stays
# fixed is their shape: each is one full commit id, and refusal controls build
# the source output returned by the scan, with no second revision declaration.
admit() {
  jq -e '
    def pinned($action): capture("^" + $action + "@(?<sha>[0-9a-f]{40})$").sha;
    def wrapper($checkout):
      keys == ["name","permissions","runs-on","steps","timeout-minutes"]
      and .permissions == {contents:"read"}
      and ."runs-on" == "ubuntu-latest" and ."timeout-minutes" == 10
      and (.steps | length) == 2
      and (.steps[0] | keys == ["uses","with"] and .uses == $checkout
        and .with == {ref:"${{ github.sha }}","persist-credentials":false})
      and (.steps[1] | keys == ["name","uses"]
        and .uses == "$/.github/actions/retired-repo-links");
    (.guard.jobs["retired-repo-links"].steps[0].uses | pinned("actions/checkout")) as $checkout_sha
    | ("actions/checkout@" + $checkout_sha) as $checkout
    | (.action.runs.steps[0].uses
      | pinned("devantler-tech/\\.github/actions/validate-retired-repo-links")) as $source
    | ("devantler-tech/.github/actions/validate-retired-repo-links@" + $source) as $validator
    |
    .ci.on == {pull_request:null,merge_group:null}
    and .ci.permissions == {contents:"read"}
    and (.ci.jobs["retired-repo-links"] | wrapper($checkout))
    and (.ci.jobs["ci-required-checks"] |
      (.needs | index("retired-repo-links")) != null
      and .if == "${{ always() }}"
      and (.steps | length) == 5
      and ([.steps[] | select(.uses? | strings | startswith("devantler-tech/.github/actions/aggregate-job-checks@"))] | length) == 1
      and (.steps[-1] | keys == ["uses","with"]
        and (.uses | pinned("devantler-tech/\\.github/actions/aggregate-job-checks") | type) == "string"
        and (.with | keys) == ["job-results"]
        and (.with["job-results"] | contains("${{ needs.retired-repo-links.result }}"))))
    and (.guard | keys == ["jobs","name","on","permissions"]
      and .on == {push:{branches:["main"]}}
      and .permissions == {contents:"read"}
      and (.jobs | keys) == ["retired-repo-links"])
    and (.guard.jobs["retired-repo-links"] | wrapper($checkout))
    and (.action | keys == ["author","description","name","runs"]
      and .author == "devantler-tech"
      and (.runs | keys == ["steps","using"] and .using == "composite"
        and (.steps | length) == 4))
    and (.action.runs.steps |
      (.[0] | keys == ["id","name","uses","with"]
        and .id == "links" and .uses == $validator and .with == {enabled:"true"})
      and (.[1] | keys == ["env","name","run","shell"] and .shell == "bash"
        and .env == {VALIDATED:"${{ steps.links.outputs.validated }}"}
        and .run == "test \"$VALIDATED\" = true")
      and (.[2] | keys == ["env","name","run","shell"] and .shell == "bash"
        and .env == {GOWORK:"off",GOFLAGS:"",GOTOOLCHAIN:"local",
          VALIDATOR_SOURCE:"${{ steps.links.outputs.source-directory }}"}
        and .run == "bash tools/retired-repo-links-controls.sh")
      and (.[3] | keys == ["name","run","shell"] and .shell == "bash"
        and .run == "bash tools/retired-repo-links-workflow.test.sh"))
  ' "$1" >/dev/null
}
if ! admit "$scratch/bundle.json"; then
  echo 'TEST FAIL -- restore main-only routing, the shared read-only guard and its required CI result' >&2
  exit 1
fi

# Derive selection from the admitted production trigger: main is the sole push
# branch, tags and other branches do not match, and ordinary app CI stays PR-only.
for ref in refs/heads/main refs/heads/feature refs/tags/v1.0.0; do
  selected=$(jq --arg ref "$ref" '
    .guard.on.push.branches | map("refs/heads/" + .) | index($ref) != null
  ' "$scratch/bundle.json")
  case "$ref:$selected" in
  refs/heads/main:true | refs/heads/feature:false | refs/tags/v1.0.0:false) ;;
  *)
    echo "TEST FAIL -- wrong push selection for $ref" >&2
    exit 1
    ;;
  esac
done

# A dependency updater changes only the declared action revision. This must
# remain admissible without a source-checkout or guard-test pin update.
jq '.action.runs.steps[0].uses="devantler-tech/.github/actions/validate-retired-repo-links@" + ("a" * 40)' \
  "$scratch/bundle.json" >"$scratch/updated-pin.json"
if ! admit "$scratch/updated-pin.json"; then
  echo 'TEST FAIL -- an isolated immutable validator pin update requires another edit' >&2
  exit 1
fi

mutation_count=0
for mutation in \
  'del(.guard.on.push)' \
  '.guard.on.push.branches=["feature"]' \
  '.guard.on.push.branches += ["feature"]' \
  '.guard.on.push.paths=["README.md"]' \
  '.guard.on.push.tags=["v*"]' \
  '.guard.on.workflow_call=null' \
  '.ci.on.push={branches:["main"]}' \
  '.ci.jobs["retired-repo-links"].steps[1].uses="./.github/workflows/ci.yaml"' \
  '.ci.jobs["retired-repo-links"].if="false"' \
  '.ci.jobs["retired-repo-links"].secrets="inherit"' \
  '.guard.permissions={contents:"write"}' \
  '.guard.jobs["retired-repo-links"].permissions={contents:"write"}' \
  '.guard.jobs["retired-repo-links"].if="false"' \
  '.guard.jobs["retired-repo-links"].steps[0].with["persist-credentials"]=true' \
  '.ci.jobs["retired-repo-links"].steps[0].with["persist-credentials"]=true' \
  '.ci.jobs["retired-repo-links"].steps[1]["continue-on-error"]=true' \
  '.guard.jobs["retired-repo-links"].steps[1].uses="$/actions/other"' \
  '.guard.jobs["retired-repo-links"].steps[1].uses="./.github/actions/retired-repo-links"' \
  '.guard.jobs["retired-repo-links"].steps[1].if="false"' \
  '.action.runs.steps[0].with.enabled="false"' \
  '.action.runs.steps[0].if="false"' \
  '.action.runs.steps[2].env.VALIDATOR_SOURCE="/tmp/substituted-validator"' \
  '.action.runs.steps[2].env.VALIDATOR_SOURCE |= sub("steps.links"; "steps.other")' \
  '.action.runs.steps[2].run = "VALIDATOR_SOURCE=/tmp/substituted-validator\n" + .action.runs.steps[2].run' \
  '.action.runs.steps[2].env.GOFLAGS="-C /tmp/substituted-validator"' \
  '.action.runs.steps[2].env.GOTOOLCHAIN="auto"' \
  '.action.runs.steps[1].run="true"' \
  '.action.runs.steps[2]["continue-on-error"]=true' \
  '.action.runs.steps[3].run="true"' \
  '.action.runs.steps[2].shell="sh"' \
  '.ci.jobs["ci-required-checks"].needs |= map(select(. != "retired-repo-links"))' \
  '.ci.jobs["ci-required-checks"].steps[-1].with["job-results"]="success"' \
  '.ci.jobs["ci-required-checks"].steps += [.ci.jobs["ci-required-checks"].steps[-1]]' \
  '.ci.jobs["ci-required-checks"].steps[-1].if="false"' \
  '.ci.jobs["ci-required-checks"].steps[-1]["continue-on-error"]=true' \
  '.ci.jobs["ci-required-checks"].steps[-1].uses="actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"' \
  '.guard.jobs["retired-repo-links"].steps[0].uses="actions/checkout@v7"' \
  '.action.runs.steps[0].uses="devantler-tech/.github/actions/validate-retired-repo-links@v7.2.10"' \
  '.action.runs.steps[0].uses="devantler-tech/.github/actions/validate-retired-repo-links@main"' \
  '.ci.jobs["ci-required-checks"].steps[-1].uses="devantler-tech/.github/actions/aggregate-job-checks@v7"' \
  '.ci.jobs["ci-required-checks"].steps[-1].uses="example/.github/actions/aggregate-job-checks@bd0035dd8f41fcf1459b878882b8897443f8dc59"'; do
  jq "$mutation" "$scratch/bundle.json" >"$scratch/mutant.json"
  mutation_count=$((mutation_count + 1))
  if cmp -s "$scratch/bundle.json" "$scratch/mutant.json"; then
    echo "TEST FAIL -- mutation did not change the fixture: $mutation" >&2
    exit 1
  fi
  if admit "$scratch/mutant.json"; then
    echo "TEST FAIL -- workflow accepted $mutation" >&2
    exit 1
  fi
done
echo "TEST PASS -- main-only shared guard, read-only credentials and $mutation_count rejected wiring mutations"
