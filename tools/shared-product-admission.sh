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
context=$(bash "$root/tools/resolve-trusted-regression-event.sh" --shared-event-json) || fail 'event has no matching immutable product identities'
base=$(jq -ser --arg candidate "$CANDIDATE_SHA" '
  select(length==1) | .[0] |
  select(keys==["candidate_sha","event_head_sha","trusted_sha"] and .candidate_sha==$candidate) | .trusted_sha
' <<<"$context") || fail 'event resolution is incomplete'
event_head=$(jq -er '.event_head_sha | select(type=="string" and test("^[0-9a-f]{40}$"))' <<<"$context") ||
  fail 'event head identity is incomplete'
actual=$(git --no-replace-objects -C "$root" rev-parse --verify HEAD) || fail 'reviewed checkout unavailable'
[[ $actual == "$base" ]] || fail 'action checkout is not the GitHub-supplied product base'
git --no-replace-objects -C "$root" diff --quiet HEAD -- || fail 'reviewed product files changed'
printf 'Verified reviewed product base %s and GitHub candidate context %s\n' "$base" "$CANDIDATE_SHA"
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
candidate_root="$scratch/candidate"
candidate_actual=$(git --no-replace-objects -C "$candidate_root" rev-parse --verify HEAD) || fail 'candidate checkout unavailable'
[[ $candidate_actual == "$CANDIDATE_SHA" ]] || fail 'candidate checkout does not match the GitHub integration identity'
if [[ $GITHUB_EVENT_NAME == pull_request ]]; then
  # Native event payloads can retain a different merge_commit_sha snapshot. Read
  # the actual Git object, including parents hidden by a depth-one fetch. Drain
  # the message without interpreting it so a long message cannot cause SIGPIPE.
  parents=$(git --no-replace-objects -C "$candidate_root" cat-file commit "$CANDIDATE_SHA" |
    awk 'BEGIN { header=1 } /^$/ { header=0 } header && /^parent / { print $2 }') ||
    fail 'candidate integration object unavailable'
  first_parent=${parents%%$'\n'*}
  [[ $first_parent =~ ^[0-9a-f]{40}$ && $parents == "$first_parent"$'\n'"$event_head" ]] ||
    fail 'candidate must have exactly two ordered parents and the immutable event head'
  if [[ $first_parent != "$base" ]]; then
    # The event base can be frozen while GitHub rebuilds its integration against
    # newer main. Keep executing the event's reviewed implementation, but require
    # GitHub to prove that this exact first parent descends from that base. The
    # depth-one candidate deliberately cannot supply its own ancestry witness.
    [[ -n ${GH_TOKEN:-} ]] || fail 'read-only comparison credential unavailable'
    comparison_url="https://api.github.com/repos/devantler-tech/world-at-ruin/compare/$base...$first_parent"
    trusted_wait curl --disable --fail --silent --show-error --connect-timeout 5 --max-time 30 \
      --header "Authorization: Bearer $GH_TOKEN" \
      --header 'Accept: application/vnd.github+json' \
      --header 'X-GitHub-Api-Version: 2026-03-10' \
      "$comparison_url?per_page=1" >"$scratch/base-comparison.json"
    jq -se --arg url "$comparison_url" --arg base "$base" '
      length==1 and (.[0] |
        type=="object" and .url==$url and .status=="ahead" and
        .base_commit.sha==$base and .merge_base_commit.sha==$base and
        (.ahead_by|type)=="number" and .ahead_by>0 and .ahead_by==(.ahead_by|floor) and
        .behind_by==0 and .total_commits==.ahead_by)
    ' "$scratch/base-comparison.json" >/dev/null || fail 'canonical comparison did not prove the integration base ancestry'
  fi
fi
printf 'Verified fetched integration object %s against immutable event identities\n' "$CANDIDATE_SHA"
# Candidate processes never inherit the credential used for this read.
unset GH_TOKEN GITHUB_TOKEN
trusted_wait bash "$root/tools/run-sandboxed-trusted-regressions.sh" "$root" "$scratch/candidate"
