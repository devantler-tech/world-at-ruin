#!/usr/bin/env bash
# Exercise the GitHub event boundary before any candidate bytes can run.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
base="$(printf 'trusted base' | git hash-object --stdin)"
head="$(printf 'candidate head' | git hash-object --stdin)"
workflow='devantler-tech/world-at-ruin/.github/workflows/trusted-regressions.yaml@refs/heads/main'
jq -n --arg base "$base" --arg head "$head" '{repository:{full_name:"devantler-tech/world-at-ruin",default_branch:"main"},pull_request:{base:{ref:"main",sha:$base,repo:{full_name:"devantler-tech/world-at-ruin"}},head:{sha:$head},merge_commit_sha:null}}' >"$tmp/good.json"
run() {
  GITHUB_EVENT_NAME="${1:-pull_request_target}" GITHUB_REPOSITORY=devantler-tech/world-at-ruin \
    GITHUB_WORKFLOW_REF="${2:-$workflow}" GITHUB_EVENT_PATH="$tmp/event.json" GITHUB_OUTPUT="$tmp/outputs" \
    bash "$root/tools/resolve-trusted-regression-event.sh" >"$tmp/log" 2>&1
}
cp "$tmp/good.json" "$tmp/event.json"
run
grep -Fxq "trusted-sha=$base" "$tmp/outputs"
grep -Fxq "candidate-sha=$head" "$tmp/outputs"
for expression in \
  '.repository.full_name="other/world-at-ruin"' \
  '.repository.default_branch="develop"' \
  '.pull_request.base.ref="develop"' \
  '.pull_request.base.repo.full_name="other/world-at-ruin"' \
  'del(.pull_request)' 'del(.pull_request.base.sha)' \
  '.pull_request.base.sha=""' '.pull_request.base.sha=42' \
  '.pull_request.base.sha="../main"' '.pull_request.base.sha="refs/heads/main"' \
  '.pull_request.head.sha=null' '.pull_request.head.sha="short"' \
  'del(.repository)' '.pull_request=[]'; do
  jq "$expression" "$tmp/good.json" >"$tmp/event.json"
  : >"$tmp/outputs"
  if run; then
    echo "TEST FAIL -- accepted $expression" >&2
    exit 1
  fi
  test ! -s "$tmp/outputs"
done
cp "$tmp/good.json" "$tmp/event.json"
for event in pull_request merge_group workflow_dispatch; do
  : >"$tmp/outputs"
  if run "$event"; then
    echo "TEST FAIL -- accepted event $event" >&2
    exit 1
  fi
  test ! -s "$tmp/outputs"
done
for ref in \
  'devantler-tech/world-at-ruin/.github/workflows/renamed.yaml@refs/heads/main' \
  'devantler-tech/world-at-ruin/.github/workflows/trusted-regressions.yaml@refs/heads/candidate' \
  'other/world-at-ruin/.github/workflows/trusted-regressions.yaml@refs/heads/main'; do
  : >"$tmp/outputs"
  if run pull_request_target "$ref"; then
    echo "TEST FAIL -- accepted workflow tuple $ref" >&2
    exit 1
  fi
  test ! -s "$tmp/outputs"
done
printf '{broken' >"$tmp/event.json"
: >"$tmp/outputs"
if run; then
  echo 'TEST FAIL -- malformed event accepted' >&2
  exit 1
fi
test ! -s "$tmp/outputs"
echo 'TEST PASS -- trusted regression event resolves only canonical base-owned workflow inputs'
