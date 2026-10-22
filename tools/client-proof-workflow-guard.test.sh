#!/usr/bin/env bash
# Mutate actual workflow inputs to the same guard used by the stable check.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="$root/tools/client-proof-workflow-guard.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bash "$guard"
yq -o=json '.' "$root/.github/workflows/ci.yaml" > "$tmp/base.json"
if ! jq -e '
  (.jobs | has("client-smoke") | not)
  and (.jobs["ci-required-checks"] |
    (.steps | length) == 5
    and .steps[3].run == "bash tools/client-proof-gate.sh"
    and (.needs | index("client-ordinary")) != null
    and (.needs | index("client-sandbox")) != null)
' "$tmp/base.json" >/dev/null; then
  echo 'FAIL: client proof validation and aggregation need one runner allocation' >&2
  exit 1
fi
mutations=(
  '.jobs["ci-required-checks"].needs = ["client-ordinary"]'
  '.jobs["ci-required-checks"].if = "false"'
  '.jobs["ci-required-checks"]["continue-on-error"] = true'
  '.jobs["ci-required-checks"].steps[3]["continue-on-error"] = true'
  ".jobs[\"ci-required-checks\"].steps[3].env.EXPECTED_SHA = \"\${{ github.event.pull_request.head.sha }}\""
  '.jobs["ci-required-checks"].steps[3].env.ORDINARY_COMPLETE = "true"'
  ".jobs[\"ci-required-checks\"].steps[3].env.SANDBOX_SHA = \"\${{ github.sha }}\""
  '.jobs["client-ordinary"].if = "false"'
  '.jobs["client-ordinary"]["timeout-minutes"] = 75'
  '.jobs["ci-required-checks"].steps[3].env.SCENES_COMPLETE = "true"'
  '.jobs["ci-required-checks"].steps[3].env.SCENES_SHA = "unknown"'
  '.jobs["ci-required-checks"].steps[3].env.CLOTH_SELECTED = "false"'
  '.jobs["ci-required-checks"].steps[3].env.CLOTH_RESULT = "success"'
  '.jobs["client-ordinary"].steps[-1].if = "always()"'
  '.jobs["client-ordinary"].steps[-1].run = "true"'
  ".jobs[\"client-ordinary\"].steps[0].with.ref = \"\${{ github.event.pull_request.head.sha }}\""
  '.jobs["client-ordinary"].steps[4].shell = "bash"'
  '.jobs["client-ordinary"].steps[4].if = "false"'
  '.jobs["ci-required-checks"].steps[3].shell = "true {0}"'
  '.jobs["client-ordinary"].steps[1].run = "true"'
  '.jobs["client-sandbox"]["continue-on-error"] = true'
  '.jobs["client-sandbox"].steps[4].run = "true"'
  '.jobs["client-sandbox"].steps[4].env.WAR_TRUSTED_RUNTIME_FOOTPRINT = "0"'
  '.jobs["client-sandbox"].steps[4].env.WAR_TRUSTED_RUNTIME_INVENTORY_PROBE = "0"'
  '.jobs["client-sandbox"].steps[4].if = "false"'
  '.jobs["client-sandbox"].steps[2].run = "true"'
  '.jobs["client-sandbox"].steps[2].run |= (split("\n") | .[1:] | join("\n"))'
  '.jobs["client-sandbox"].steps[2].run |= sub("bash tools/trusted-runtime-bases.test.sh\n"; "")'
  '.jobs["client-sandbox"].steps[2].run |= sub("bash tools/trusted-runtime-packages.test.sh\n"; "")'
  '.jobs["client-sandbox"].steps[2].run |= sub("bash tools/trusted-runtime-transaction.test.sh\n"; "")'
  '.jobs["client-sandbox"].steps[2].run |= sub("bash tools/propose-trusted-runtime-archives.test.sh\n"; "")'
  '.jobs["client-sandbox"].steps[2].run |= sub("go test tools/trusted-runtime-origin/main.go tools/trusted-runtime-origin/main_test.go\n"; "")'
  '.jobs["client-sandbox"].steps[2].run |= sub("go test tools/trusted-runtime-archives/main.go tools/trusted-runtime-archives/main_test.go\n"; "")'
  '.jobs["client-sandbox"].steps[-1].run = "echo complete=true"'
  '.jobs["client-sandbox"].steps[0].with.ref = "main"'
  '.jobs["ci-required-checks"].needs |= map(select(. != "client-sandbox"))'
  ".jobs[\"ci-required-checks\"].steps[4].with[\"job-results\"] = \"\${{ needs.client-ordinary.result }}\""
  '.jobs["ci-required-checks"].steps[4]["continue-on-error"] = true'
  '.permissions = {contents:"write"}'
  '.env.BASH_ENV = "/tmp/override"'
  '.defaults = {run:{shell:"true {0}"}}'
  '.jobs["ci-required-checks"].permissions = {contents:"write"}'
  '.jobs["ci-required-checks"].defaults = {run:{shell:"true {0}"}}'
  '.jobs["ci-required-checks"]["timeout-minutes"] = 75'
  '.jobs["ci-required-checks"].env = {BASH_ENV:"/tmp/override"}'
  '.jobs["ci-required-checks"].steps[0].with["persist-credentials"] = true'
  '.jobs["ci-required-checks"].steps[0].with.ref = "main"'
  '.jobs["ci-required-checks"].steps[1].run = "true"'
  '.jobs["ci-required-checks"].steps[2].run = "true"'
  '.jobs["ci-required-checks"].steps[3].run = "true"'
  '.jobs["ci-required-checks"].steps[3].if = "false"'
  '.jobs["ci-required-checks"].steps[3]["working-directory"] = "/tmp/other"'
  '.jobs["ci-required-checks"].steps[4].if = "always()"'
  '.jobs["ci-required-checks"].steps[4].uses = "devantler-tech/.github/actions/aggregate-job-checks@main"'
  '.jobs["ci-required-checks"].steps[4].with["job-results"] += " success"'
  '.jobs["ci-required-checks"].steps += [.jobs["ci-required-checks"].steps[4]]'
  '.jobs["client-smoke"] = {steps:[{run:"true"}]}'
  ".jobs[\"ci-required-checks\"].steps[4].with[\"job-results\"] |= (split(\"\${{ needs.client-ordinary.result == 'success' && 'success' || 'failure' }}\") | join(\"\${{ needs.client-ordinary.result }}\"))"
  ".jobs[\"ci-required-checks\"].steps[4].with[\"job-results\"] |= (split(\"\${{ needs.client-sandbox.result == 'success' && 'success' || 'failure' }}\") | join(\"\${{ needs.client-sandbox.result }}\"))"
  ".jobs[\"ci-required-checks\"].steps[4].with[\"job-results\"] |= (split(\"\${{ needs.owned-child-native.result == 'success' && 'success' || 'failure' }}\") | join(\"\${{ needs.owned-child-native.result }}\"))"
)
for dependency in retired-repo-links client-ordinary client-sandbox client-scene-shards client-scene-proof client-export-macos license-guard lint duplication-gate gdscript-lint go-vulnerability-scan server-ci gameserver-commit-trial zone-container nakama-native spire-native owned-child-native detect-visual-changes frame-capture frame-capture-cloth frame-capture-exported; do
  mutations+=(".jobs[\"ci-required-checks\"].needs |= map(select(. != \"$dependency\"))")
done
mutation_count=0
for mutation in "${mutations[@]}"; do
  mutation_count=$((mutation_count + 1))
  jq "$mutation" "$tmp/base.json" > "$tmp/mutated.json"
  if cmp -s "$tmp/base.json" "$tmp/mutated.json"; then
    echo "FAIL: no-op workflow mutation: $mutation" >&2; exit 1
  fi
  if bash "$guard" "$tmp/mutated.json" > "$tmp/verdict" 2>&1; then
    echo "FAIL: workflow guard accepted $mutation" >&2; exit 1
  fi
done
echo "TEST PASS -- client workflow rejects $mutation_count omissions, skips, error masking and false completion"
