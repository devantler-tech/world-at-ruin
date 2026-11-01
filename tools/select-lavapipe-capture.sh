#!/usr/bin/env bash
# Select advisory volumetric evidence only for an exact PR integration checkout.
# Unavailable path evidence conservatively captures; unknown source identity refuses.
set -euo pipefail
case ${1:-} in select | verify) mode=$1 ;; *)
  echo 'expected select or verify' >&2
  exit 1
  ;;
esac
[[ $# == 1 && ${GITHUB_EVENT_NAME:-} == pull_request ]] || exit 1
for revision in "${GITHUB_SHA:-}" "${HEAD_SHA:-}" "${BASE_SHA:-}"; do
  [[ $revision =~ ^[0-9a-f]{40}$ ]] || {
    echo 'missing immutable PR source identity' >&2
    exit 1
  }
done
[[ $(git rev-parse HEAD) == "$GITHUB_SHA" ]] || {
  echo 'checkout differs from event integration' >&2
  exit 1
}
parents=$(git rev-list --parents -n 1 HEAD)
read -r commit first second extra <<<"$parents"
[[ $commit == "$GITHUB_SHA" && -n $first && $second == "$HEAD_SHA" && -z $extra ]] || {
  echo 'integration does not contain the exact event PR head' >&2
  exit 1
}
printf 'Lavapipe source verified: integration=%s pr_head=%s\n' "$GITHUB_SHA" "$HEAD_SHA" >&2
[[ $mode != verify ]] || exit 0

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
capture() {
  echo true
  exit 0
}
# The frozen base only over-selects. Use it to detect changes to the selector's
# own machinery without first executing a candidate-modified base resolver.
if ! git diff --name-only "$BASE_SHA" HEAD >"$scratch/machinery"; then
  capture
fi
machinery='^tools/(pr-diff-base\.sh|select-lavapipe-capture(\.test)?\.sh|lavapipe-capture-guard(\.test)?\.sh|collect-lavapipe-captures\.sh|lavapipe-partitions\.test\.sh|install-ci-godot\.sh|install-ci-lavapipe(\.test)?\.sh)$|^\.github/workflows/lavapipe-capture\.yaml$|^client/tools/frame_capture\.(gd|tscn)$'
status=0
grep -qE "$machinery" "$scratch/machinery" || status=$?
case $status in 0) capture ;; 1) ;; *) capture ;; esac
if ! diff_base=$(bash tools/pr-diff-base.sh "$HEAD_SHA" "$BASE_SHA"); then
  capture
fi
if ! git diff --name-only "$diff_base" HEAD >"$scratch/changed"; then
  capture
fi
status=0
grep -qE '^client/scripts/(volumetrics|hollow_fog|main)\.gd$|^\.github/workflows/ci\.yaml$' "$scratch/changed" || status=$?
case $status in 1) echo false ;; *) capture ;; esac
