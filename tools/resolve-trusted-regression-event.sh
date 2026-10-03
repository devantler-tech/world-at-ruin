#!/usr/bin/env bash
# GitHub's required workflow selects this controller from main. The candidate
# is the integration commit, never a branch name or candidate-owned selector.
set -euo pipefail
expected='devantler-tech/world-at-ruin/.github/workflows/trusted-regressions.yaml@refs/heads/main'
if [ "${GITHUB_REPOSITORY:-}" != devantler-tech/world-at-ruin ] ||
  [ "${GITHUB_WORKFLOW_REF:-}" != "$expected" ] ||
  [[ ! "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]]; then
  echo '::error::trusted regressions require the canonical required-main workflow and exact integration identity' >&2
  exit 1
fi
case "${GITHUB_EVENT_NAME:-}" in
  pull_request|merge_group) ;;
  *) echo '::error::trusted regressions require a pull request or merge group' >&2; exit 1 ;;
esac
if [ ! -f "${GITHUB_EVENT_PATH:-}" ] || [ -z "${GITHUB_OUTPUT:-}" ]; then
  echo '::error::GitHub event or output path is missing' >&2
  exit 1
fi
resolved="$(jq -er --arg event "$GITHUB_EVENT_NAME" --arg candidate "$GITHUB_SHA" '
  def sha: type == "string" and test("^[0-9a-f]{40}$");
  select(.repository.full_name == "devantler-tech/world-at-ruin"
    and .repository.default_branch == "main")
  | if $event == "pull_request" then
      select(.pull_request.base.repo.full_name == "devantler-tech/world-at-ruin"
        and .pull_request.base.ref == "main"
        and (.pull_request.base.sha | sha)
        and (.pull_request.head.sha | sha)
        and (.pull_request.merge_commit_sha | sha)
        and .pull_request.merge_commit_sha == $candidate)
      | {base: .pull_request.base.sha}
    else
      select(.merge_group.base_ref == "refs/heads/main"
        and (.merge_group.base_sha | sha)
        and (.merge_group.head_sha | sha)
        and .merge_group.head_sha == $candidate)
      | {base: .merge_group.base_sha}
    end
  | "trusted-sha=\(.base)\ncandidate-sha=\($candidate)"
' "$GITHUB_EVENT_PATH")" || {
  echo '::error::event lacks canonical repository/base or matching integration identities' >&2
  exit 1
}
printf '%s\n' "$resolved" >>"$GITHUB_OUTPUT"
