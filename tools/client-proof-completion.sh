#!/usr/bin/env bash
# The last worker step publishes evidence only after checked-out identity and
# cleanup succeed; job failure/cancellation still invalidates these outputs.
set -euo pipefail
case "${1:-}" in ordinary|sandbox) kind=$1 ;; *) exit 2 ;; esac
state="${RUNNER_TEMP:?}/war-client-$kind"
if [[ ${XDG_DATA_HOME:-} != "$state" ]]; then
  echo '::error::client proof state does not match this worker' >&2; exit 1
fi
tested_sha="$(git rev-parse HEAD)"
if [[ ! $tested_sha =~ ^[0-9a-f]{40}$ || $tested_sha != "${GITHUB_SHA:-}" ]]; then
  echo '::error::client proof did not test the event integration commit' >&2; exit 1
fi
rm -rf -- "$state"
test ! -e "$state"
printf 'complete=true\ntested-sha=%s\n' "$tested_sha" >> "${GITHUB_OUTPUT:?}"
