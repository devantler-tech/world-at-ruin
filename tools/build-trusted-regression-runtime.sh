#!/usr/bin/env bash
# Build only reviewed runtime bytes and the checksum-verified engine.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=tools/trusted-regression-lifecycle.sh
source "$root/tools/trusted-regression-lifecycle.sh"
context="$(mktemp -d)"
cleanup() {
  local status=$trusted_cleanup_status
  trap - EXIT
  trap ':' INT TERM
  trusted_stop_child || status=2
  if [ "$trusted_cleanup_uncertain" -eq 0 ] && [ "$status" -ne 2 ]; then rm -rf "$context"; fi
  exit "$status"
}
trap 'trusted_cleanup_status=$? trusted_cleanup_started=true; cleanup' EXIT
trap 'trap ":" INT TERM; trusted_request_cancel' INT TERM
cp "$(command -v godot)" "$context/godot"
trusted_wait bash "$root/tools/trusted-regression-phase.sh" "runtime build/pull" docker build --pull --file "$root/.github/containers/trusted-regressions.Dockerfile" \
  --tag "world-trusted-regressions:build-$$" "$context" >&2
trusted_wait bash "$root/tools/trusted-regression-phase.sh" "runtime image inspection" docker image inspect "world-trusted-regressions:build-$$" --format '{{.Id}}' >"$context/identity"
digest="$(cat "$context/identity")"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo '::error::trusted runtime image identity is missing' >&2
  exit 1
}
printf '%s\n' "$digest"
