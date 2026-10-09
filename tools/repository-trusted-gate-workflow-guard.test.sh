#!/usr/bin/env bash
# Mutate credential, source and verdict boundaries without running candidate code.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
workflow="$root/.github/workflows/repository-trusted-regressions.yaml"
guard="$root/tools/repository-trusted-gate-workflow-guard.sh"
fail() { echo "TEST FAIL -- repository trusted gate workflow: $*" >&2; exit 1; }
bash "$guard" "$workflow" >"$work/log" 2>&1 || { cat "$work/log"; fail 'reviewed workflow was rejected'; }
yq -o=json '.' "$workflow" | jq -S . >"$work/baseline.json"
count=0
for mutation in \
  '.on.workflow_run.workflows=["Fake CI"]' \
  '.on.workflow_run.types=["requested"]' \
  '.on.workflow_dispatch={}' \
  '.permissions={"checks":"write"}' \
  '.jobs.evaluate.if="true"' \
  ".jobs.publish.if=\"\${{ always() }}\"" \
  '.jobs.publish.environment="unprotected"' \
  '.jobs.evaluate.environment="world-trusted-gate-publisher"' \
  '.jobs.evaluate.permissions.checks="write"' \
  '.jobs.publish.permissions.checks="write"' \
  ".jobs.evaluate.steps[1].with.ref=\"\${{ github.event.workflow_run.head_sha }}\"" \
  ".jobs.publish.steps[1].with.ref=\"\${{ github.event.workflow_run.head_sha }}\"" \
  '.jobs.evaluate.steps[1].with."persist-credentials"=true' \
  '.jobs.publish.steps[1].with."persist-credentials"=true' \
  '.jobs.evaluate.steps[2].run="true"' \
  '.jobs.publish.steps[2].run="true"' \
  ".jobs.evaluate.steps[4].env.GITHUB_TOKEN=\"\${{ secrets.APP_PRIVATE_KEY }}\"" \
  ".jobs.evaluate.steps[9].env={\"GITHUB_TOKEN\":\"\${{ github.token }}\"}" \
  '.jobs.evaluate.steps[9].run="bash candidate/tools/run-sandboxed-trusted-regressions.sh trusted candidate"' \
  '.jobs.evaluate.steps[9]."continue-on-error"=true' \
  '.jobs.evaluate.steps[9].if="false"' \
  '.jobs.evaluate.steps[9].shell="true {0}"' \
  '.jobs.evaluate.steps[9]."working-directory"="candidate"' \
  '.jobs.publish.steps[4].with."client-id"="substituted-client"' \
  '.jobs.publish.steps[4].with."app-id"="123"' \
  '.jobs.publish.steps[4].with."private-key"="substituted-key"' \
  '.jobs.publish.steps[4].with.owner="other"' \
  '.jobs.publish.steps[4].with.repositories="other"' \
  '.jobs.publish.steps[4].with."permission-checks"="read"' \
  '.jobs.publish.steps[4].with."permission-contents"="write"' \
  '.jobs.publish.steps[4].with."permission-pull-requests"="write"' \
  '.jobs.publish.steps[4].uses="actions/create-github-app-token@main"' \
  '.jobs.publish.steps[5].env.VERDICT="success"' \
  'del(.jobs.evaluate.steps[4].env.WAR_REPOSITORY_TRUSTED_GATE_ENABLED)' \
  'del(.jobs.publish.steps[5].env.WAR_REPOSITORY_TRUSTED_GATE_ENABLED)' \
  ".jobs.publish.steps[5].env.VERDICT=\"\${{ needs.evaluate.result }}\"" \
  ".jobs.publish.steps[5].env.GITHUB_TOKEN=\"\${{ github.token }}\"" \
  '.jobs.publish.steps[5].run="true"' \
  '.jobs.publish.steps[5]."continue-on-error"=true' \
  '.jobs.publish.steps += [{"uses":"actions/download-artifact@main"}]' \
  '.jobs.publish.needs=[]' \
  ".jobs.publish.env={\"PRIVATE_KEY\":\"\${{ secrets.APP_PRIVATE_KEY }}\"}" \
  ".jobs.evaluate.outputs.\"identity-json\"=\"\${{ steps.untrusted.outputs.identity }}\"" \
  '.jobs.evaluate.steps[3].with."go-version"="latest"' \
  '.jobs.evaluate.steps[8].run="true"'; do
  yq "$mutation" "$workflow" >"$work/mutant.yaml"
  yq -o=json '.' "$work/mutant.yaml" | jq -S . >"$work/mutant.json"
  if cmp -s "$work/baseline.json" "$work/mutant.json"; then fail "ineffective mutation: $mutation"; fi
  count=$((count + 1))
  if bash "$guard" "$work/mutant.yaml" >"$work/log" 2>&1; then fail "accepted boundary regression: $mutation"; fi
done
if bash "$guard" "$work/missing.yaml" >"$work/log" 2>&1; then fail 'missing workflow passed'; fi
printf '{malformed' >"$work/malformed.yaml"
if bash "$guard" "$work/malformed.yaml" >"$work/log" 2>&1; then fail 'malformed workflow passed'; fi
{
  cat "$workflow"
  printf '\n---\n'
  cat "$workflow"
} >"$work/multiple.yaml"
if bash "$guard" "$work/multiple.yaml" >"$work/log" 2>&1; then fail 'multiple workflow documents passed'; fi
for change in \
  's/ignore\[dangerous-triggers\]/ignore[dangerous-triggers,artipacked]/' \
  '/# Candidate data runs only in containment/d'; do
  sed "$change" "$workflow" >"$work/annotation.yaml"
  if bash "$guard" "$work/annotation.yaml" >"$work/log" 2>&1; then fail "unaudited annotation passed: $change"; fi
done
echo "TEST PASS -- publisher wiring rejects $count source, credential, verdict and admission substitutions"
