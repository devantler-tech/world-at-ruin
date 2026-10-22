#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="$root/tools/client-scene-workflow-guard.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
[[ -f "$guard" ]] || {
  echo 'FAIL: scene workers have no workflow contract' >&2
  exit 1
}
bash "$guard"
yq -o=json . "$root/.github/workflows/ci.yaml" >"$scratch/workflow.json"
mutations=(
  'del(.jobs["client-scene-shards"])'
  '.jobs["client-scene-shards"].if="false"'
  '.jobs["client-scene-shards"]["continue-on-error"]=true'
  '.jobs["client-scene-shards"]["timeout-minutes"]=30'
  '.jobs["client-scene-shards"].strategy["fail-fast"]=true'
  '.jobs["client-scene-shards"].strategy.matrix.shard=["0","1"]'
  '.jobs["client-scene-shards"].strategy.matrix.shard=["0","1","1"]'
  '.jobs["client-scene-shards"].strategy.matrix.exclude=[{shard:"2"}]'
  '.jobs["client-scene-shards"].env.SCENE_SHARD="0"'
  '.jobs["client-scene-shards"].steps[0].with.ref="main"'
  '.jobs["client-scene-shards"].steps[1].run="true"'
  '.jobs["client-scene-shards"].steps[3].run="true"'
  '.jobs["client-scene-shards"].steps[4].run="true"'
  '.jobs["client-scene-shards"].steps[5].run="true"'
  '.jobs["client-scene-shards"].steps[6].if="false"'
  '.jobs["client-scene-shards"].steps[6].run="true"'
  '.jobs["client-scene-shards"].steps[7].with.name="unbound"'
  '.jobs["client-scene-shards"].steps[7].with["if-no-files-found"]="ignore"'
  '.jobs["client-scene-proof"].needs=[]'
  '.jobs["client-scene-proof"].if="always()"'
  '.jobs["client-scene-proof"].steps[0].with["persist-credentials"]=true'
  '.jobs["client-scene-proof"].steps[2].with.pattern="client-scenes-*"'
  '.jobs["client-scene-proof"].steps[2].with["merge-multiple"]=true'
  '.jobs["client-scene-proof"].steps[3].run="true"'
  '.jobs["client-scene-proof"].steps[4].run="echo complete=true"'
  '.jobs["client-scene-proof"].outputs.complete="true"'
  '.jobs["ci-required-checks"].needs|=map(select(.!="client-scene-shards"))'
  '.jobs["ci-required-checks"].needs|=map(select(.!="client-scene-proof"))'
  '(.jobs["client-ordinary"].steps[]|select((.run//"")|startswith("./tools/run-client-test.sh "))).if="false"'
  '(.jobs["client-ordinary"].steps[]|select((.run//"")|startswith("./tools/run-client-test.sh ")))["continue-on-error"]=true'
  '(.jobs["client-ordinary"].steps[]|select((.run//"")|startswith("./tools/run-client-test.sh "))).shell="true {0}"'
  '(.jobs["client-ordinary"].steps[]|select((.run//"")|startswith("./tools/run-client-test.sh ")))["working-directory"]="fixture"'
  '(.jobs["client-ordinary"].steps[]|select((.run//"")|startswith("./tools/run-client-test.sh "))).env={PATH:"fixture"}'
  '(.jobs["client-ordinary"].steps[]|select((.run//"")|startswith("./tools/run-client-test.sh "))).run|="if false; then\n"+.+"\nfi"'
)
for mutation in "${mutations[@]}"; do
  jq "$mutation" "$scratch/workflow.json" >"$scratch/mutant.json"
  if bash "$guard" "$scratch/mutant.json" >"$scratch/verdict" 2>&1; then
    echo "FAIL: accepted scene workflow mutation $mutation" >&2
    exit 1
  fi
done
echo "TEST PASS -- complete scene routing refuses ${#mutations[@]} omissions and evidence substitutions"
