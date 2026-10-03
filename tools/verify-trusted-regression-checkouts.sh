#!/usr/bin/env bash
# Confirm the identities supplied by GitHub, not merely the checkout labels.
set -euo pipefail
if [ "$#" -ne 3 ]; then
  echo '::error::usage: verify-trusted-regression-checkouts.sh <workflow-root> <trusted-root> <candidate-root>' >&2
  exit 1
fi
verify() {
  local path="$1" expected="$2" actual
  if [[ ! "$expected" =~ ^[0-9a-f]{40}$ ]] ||
    ! actual="$(git --no-replace-objects -C "$path" rev-parse --verify HEAD)" || [ "$actual" != "$expected" ]; then
    echo "::error::checkout identity mismatch for $path; rerun the canonical base-owned gate" >&2
    exit 1
  fi
}
verify "$1" "${GITHUB_WORKFLOW_SHA:-}"
verify "$2" "${TRUSTED_SHA:-}"
verify "$3" "${CANDIDATE_SHA:-}"
printf 'Verified workflow=%s source=%s trusted-base=%s candidate-integration=%s\n' \
  "${GITHUB_WORKFLOW_REF:-}" "$GITHUB_WORKFLOW_SHA" "$TRUSTED_SHA" "$CANDIDATE_SHA"
