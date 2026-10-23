#!/usr/bin/env bash
# GitHub's required workflow selects this controller from main. The candidate
# is the integration commit, never a branch name or candidate-owned selector.
# --json returns the same verified identities to a product-owned caller;
# the default writes the established GitHub step-output interface.
set -euo pipefail
format=outputs
if [[ $# == 1 && $1 == --json ]]; then
  format=json
elif [[ $# != 0 ]]; then
  echo '::error::usage: resolve-trusted-regression-event.sh [--json]' >&2
  exit 1
fi
case ${GITHUB_WORKFLOW_REF:-} in
devantler-tech/world-at-ruin/.github/workflows/trusted-regressions.yaml@refs/heads/main | \
  devantler-tech/.github/.github/workflows/repository-pr-admission.yaml@refs/heads/main) ;;
*)
  echo '::error::trusted regressions require a canonical required-main source' >&2
  exit 1
  ;;
esac
if [ "${GITHUB_REPOSITORY:-}" != devantler-tech/world-at-ruin ] ||
  [[ ! "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]]; then
  echo '::error::trusted regressions require the canonical required-main workflow and exact integration identity' >&2
  exit 1
fi
case "${GITHUB_EVENT_NAME:-}" in
pull_request | merge_group) ;;
*)
  echo '::error::trusted regressions require a pull request or merge group' >&2
  exit 1
  ;;
esac
if [ ! -f "${GITHUB_EVENT_PATH:-}" ] || [ -L "$GITHUB_EVENT_PATH" ] ||
  { [ "$format" == outputs ] && [ -z "${GITHUB_OUTPUT:-}" ]; }; then
  echo '::error::GitHub event or output path is missing' >&2
  exit 1
fi
resolved="$(jq -sce --arg event "$GITHUB_EVENT_NAME" --arg candidate "$GITHUB_SHA" '
  def sha: type == "string" and test("^[0-9a-f]{40}$");
  select(length==1) | .[0] |
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
  | {trusted_sha:.base,candidate_sha:$candidate}
' "$GITHUB_EVENT_PATH")" || {
  echo '::error::event lacks canonical repository/base or matching integration identities' >&2
  exit 1
}
if [[ $format == json ]]; then
  printf '%s\n' "$resolved"
else
  jq -r '"trusted-sha=\(.trusted_sha)\ncandidate-sha=\(.candidate_sha)"' <<<"$resolved" >>"$GITHUB_OUTPUT"
fi
