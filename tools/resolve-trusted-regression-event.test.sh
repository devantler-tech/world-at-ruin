#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
base="$(printf 'trusted base' | git hash-object --stdin)"
head="$(printf 'candidate head' | git hash-object --stdin)"
merge="$(printf 'integration candidate' | git hash-object --stdin)"
workflow='devantler-tech/world-at-ruin/.github/workflows/trusted-regressions.yaml@refs/heads/main'
jq -n --arg base "$base" --arg head "$head" --arg merge "$merge" '{repository:{full_name:"devantler-tech/world-at-ruin",default_branch:"main"},pull_request:{base:{ref:"main",sha:$base,repo:{full_name:"devantler-tech/world-at-ruin"}},head:{sha:$head},merge_commit_sha:$merge}}' >"$tmp/pr.json"
jq -n --arg base "$base" --arg merge "$merge" '{repository:{full_name:"devantler-tech/world-at-ruin",default_branch:"main"},merge_group:{base_ref:"refs/heads/main",base_sha:$base,head_sha:$merge}}' >"$tmp/group.json"
# Resolve one fixture event with explicit canonical GitHub metadata.
run() {
  GITHUB_EVENT_NAME="${1:-pull_request}" GITHUB_REPOSITORY=devantler-tech/world-at-ruin \
    GITHUB_WORKFLOW_REF="${2:-$workflow}" GITHUB_SHA="${3:-$merge}" \
    GITHUB_EVENT_PATH="$tmp/event.json" GITHUB_OUTPUT="$tmp/outputs" \
    bash "$root/tools/resolve-trusted-regression-event.sh" >"$tmp/log" 2>&1
}
# Require rejection of a changed event identity instead of partial outputs.
refuse() {
  : >"$tmp/outputs"
  if run "$@"; then echo 'TEST FAIL -- invalid event identity accepted' >&2; exit 1; fi
  test ! -s "$tmp/outputs"
}
for event in pull_request merge_group; do
  fixture="pr"
  if [ "$event" = merge_group ]; then fixture=group; fi
  cp "$tmp/$fixture.json" "$tmp/event.json"
  : >"$tmp/outputs"
  run "$event" || { cat "$tmp/log"; exit 1; }
  grep -Fxq "trusted-sha=$base" "$tmp/outputs"
  grep -Fxq "candidate-sha=$merge" "$tmp/outputs"
  refuse "$event" "$workflow" "$head"
  refuse "$event" "$workflow" short
  for expression in '.repository.full_name="other/world-at-ruin"' '.repository.default_branch="develop"' 'del(.repository)'; do
    jq "$expression" "$tmp/$fixture.json" >"$tmp/event.json"
    refuse "$event"
  done
done
for expression in \
  '.pull_request.base.ref="develop"' '.pull_request.base.repo.full_name="other/world-at-ruin"' \
  'del(.pull_request)' 'del(.pull_request.base.sha)' '.pull_request.base.sha=""' \
  '.pull_request.base.sha=42' '.pull_request.base.sha="../main"' \
  '.pull_request.head.sha=null' '.pull_request.head.sha="short"' \
  '.pull_request.merge_commit_sha=null' '.pull_request.merge_commit_sha="short"' '.pull_request=[]'; do
  jq "$expression" "$tmp/pr.json" >"$tmp/event.json"
  refuse
done
for expression in \
  '.merge_group.base_ref="refs/heads/develop"' 'del(.merge_group)' \
  '.merge_group.base_sha=null' '.merge_group.base_sha="short"' \
  '.merge_group.head_sha=null' '.merge_group.head_sha=42' '.merge_group=[]'; do
  jq "$expression" "$tmp/group.json" >"$tmp/event.json"
  refuse merge_group
done
cp "$tmp/pr.json" "$tmp/event.json"
for event in pull_request_target push workflow_dispatch; do refuse "$event"; done
for ref in \
  'devantler-tech/world-at-ruin/.github/workflows/renamed.yaml@refs/heads/main' \
  'devantler-tech/world-at-ruin/.github/workflows/trusted-regressions.yaml@refs/pull/979/merge' \
  'other/world-at-ruin/.github/workflows/trusted-regressions.yaml@refs/heads/main'; do
  refuse pull_request "$ref"
done
printf '{broken' >"$tmp/event.json"
refuse
echo 'TEST PASS -- required-main PR and merge-group identities bind the integration candidate'
