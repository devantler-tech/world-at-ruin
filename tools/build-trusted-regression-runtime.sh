#!/usr/bin/env bash
# Build only reviewed runtime bytes and the checksum-verified engine.
set -euo pipefail
mode="${WAR_TRUSTED_RUNTIME_INVENTORY:-0}"
case "$mode" in 0|1) ;; *) echo '::error::runtime inventory selection refused' >&2; exit 2;; esac
proposal="${WAR_TRUSTED_RUNTIME_ARCHIVE_PROPOSAL:-0}"
case "$proposal" in 0) policy=locked;; 1) policy=proposal;; *) echo '::error::runtime archive proposal selection refused' >&2; exit 2;; esac
if [ "$policy" = proposal ] && [ "$mode" != 1 ]; then
  echo '::error::runtime archive proposal requires complete inventory publication' >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=tools/trusted-regression-lifecycle.sh
source "$root/tools/trusted-regression-lifecycle.sh"
context="$(mktemp -d)"
mkdir "$context/containers"
cleanup() {
  if [ "$mode" = 1 ]; then
    trusted_cleanup_controller "$context" "$root/tools/trusted-regression-phase.sh" "$context/containers"
  fi
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
cp "$root/tools/capture-trusted-runtime-inventory.sh" "$context/capture-trusted-runtime-inventory.sh"
cp "$root/tools/observe-runtime-transaction.sh" "$context/observe-runtime-transaction.sh"
cp "$root/tools/trusted-runtime-origin/main.go" "$context/trusted-runtime-origin.go"
cp "$root/tools/trusted-runtime-archives/main.go" "$context/trusted-runtime-archives.go"
if [ "$policy" = proposal ]; then
  echo 'TRUSTED_RUNTIME_ARCHIVE_PROPOSAL evidence-only=true' >&2
fi
trusted_wait bash "$root/tools/trusted-regression-phase.sh" "runtime build/pull" \
  bash "$root/tools/build-locked-trusted-runtime.sh" "$root" "$context" "$mode" "world-trusted-regressions:build-$$" "$policy" >&2
if [ "$mode" = 1 ]; then
  trusted_wait bash "$root/tools/trusted-regression-phase.sh" "runtime image inspection" bash "$root/tools/inspect-trusted-runtime.sh" "world-trusted-regressions:build-$$" "$context" > "$context/identity"
  printf 'TRUSTED_RUNTIME_INVENTORY ' >&2
  cat "$context/report.json" >&2
else
  trusted_wait bash "$root/tools/trusted-regression-phase.sh" "runtime image inspection" docker image inspect "world-trusted-regressions:build-$$" --format '{{.Id}}' >"$context/identity"
fi
digest="$(cat "$context/identity")"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo '::error::trusted runtime image identity is missing' >&2
  exit 1
}
printf '%s\n' "$digest"
