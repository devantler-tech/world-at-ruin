#!/usr/bin/env bash
# Reviewed product entrypoint for the shared required-workflow runner.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
fail() {
  echo "::error::World admission: $*" >&2
  exit 2
}
[[ $# == 1 && ($1 == check || $1 == run) ]] || fail 'expected check or run'
[[ ${GITHUB_REPOSITORY:-} == devantler-tech/world-at-ruin &&
  ${GITHUB_WORKFLOW_REF:-} == devantler-tech/.github/.github/workflows/repository-pr-admission.yaml@refs/heads/main &&
  ${GITHUB_WORKFLOW_SHA:-} =~ ^[0-9a-f]{40}$ &&
  ${GITHUB_SHA:-} =~ ^[0-9a-f]{40}$ && ${CANDIDATE_SHA:-} == "$GITHUB_SHA" ]] ||
  fail 'requires canonical shared source and matching integration identity'
context=$(bash "$root/tools/resolve-trusted-regression-event.sh" --json) || fail 'event has no matching immutable product identities'
base=$(jq -ser --arg candidate "$CANDIDATE_SHA" '
  select(length==1) | .[0] |
  select(keys==["candidate_sha","trusted_sha"] and .candidate_sha==$candidate) | .trusted_sha
' <<<"$context") || fail 'event resolution is incomplete'
actual=$(git --no-replace-objects -C "$root" rev-parse --verify HEAD) || fail 'reviewed checkout unavailable'
[[ $actual == "$base" ]] || fail 'action checkout is not the GitHub-supplied product base'
git --no-replace-objects -C "$root" diff --quiet HEAD -- || fail 'reviewed product files changed'
printf 'Verified reviewed product base %s and candidate integration %s\n' "$base" "$CANDIDATE_SHA"
[[ $1 == run ]] || exit 0
[[ ${RUNNER_TEMP:-} == /* && -d $RUNNER_TEMP && ! -L $RUNNER_TEMP ]] || fail 'private runner directory unavailable'
# The complete existing contained controller retains runtime and verdict authority.
# shellcheck source=tools/trusted-regression-lifecycle.sh
source "$root/tools/trusted-regression-lifecycle.sh"
scratch=$(mktemp -d "$RUNNER_TEMP/world-admission.XXXXXX")
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  local status=$trusted_cleanup_status
  trap - EXIT
  trap ':' INT TERM
  trusted_stop_child || status=2
  if [[ $trusted_cleanup_uncertain == 0 && $status != 2 ]]; then rm -rf "$scratch"; fi
  exit "$status"
}
trap 'trusted_cleanup_status=$?; trusted_cleanup_started=true; cleanup' EXIT
trap 'trap ":" INT TERM; trusted_request_cancel' INT TERM
cd "$scratch"
trusted_wait bash "$root/tools/fetch-trusted-regression-data.sh" candidate "$CANDIDATE_SHA"
trusted_wait bash "$root/tools/run-sandboxed-trusted-regressions.sh" "$root" "$scratch/candidate"
