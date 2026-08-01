#!/usr/bin/env bash
set -euo pipefail

workflow=${1:-.github/workflows/cla.yaml}

concurrency_block=$(
  awk '
    /^concurrency:[[:space:]]*$/ {
      found = 1
      in_block = 1
      next
    }
    in_block && /^[^[:space:]#]/ { exit }
    in_block { print }
    END { if (!found) exit 2 }
  ' "$workflow"
) || {
  echo "CLA workflow must declare a top-level concurrency block" >&2
  exit 1
}

# Literal GitHub expression; the runner expands it, this test must not.
# shellcheck disable=SC2016
expected_group='  group: cla-${{ github.event.pull_request.number || github.event.issue.number }}'
if ! grep -Fqx "$expected_group" <<<"$concurrency_block"; then
  echo "CLA workflow must serialize runs per pull request" >&2
  exit 1
fi

if ! grep -Fqx '  cancel-in-progress: false' <<<"$concurrency_block"; then
  echo "CLA workflow must not cancel an active ledger write" >&2
  exit 1
fi

if grep -Eq '^[[:space:]]+queue:' <<<"$concurrency_block"; then
  echo "CLA workflow must keep the default single-pending queue" >&2
  exit 1
fi

echo "CLA concurrency guard passed"
