#!/usr/bin/env bash
set -euo pipefail

workflow=${1:-.github/workflows/cla.yaml}
workflow_text=$(cat "$workflow")

if grep -Eq '^concurrency:[[:space:]]*$' <<<"$workflow_text"; then
  echo "CLA workflow must not let non-actionable events enter a shared pending queue" >&2
  exit 1
fi

job_body() {
  local job=$1
  awk -v job="$job" '
    $0 == "  " job ":" { in_job = 1; next }
    in_job && /^  [[:alnum:]_-]+:[[:space:]]*$/ { exit }
    in_job { print }
  ' <<<"$workflow_text"
}

job_concurrency() {
  awk '
    /^    concurrency:[[:space:]]*$/ {
      found = 1
      in_block = 1
      next
    }
    in_block && /^    [^[:space:]#]/ { exit }
    in_block { print }
    END { if (!found) exit 2 }
  '
}

check_job=$(job_body cla-check)
sign_job=$(job_body cla-sign)
check_block=$(job_concurrency <<<"$check_job") || {
  echo "CLA gate must declare job-level concurrency after its event filter" >&2
  exit 1
}
sign_block=$(job_concurrency <<<"$sign_job") || {
  echo "CLA signer must declare job-level concurrency after its comment filter" >&2
  exit 1
}

if ! grep -Fq 'github.event.comment.user.id == github.event.issue.user.id' <<<"$sign_job"; then
  echo "CLA signer must filter non-author signatures before they enter concurrency" >&2
  exit 1
fi

# A pull_request check can fail while a signature write is active. Refreshing the head after the
# write path makes the signer rerun that latest check instead of the stale head seen at job start.
# shellcheck disable=SC2016
expected_head_refresh='head_sha=$(gh api "repos/$REPO/pulls/$PR_NUMBER" --jq .head.sha)'
# shellcheck disable=SC2016
write_line=$(grep -nF 'gh api -X PUT "repos/$REPO/contents/$LEDGER_PATH"' <<<"$sign_job" | cut -d: -f1 || true)
refresh_line=$(grep -nF "$expected_head_refresh" <<<"$sign_job" | cut -d: -f1 || true)
if [[ -z "$write_line" || -z "$refresh_line" || "$refresh_line" -le "$write_line" ]]; then
  echo "CLA signer must refresh the current PR head after the ledger-write path" >&2
  exit 1
fi
# Literal shell source; the workflow runner expands these variables, not this test.
# shellcheck disable=SC2016
if ! grep -Fq 'for attempt in {1..30}; do' <<<"$sign_job" ||
  ! grep -Fq 'run_status=$(gh api "repos/$REPO/actions/runs/$run_id" --jq .status)' <<<"$sign_job"; then
  echo "CLA signer must wait boundedly for the current-head gate to become rerunnable" >&2
  exit 1
fi
if grep -Fq '|| true' <<<"$sign_job"; then
  echo "CLA signer must fail loudly when the current-head gate cannot be rerun" >&2
  exit 1
fi

# Literal GitHub expressions; the runner expands them, this test must not.
# shellcheck disable=SC2016
expected_check_group='      group: cla-check-${{ github.event.pull_request.number }}'
# shellcheck disable=SC2016
expected_sign_group="      group: cla-sign-\${{ github.event.issue.number }}-\${{ github.event.comment.body == 'recheck' }}"
if ! grep -Fqx "$expected_check_group" <<<"$check_block"; then
  echo "CLA gate must collapse only redundant pull_request checks" >&2
  exit 1
fi
if ! grep -Fqx "$expected_sign_group" <<<"$sign_block"; then
  echo "CLA signer must keep signature and recheck queues independent" >&2
  exit 1
fi

for block in "$check_block" "$sign_block"; do
  if ! grep -Fqx '      cancel-in-progress: false' <<<"$block"; then
    echo "CLA jobs must not cancel active checks or ledger writes" >&2
    exit 1
  fi
  if grep -Eq '^[[:space:]]+queue:' <<<"$block"; then
    echo "CLA jobs must keep the default single-pending queue" >&2
    exit 1
  fi
done

echo "CLA concurrency guard passed"
