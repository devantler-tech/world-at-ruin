#!/usr/bin/env bash
# Mutation controls exercise the actual workflow and its pre-checkout admission.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
workflow="$root/.github/workflows/issued-native-stability.yaml"
guard="$root/tools/issued-native-stability-workflow-guard.sh"
bash "$guard" "$workflow"
yq -o=json '.' "$workflow" > "$scratch/workflow.json"
for mutation in \
  '.on.pull_request={}' \
  '.on.workflow_dispatch.inputs.source={type:"string"}' \
  '.permissions.contents="write"' \
  '.jobs.admit.steps[0].if="false"' \
  '.jobs.admit.steps[0]["continue-on-error"]=true' \
  '.jobs.admit.steps[0].run="echo source=unbound"' \
  '.jobs.trials.needs=[]' \
  '.jobs.trials.strategy["fail-fast"]=true' \
  '.jobs.trials.strategy.matrix.include |= .[:1]' \
  '.jobs.trials.steps[0].with.ref="main"' \
  '.jobs.trials.steps[0].with["persist-credentials"]=true' \
  '.jobs.trials.steps[2].with["build-args"]="EXPERIMENTAL=true\nRUNTIME_PROFILE=native\n"' \
  '.jobs.trials.steps[3].env.IMAGE_ID="mutable-tag"' \
  '.jobs.trials.steps[3].run += " || true"' \
  '.jobs.trials.steps[3].if="false"' \
  '.jobs.trials.steps[3]["continue-on-error"]=true' \
  '.jobs.trials.steps[3]["timeout-minutes"]=60'; do
  jq "$mutation" "$scratch/workflow.json" > "$scratch/mutant.json"
  if bash "$guard" "$scratch/mutant.json" > "$scratch/result" 2>&1; then
    echo "FAIL: startup workflow accepted $mutation"; exit 1
  fi
done
if bash "$guard" "$scratch/missing" > "$scratch/result" 2>&1; then exit 1; fi
jq -r '.jobs.admit.steps[0].run' "$scratch/workflow.json" > "$scratch/admit.sh"
export GITHUB_REPOSITORY=devantler-tech/world-at-ruin GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main
export GITHUB_WORKFLOW_REF=devantler-tech/world-at-ruin/.github/workflows/issued-native-stability.yaml@refs/heads/main
export GITHUB_SHA GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=1 CONFIRMATION=measure-issued-startup GITHUB_OUTPUT="$scratch/outputs"
GITHUB_SHA=$(printf '%040d' 1)
bash "$scratch/admit.sh"
grep -Fxq "source=$GITHUB_SHA" "$GITHUB_OUTPUT"
for rejection in 'GITHUB_REPOSITORY=other/project' 'GITHUB_EVENT_NAME=pull_request' 'GITHUB_REF=refs/heads/candidate' \
  'GITHUB_WORKFLOW_REF=devantler-tech/world-at-ruin/.github/workflows/other.yaml@refs/heads/main' \
  'GITHUB_SHA=main' 'GITHUB_RUN_ID=0' 'GITHUB_RUN_ATTEMPT=0' 'CONFIRMATION=anything'; do
  : > "$GITHUB_OUTPUT"
  if env "$rejection" bash "$scratch/admit.sh" > "$scratch/result" 2>&1; then echo "FAIL: admission accepted $rejection"; exit 1; fi
  [[ ! -s $GITHUB_OUTPUT ]]
done
actual_yq=$(command -v yq)
mkdir "$scratch/bin"
cat > "$scratch/bin/yq" <<'YQ'
#!/usr/bin/env bash
set -euo pipefail
"$STABILITY_REAL_YQ" "$@"
exit 1
YQ
chmod +x "$scratch/bin/yq"
if STABILITY_REAL_YQ="$actual_yq" PATH="$scratch/bin:$PATH" bash "$guard" "$workflow" > "$scratch/result" 2>&1; then
  echo 'FAIL: workflow accepted valid partial parser output followed by failure'; exit 1
fi
echo 'TEST PASS: manual main-only measurement, exact checkout and mandatory two-architecture execution remain bound'
