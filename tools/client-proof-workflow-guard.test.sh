#!/usr/bin/env bash
# Mutate actual workflow inputs to the same guard used by the stable check.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="$root/tools/client-proof-workflow-guard.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bash "$guard"
yq -o=json '.' "$root/.github/workflows/ci.yaml" > "$tmp/base.json"
mutations=(
  '.jobs["client-smoke"].needs = ["client-ordinary"]'
  '.jobs["client-smoke"].if = "false"'
  '.jobs["client-smoke"]["continue-on-error"] = true'
  '.jobs["client-smoke"].steps[3]["continue-on-error"] = true'
  ".jobs[\"client-smoke\"].steps[3].env.EXPECTED_SHA = \"\${{ github.event.pull_request.head.sha }}\""
  '.jobs["client-smoke"].steps[3].env.ORDINARY_COMPLETE = "true"'
  ".jobs[\"client-smoke\"].steps[3].env.SANDBOX_SHA = \"\${{ github.sha }}\""
  '.jobs["client-ordinary"].if = "false"'
  '.jobs["client-ordinary"].steps[-1].if = "always()"'
  '.jobs["client-ordinary"].steps[-1].run = "true"'
  ".jobs[\"client-ordinary\"].steps[0].with.ref = \"\${{ github.event.pull_request.head.sha }}\""
  '.jobs["client-ordinary"].steps[4].shell = "bash"'
  '.jobs["client-ordinary"].steps[4].if = "false"'
  '.jobs["client-smoke"].steps[3].shell = "true {0}"'
  '.jobs["client-ordinary"].steps[1].run = "true"'
  '.jobs["client-sandbox"]["continue-on-error"] = true'
  '.jobs["client-sandbox"].steps[4].run = "true"'
  '.jobs["client-sandbox"].steps[4].env.WAR_TRUSTED_RUNTIME_FOOTPRINT = "0"'
  '.jobs["client-sandbox"].steps[4].env.WAR_TRUSTED_RUNTIME_INVENTORY_PROBE = "0"'
  '.jobs["client-sandbox"].steps[4].if = "false"'
  '.jobs["client-sandbox"].steps[2].run = "true"'
  '.jobs["client-sandbox"].steps[-1].run = "echo complete=true"'
  '.jobs["client-sandbox"].steps[0].with.ref = "main"'
  '.jobs["ci-required-checks"].needs |= map(select(. != "client-smoke"))'
  ".jobs[\"ci-required-checks\"].steps[0].with[\"job-results\"] = \"\${{ needs.client-smoke.result }}\""
  '.jobs["ci-required-checks"]["continue-on-error"] = true'
  '.jobs["ci-required-checks"].steps[0]["continue-on-error"] = true'
)
for mutation in "${mutations[@]}"; do
  jq "$mutation" "$tmp/base.json" > "$tmp/mutated.json"
  if bash "$guard" "$tmp/mutated.json" > "$tmp/verdict" 2>&1; then
    echo "FAIL: workflow guard accepted $mutation" >&2; exit 1
  fi
done
echo 'TEST PASS -- client workflow rejects omissions, skips, error masking and false completion'
