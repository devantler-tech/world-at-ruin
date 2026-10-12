#!/usr/bin/env bash
# Observe terminal members before releasing invocation-private state. A zombie
# has acknowledged exit; its reaper may be outside this process group.
# Initialize the caller's launch, cancellation and saved-exit state.
war_cancel_init() {
  launching="${1:-false}"
  cancel_pending=false
  cleanup_started=false
  # shellcheck disable=SC2034 # The caller's EXIT trap consumes this saved status.
  cleanup_status=0
}
# Defer cancellation until child handles are published, then enter cleanup once.
war_request_cancel() {
  # shellcheck disable=SC2034 # Callers check this deferred intent after publishing handles.
  cancel_pending=true
  if [ "$cleanup_started" = true ]; then return; fi
  if [ "$launching" != true ]; then trap '' INT TERM; exit 130; fi
}
# Return 0 for live group members, 1 for terminal members, or 2 for unknown inspection.
war_group_active() {
  local snapshot
  snapshot="$(ps -axo pgid=,stat=)" || return 2
  awk -v group="$1" '
    NF != 2 || $1 !~ /^[0-9]+$/ || $2 !~ /^[A-Za-z?<>+]+$/ {bad=1}
    $1 == group && $2 !~ /^Z/ {live=1}
    END {if (NR == 0 || bad) exit 2; exit live ? 0 : 1}
  ' <<< "$snapshot"
}
# Send TERM with bounded grace, escalate to KILL and require observed group retirement.
war_retire_group() {
  local group="$1" grace="$2" attempt rc=0 failed=0
  [[ $group =~ ^[1-9][0-9]*$ && $grace =~ ^[1-5]$ ]] || return 2
  kill -TERM -- "-$group" 2>/dev/null || true
  for ((attempt=0; attempt<grace*10; attempt++)); do
    rc=0
    war_group_active "$group" || rc=$?
    [[ $rc == 1 ]] && return 0
    if [[ $rc != 0 ]]; then failed=1; break; fi
    sleep 0.1
  done
  kill -KILL -- "-$group" 2>/dev/null || true
  for ((attempt=0; attempt<20; attempt++)); do
    rc=0
    war_group_active "$group" || rc=$?
    if [[ $rc == 1 && $failed == 0 ]]; then return 0; fi
    if [[ $rc != 0 && $rc != 1 ]]; then break; fi
    sleep 0.1
  done
  echo '::error::owned process-group exit is unverified; cleanup ownership retained' >&2
  return 2
}
