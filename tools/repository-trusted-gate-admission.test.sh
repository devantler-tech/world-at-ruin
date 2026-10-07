#!/usr/bin/env bash
# The disabled path cannot admit publication; enabled runs require reviewed main.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
helper="$root/tools/repository-trusted-gate-admission.sh"
workflow='devantler-tech/world-at-ruin/.github/workflows/repository-trusted-regressions.yaml@refs/heads/main'
sha=0123456789abcdef0123456789abcdef01234567
fail() { echo "TEST FAIL -- repository trusted gate admission: $*" >&2; exit 1; }
jq -n '{action:"completed",repository:{full_name:"devantler-tech/world-at-ruin",default_branch:"main"},workflow_run:{id:123,name:"CI",path:".github/workflows/ci.yaml",status:"completed",event:"pull_request",repository:{full_name:"devantler-tech/world-at-ruin"}}}' >"$work/good.json"
run() {
  : >"$work/output"
  env WAR_REPOSITORY_TRUSTED_GATE_ENABLED="${flag:-true}" WAR_TRUSTED_GATE_APP_ID="${app:-123}" \
    WAR_TRUSTED_GATE_PUBLISHER_ENVIRONMENT="${publisher:-world-trusted-gate-publisher}" \
    GITHUB_REPOSITORY="${repository:-devantler-tech/world-at-ruin}" \
    GITHUB_EVENT_NAME="${event:-workflow_run}" GITHUB_REF="${ref:-refs/heads/main}" \
    GITHUB_WORKFLOW_REF="${source:-$workflow}" GITHUB_WORKFLOW_SHA="${source_sha:-$sha}" \
    GITHUB_EVENT_PATH="$work/event.json" GITHUB_OUTPUT="$work/output" \
    bash "$helper" >"$work/log" 2>&1
}
refuse() {
  if run; then fail 'unsafe admission succeeded'; fi
  test ! -s "$work/output" || fail 'rejected admission emitted partial outputs'
}
cp "$work/good.json" "$work/event.json"
run || { cat "$work/log"; fail 'enabled reviewed-main fixture was rejected'; }
grep -Fxq admitted=true "$work/output" || fail 'enabled fixture was not admitted'
for value in false empty; do
  if [[ "$value" == empty ]]; then
    : >"$work/output"
    WAR_REPOSITORY_TRUSTED_GATE_ENABLED='' GITHUB_OUTPUT="$work/output" bash "$helper" >"$work/log" 2>&1 || fail 'omitted flag did not remain disabled'
  else
    flag=false run || fail 'false flag did not remain disabled'
  fi
  grep -Fxq admitted=false "$work/output" || fail 'disabled path did not emit inert verdict'
  if grep -q admitted=true "$work/output"; then fail 'disabled path admitted publication'; fi
done
for value in TRUE 1 enabled 'true '; do flag="$value" refuse; done
for value in 0 -1 001 not-an-app 1e3 15368; do app="$value" refuse; done
for value in renamed-environment ''; do
  if [[ -n "$value" ]]; then publisher="$value" refuse; else
    : >"$work/output"
    if WAR_REPOSITORY_TRUSTED_GATE_ENABLED=true WAR_TRUSTED_GATE_APP_ID=123 \
      GITHUB_OUTPUT="$work/output" bash "$helper" >"$work/log" 2>&1; then fail 'missing environment was admitted'; fi
    test ! -s "$work/output" || fail 'missing environment emitted partial outputs'
  fi
done
repository=other/world-at-ruin refuse
event=pull_request refuse
ref=refs/heads/feature refuse
source='devantler-tech/world-at-ruin/.github/workflows/repository-trusted-regressions.yaml@refs/heads/feature' refuse
source='devantler-tech/world-at-ruin/.github/workflows/renamed.yaml@refs/heads/main' refuse
source_sha=short refuse
for mutation in \
  '.action="requested"' \
  '.repository.full_name="other/world-at-ruin"' \
  '.repository.default_branch="develop"' \
  '.workflow_run.name="Fake CI"' \
  '.workflow_run.path=".github/workflows/other.yaml"' \
  '.workflow_run.status="in_progress"' \
  '.workflow_run.event="push"' \
  '.workflow_run.id=0' \
  '.workflow_run.id="123"' \
  '.workflow_run.repository.full_name="other/world-at-ruin"' \
  'del(.workflow_run)'; do
  jq "$mutation" "$work/good.json" >"$work/event.json"
  refuse
done
jq '.workflow_run.event="merge_group"' "$work/good.json" >"$work/event.json"
run || { cat "$work/log"; fail 'merge-group CI completion was rejected'; }
grep -Fxq admitted=true "$work/output" || fail 'merge-group completion was not admitted'
printf '{malformed' >"$work/event.json"
refuse
echo 'TEST PASS -- default-off admission binds reviewed main, canonical CI and publisher configuration'
