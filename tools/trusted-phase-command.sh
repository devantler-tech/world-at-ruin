#!/usr/bin/env bash
# Publish the direct child verdict after join. GNU timeout can replace a
# cancellation status with 124, so its exit alone cannot carry cleanup refusal.
set -euo pipefail
record="${1:?private verdict record required}"
shift
cancelled=false
trap 'cancelled=true; trap ":" INT TERM' INT TERM
"$@" &
child=$!
if [ "$cancelled" = true ]; then kill -TERM "$child" 2>/dev/null || true; fi
status=0
wait "$child" || status=$?
if [ "$cancelled" = true ]; then
  status=0
  wait "$child" || status=$?
fi
printf '%s\n' "$status" > "$record"
exit "$status"
