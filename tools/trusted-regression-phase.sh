#!/usr/bin/env bash
# Bound reviewed host phases; GNU timeout owns and terminates the child group.
set -euo pipefail
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
# shellcheck disable=SC2329 # Invoked by the signal trap.
cancel() {
  trap - INT TERM
  if [ -n "$pid" ]; then
    kill -TERM -- "-$pid" 2>/dev/null || true
    sleep "$grace"
    kill -KILL -- "-$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  echo "::error::$phase cancelled" >&2
  exit 130
}
trap cancel INT TERM
set -m
timeout --kill-after="${grace}s" "${seconds}s" "$@" &
pid=$!
set +m
status=0
wait "$pid" || status=$?
# Even a successful command cannot retain invocation-owned background children.
kill -TERM -- "-$pid" 2>/dev/null || true
kill -KILL -- "-$pid" 2>/dev/null || true
pid=""
trap - INT TERM
if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
  echo "::error::$phase timed out (${seconds}s; termination grace ${grace}s)" >&2
fi
exit "$status"
