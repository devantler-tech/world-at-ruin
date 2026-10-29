#!/usr/bin/env bash
# Publish the direct child verdict after join. GNU timeout can replace a
# cancellation status with 124, so its exit alone cannot carry cleanup refusal.
set -euo pipefail
record="${1:?private verdict record required}"
shift
# Bash gives asynchronous children ignored SIGINT. Reset it before exec while
# preserving the enclosing process group; otherwise nested INT controls hang.
signal_env=""
for candidate in env gnuenv genv; do
  if version="$("$candidate" --version 2>/dev/null)" && [[ $version == *'GNU coreutils'* ]]; then signal_env="$candidate"; break; fi
done
if [ -z "$signal_env" ]; then echo '::error::phase child requires GNU coreutils env for normal signals' >&2; exit 2; fi
cancelled=false
# shellcheck disable=SC2329 # The signal trap invokes this during the launch/wait lifecycle.
# Latch a launch-window signal until the direct child's handle is captured.
mark_cancel() {
  cancelled=true
}
trap 'trap ":" INT TERM; mark_cancel' INT TERM
"$signal_env" --default-signal=INT,TERM "$@" &
child=$!
# The phase owner signals the entire group, including the child. Keep this
# join immune to those signals: an interrupted Bash wait can cache 143 even
# when the native child acknowledged TERM and exited zero. The owner still
# escalates to KILL within its bound if the child does not retire.
trap '' INT TERM
if [ "$cancelled" = true ]; then kill -TERM "$child" 2>/dev/null || true; fi
status=0
wait "$child" || status=$?
printf '%s\n' "$status" > "$record"
exit "$status"
