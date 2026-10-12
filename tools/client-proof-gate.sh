#!/usr/bin/env bash
# The stable check accepts only two fully cleaned proofs of one integration.
set -euo pipefail
if [[ ! ${EXPECTED_SHA:-} =~ ^[0-9a-f]{40}$ ]]; then
  echo '::error::client proofs have no valid expected integration SHA' >&2
  exit 1
fi
for participant in ORDINARY SANDBOX; do
  result="${participant}_RESULT"
  complete="${participant}_COMPLETE"
  observed="${participant}_SHA"
  if [[ ${!result:-} != success || ${!complete:-} != true || ${!observed:-} != "$EXPECTED_SHA" ]]; then
    echo "::error::$participant client proof lacks success, cleanup or matching integration" >&2
    exit 1
  fi
done
echo "CLIENT PROOFS PASS: both complete at $EXPECTED_SHA"
