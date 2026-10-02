#!/usr/bin/env bash
# Resolve only GitHub's canonical base-controlled workflow event. Candidate
# branch names, paths and workflow content never choose execution inputs.
set -euo pipefail
expected='devantler-tech/world-at-ruin/.github/workflows/trusted-regressions.yaml@refs/heads/main'
if [ "${GITHUB_EVENT_NAME:-}" != pull_request_target ] ||
  [ "${GITHUB_REPOSITORY:-}" != devantler-tech/world-at-ruin ] ||
  [ "${GITHUB_WORKFLOW_REF:-}" != "$expected" ]; then
  echo '::error::trusted regressions require the canonical main pull_request_target workflow' >&2
  exit 1
fi
if [ ! -f "${GITHUB_EVENT_PATH:-}" ] || [ -z "${GITHUB_OUTPUT:-}" ]; then
  echo '::error::GitHub event or output path is missing' >&2
  exit 1
fi
resolved="$(jq -er '
  def sha: type == "string" and test("^[0-9a-f]{40}$");
  select(.repository.full_name == "devantler-tech/world-at-ruin"
    and .repository.default_branch == "main"
    and .pull_request.base.repo.full_name == "devantler-tech/world-at-ruin"
    and .pull_request.base.ref == "main"
    and (.pull_request.base.sha | sha)
    and (.pull_request.head.sha | sha)
    )
  | "trusted-sha=\(.pull_request.base.sha)\ncandidate-sha=\(.pull_request.head.sha)"
' "$GITHUB_EVENT_PATH")" || {
  echo '::error::event lacks the canonical repository/base or exact base and candidate commit identities' >&2
  exit 1
}
printf '%s\n' "$resolved" >>"$GITHUB_OUTPUT"
