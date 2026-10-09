#!/usr/bin/env bash
# Check the actual caller/callee YAML, then reject independent routing,
# credential and required-check bypasses. Native CI proves runner execution.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
workflow="$root/.github/workflows/retired-repo-links.yaml"
if [[ ! -f "$workflow" ]]; then
  echo 'TEST FAIL -- no retired-link guard workflow can run on main pushes' >&2
  exit 1
fi
yq -o=json '.' "$root/.github/workflows/ci.yaml" >"$scratch/ci.json"
yq -o=json '.' "$workflow" >"$scratch/guard.json"
jq -s '{ci:.[0],guard:.[1]}' "$scratch/ci.json" "$scratch/guard.json" >"$scratch/bundle.json"

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
    (.guard.jobs["retired-repo-links"].steps[0].uses | pinned("actions/checkout")) as $checkout_sha
    | ("actions/checkout@" + $checkout_sha) as $checkout
    | (.guard.jobs["retired-repo-links"].steps[1].uses
      | pinned("devantler-tech/\\.github/actions/validate-retired-repo-links")) as $source
    | ("devantler-tech/.github/actions/validate-retired-repo-links@" + $source) as $validator
    |
    .ci.on == {pull_request:null,merge_group:null}
    and .ci.permissions == {contents:"read"}
    and (.ci.jobs["retired-repo-links"] |
      keys == ["name","permissions","uses"]
      and .uses == "./.github/workflows/retired-repo-links.yaml"
      and .permissions == {contents:"read"})
    and (.ci.jobs["ci-required-checks"] |
      (.needs | index("retired-repo-links")) != null
      and .if == "${{ always() }}"
      and (.steps | length) == 1
      and (.steps[0] | keys == ["uses","with"]
        and (.uses | pinned("devantler-tech/\\.github/actions/aggregate-job-checks") | type) == "string"
        and (.with | keys) == ["job-results"]
        and (.with["job-results"] | contains("${{ needs.retired-repo-links.result }}"))))
    and (.guard | keys == ["jobs","name","on","permissions"]
      and .on == {workflow_call:null,push:{branches:["main"]}}
      and .permissions == {contents:"read"}
      and (.jobs | keys) == ["retired-repo-links"])
    and (.guard.jobs["retired-repo-links"] |
      keys == ["name","permissions","runs-on","steps","timeout-minutes"]
      and .permissions == {contents:"read"}
      and ."runs-on" == "ubuntu-latest" and ."timeout-minutes" == 10
      and (.steps | length) == 5
      and all(.steps[]; (has("if") or has("continue-on-error") or has("shell") or has("working-directory")) | not))
    and (.guard.jobs["retired-repo-links"].steps |
      (.[0] | keys == ["uses","with"] and .uses == $checkout
        and .with == {"persist-credentials":false})
      and (.[1] | keys == ["id","name","uses","with"]
        and .id == "links" and .uses == $validator and .with == {enabled:"true"})
      and (.[2] | keys == ["env","name","run"]
        and .env == {VALIDATED:"${{ steps.links.outputs.validated }}"}
        and .run == "test \"$VALIDATED\" = true")
      and (.[3] | keys == ["env","name","run"]
        and .env == {GOWORK:"off",GOFLAGS:"",GOTOOLCHAIN:"local",
          VALIDATOR_SOURCE:"${{ steps.links.outputs.source-directory }}"}
        and .run == "bash tools/retired-repo-links-controls.sh")
      and (.[4] | keys == ["name","run"]
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
jq '.guard.jobs["retired-repo-links"].steps[1].uses="devantler-tech/.github/actions/validate-retired-repo-links@" + ("a" * 40)' \
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
  'del(.guard.on.workflow_call)' \
  '.ci.on.push={branches:["main"]}' \
  '.ci.jobs["retired-repo-links"].uses="./.github/workflows/ci.yaml"' \
  '.ci.jobs["retired-repo-links"].if="false"' \
  '.ci.jobs["retired-repo-links"].secrets="inherit"' \
  '.guard.permissions={contents:"write"}' \
  '.guard.jobs["retired-repo-links"].permissions={contents:"write"}' \
  '.guard.jobs["retired-repo-links"].if="false"' \
  '.guard.jobs["retired-repo-links"].steps[0].with["persist-credentials"]=true' \
  '.guard.jobs["retired-repo-links"].steps[1].with.enabled="false"' \
  '.guard.jobs["retired-repo-links"].steps[3].env.VALIDATOR_SOURCE="/tmp/substituted-validator"' \
  '.guard.jobs["retired-repo-links"].steps[3].env.VALIDATOR_SOURCE |= sub("steps.links"; "steps.other")' \
  '.guard.jobs["retired-repo-links"].steps[3].run = "VALIDATOR_SOURCE=/tmp/substituted-validator\n" + .guard.jobs["retired-repo-links"].steps[3].run' \
  '.guard.jobs["retired-repo-links"].steps[3].env.GOFLAGS="-C /tmp/substituted-validator"' \
  '.guard.jobs["retired-repo-links"].steps[3].env.GOTOOLCHAIN="auto"' \
  '.guard.jobs["retired-repo-links"].steps[2].run="true"' \
  '.guard.jobs["retired-repo-links"].steps[3]["continue-on-error"]=true' \
  '.guard.jobs["retired-repo-links"].steps[4].run="true"' \
  '.ci.jobs["ci-required-checks"].needs |= map(select(. != "retired-repo-links"))' \
  '.ci.jobs["ci-required-checks"].steps[0].with["job-results"]="success"' \
  '.ci.jobs["ci-required-checks"].steps[0].if="false"' \
  '.ci.jobs["ci-required-checks"].steps[0]["continue-on-error"]=true' \
  '.ci.jobs["ci-required-checks"].steps[0].uses="actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"' \
  '.guard.jobs["retired-repo-links"].steps[0].uses="actions/checkout@v7"' \
  '.guard.jobs["retired-repo-links"].steps[1].uses="devantler-tech/.github/actions/validate-retired-repo-links@v7.2.10"' \
  '.guard.jobs["retired-repo-links"].steps[1].uses="devantler-tech/.github/actions/validate-retired-repo-links@main"' \
  '.ci.jobs["ci-required-checks"].steps[0].uses="devantler-tech/.github/actions/aggregate-job-checks@v7"' \
  '.ci.jobs["ci-required-checks"].steps[0].uses="example/.github/actions/aggregate-job-checks@bd0035dd8f41fcf1459b878882b8897443f8dc59"'; do
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
