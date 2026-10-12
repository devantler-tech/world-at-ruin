#!/usr/bin/env bash
# Bound reviewed host phases; GNU timeout owns and terminates the child group.
set -euo pipefail
# shellcheck source=tools/process-group-lifecycle.sh
source "$(dirname "${BASH_SOURCE[0]}")/process-group-lifecycle.sh"
if [ "${1:-}" = --cleanup-containers ]; then
  directory="${2:?private container record directory required}"
  shopt -s nullglob
  failed=0
  for record in "$directory"/*; do
    name="$(basename "$record")"
    if [[ ! "$name" =~ ^war-trusted-[0-9a-f]{32}$ ]] || [ -L "$record" ] || [ ! -f "$record" ]; then
      echo '::error::invalid private sandbox cleanup record' >&2
      exit 2
    fi
    # A normal --rm container is already absent. Only our exact name is touched.
    timeout --kill-after=2s 5s docker rm --force "$name" >/dev/null 2>&1 || true
    remaining=""
    if ! remaining="$(timeout --kill-after=2s 5s docker ps --all --filter "name=^/$name$" --format '{{.Names}}')" || [ -n "$remaining" ]; then
      echo '::error::sandbox container cleanup could not verify absence' >&2
      failed=1
    else
      rm "$record"
    fi
  done
  exit "$failed"
fi
phase="${1:?named phase required}"
shift
case "$phase" in
  'runtime build/pull') seconds="${WAR_TRUSTED_BUILD_SECONDS:-900}"; maximum=900 ;;
  'runtime image inspection') seconds="${WAR_TRUSTED_INSPECT_SECONDS:-30}"; maximum=30 ;;
  'editor import') seconds="${WAR_TRUSTED_IMPORT_SECONDS:-600}"; maximum=600 ;;
  'sandbox execution') seconds="${WAR_TRUSTED_PROBE_SECONDS:-180}"; maximum=180 ;;
  'host cache guard build') seconds="${WAR_TRUSTED_BUILD_SECONDS:-900}"; maximum=900 ;;
  'sandbox cleanup') seconds=30; maximum=30 ;;
  'ordinary client step') seconds="${WAR_CLIENT_STEP_SECONDS:-2700}"; maximum=2700 ;;
  *) echo '::error::unknown trusted setup phase' >&2; exit 2 ;;
esac
grace="${WAR_TRUSTED_TERMINATION_SECONDS:-5}"
for value in "$seconds" "$grace"; do
  if [[ ! "$value" =~ ^[1-9][0-9]{0,3}$ ]]; then
    echo "::error::$phase has an invalid deadline" >&2
    exit 2
  fi
done
if [ "$seconds" -gt "$maximum" ] || [ "$grace" -gt 5 ]; then
  echo "::error::$phase deadline exceeds the reviewed budget" >&2
  exit 2
fi
if ! timeout --version 2>/dev/null | grep -q 'GNU coreutils'; then
  echo "::error::$phase could not execute: GNU coreutils timeout is required" >&2
  exit 2
fi
pid=""
phase_state="$(mktemp -d "${TMPDIR:-/tmp}/trusted-regression-phase.XXXXXX")"
verdict_record="$phase_state/verdict"
launching=true
cancel_pending=false
# Release phase state only after a readable direct-child verdict confirms its join.
acknowledge_child() {
  local verdict
  if [ ! -f "$verdict_record" ] || ! verdict="$(cat "$verdict_record")" ||
    [[ ! $verdict =~ ^[0-9]{1,3}$ ]] || [ "$verdict" -gt 255 ]; then
    echo '::error::phase child join is unverified; private state retained' >&2
    return 2
  fi
  case "$verdict" in 2|137|143)
    echo '::error::phase child cleanup refused or supervisor exited by signal; private state retained' >&2
    return 2;; esac
  rm -rf "$phase_state"
}
# shellcheck disable=SC2329 # Invoked by the signal trap.
# Retire the captured phase group and preserve unacknowledged private state.
cancel() {
  cancel_pending=true
  # A signal can arrive after spawn but before $! is published to the owner.
  if [ "$launching" = true ]; then return; fi
  trap '' INT TERM
  if [ -n "$pid" ]; then
    war_retire_group "$pid" "$grace" || exit 2
    wait "$pid" 2>/dev/null || true
  fi
  acknowledge_child || exit 2
  echo "::error::$phase cancelled" >&2
  exit 130
}
trap 'trap ":" INT TERM; cancel' INT TERM
set -m
timeout --kill-after="${grace}s" "${seconds}s" bash "$(dirname "${BASH_SOURCE[0]}")/trusted-phase-command.sh" "$verdict_record" "$@" &
pid=$!
set +m
launching=false
if [ "$cancel_pending" = true ]; then cancel; fi
status=0
wait "$pid" || status=$?
# Even a successful command cannot retain invocation-owned background children.
war_retire_group "$pid" "$grace" || exit 2
pid=""
trap - INT TERM
if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
  echo "::error::$phase timed out (${seconds}s; termination grace ${grace}s)" >&2
fi
acknowledge_child || exit 2
exit "$status"
