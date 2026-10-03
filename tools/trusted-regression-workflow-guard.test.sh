#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
workflow="$root/.github/workflows/trusted-regressions.yaml"
bash "$root/tools/trusted-regression-workflow-guard.sh"
for mutation in \
  '.on={"pull_request":{}}' \
  '.on={"pull_request_target":{}}' \
  '.permissions={"contents":"write"}' \
  '.jobs."trusted-client-regressions".permissions={"contents":"write"}' \
  '.jobs."trusted-client-regressions".steps[1].with.ref="candidate"' \
  '.jobs."trusted-client-regressions".steps[3].with.path="candidate"' \
  '.jobs."trusted-client-regressions".steps[4].with."persist-credentials"=true' \
  '.jobs."trusted-client-regressions".steps[7].run="candidate/tools/required-regression-control.sh trusted candidate"' \
  '.jobs."trusted-client-regressions".steps[7]."continue-on-error"=true' \
  '.jobs."trusted-client-regressions".steps[7].if="false"' \
  '.jobs."trusted-client-regressions".steps[7].env={"SECRET":"unsafe"}' \
  '.jobs."trusted-client-regressions".name="Trusted client regressions"' \
  '.jobs."trusted-client-regressions".if="false"' \
  '.jobs."trusted-client-regressions"."continue-on-error"=true' \
  '.jobs."trusted-client-regressions".steps[7]."working-directory"="candidate"' \
  '.jobs."trusted-client-regressions".steps[7].shell="true {0}"' \
  '.jobs."trusted-client-regressions".steps[6].run="# sha512sum -c -\ntrue"' \
  '.env.GODOT_SHA512="unverified"' \
  '.env.SECRET="unsafe"' \
  '.jobs."trusted-client-regressions".env={"SECRET":"unsafe"}'; do
  yq "$mutation" "$workflow" >"$tmp/workflow.yaml"
  if bash "$root/tools/trusted-regression-workflow-guard.sh" "$tmp/workflow.yaml" >"$tmp/log" 2>&1; then
    echo "TEST FAIL -- workflow accepted $mutation" >&2
    exit 1
  fi
done
if bash "$root/tools/trusted-regression-workflow-guard.sh" "$tmp/missing.yaml" >"$tmp/log" 2>&1; then
  echo 'TEST FAIL -- missing workflow passed' >&2
  exit 1
fi
echo 'TEST PASS -- only the base-owned product gate has the trusted controller contract'
