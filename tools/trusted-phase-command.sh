#!/usr/bin/env bash
# Publish the direct child verdict after join. GNU timeout can replace a
# cancellation status with 124, so its exit alone cannot carry cleanup refusal.
set -euo pipefail
record="${1:?private verdict record required}"
shift
# Bash gives asynchronous children ignored SIGINT. Reset it before exec while
# preserving the enclosing process group; otherwise nested INT controls hang.
signal_env=""
for candidate in env genv; do
  if "$candidate" --version 2>/dev/null | grep -q 'GNU coreutils'; then signal_env="$candidate"; break; fi
done
if [ -z "$signal_env" ]; then echo '::error::phase child requires GNU coreutils env for normal signals' >&2; exit 2; fi
cancelled=false
launching=true
# shellcheck disable=SC2329 # The signal trap invokes this during the launch/wait lifecycle.
mark_cancel() {
  cancelled=true
  if [ "$launching" != true ]; then trap '' INT TERM; fi
}
trap 'trap ":" INT TERM; mark_cancel' INT TERM
"$signal_env" --default-signal=INT,TERM "$@" &
child=$!
launching=false
if [ "$cancelled" = true ]; then trap '' INT TERM; kill -TERM "$child" 2>/dev/null || true; fi
status=0
wait "$child" || status=$?
if [ "$cancelled" = true ]; then
  status=0
  wait "$child" || status=$?
fi
printf '%s\n' "$status" > "$record"
exit "$status"
