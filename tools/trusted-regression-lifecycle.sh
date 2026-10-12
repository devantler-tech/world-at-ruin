#!/usr/bin/env bash
# Each controller owns one active child and forwards cancellation before cleanup.
trusted_active_pid=""
trusted_cleanup_uncertain=0
trusted_launching=false
trusted_cancel_pending=false
trusted_cleanup_started=false
# shellcheck disable=SC2034 # EXIT traps and cleanup functions in sourced callers use this.
trusted_cleanup_status=0
trusted_request_cancel() {
  trusted_cancel_pending=true
  if [ "$trusted_cleanup_started" = true ]; then return; fi
  if [ "$trusted_launching" != true ]; then exit 130; fi
}
# Run one child asynchronously so controller cancellation can interrupt its wait.
trusted_wait() {
  trusted_launching=true
  "$@" &
  trusted_active_pid=$!
  trusted_launching=false
  if [ "$trusted_cancel_pending" = true ]; then exit 130; fi
  local status=0
  wait "$trusted_active_pid" || status=$?
  case "$status" in 2|137|143) trusted_cleanup_uncertain=1;; esac
  trusted_active_pid=""
  return "$status"
}
# Stop only this controller's child, allowing its supervisor to retire descendants.
trusted_stop_child() {
  if [ -n "$trusted_active_pid" ]; then
    kill -TERM "$trusted_active_pid" 2>/dev/null || true
    # Preserve five seconds of TERM grace, two seconds of exit observation
    # and one second for scheduling. Forced supervisor exit cannot acknowledge
    # retirement of a separate engine group.
    # An acknowledged exit can release the controller before that upper bound.
    local tries=0
    while kill -0 "$trusted_active_pid" 2>/dev/null && [ "$tries" -lt 80 ]; do
      sleep 0.1
      tries=$((tries + 1))
    done
    if kill -0 "$trusted_active_pid" 2>/dev/null; then
      kill -KILL "$trusted_active_pid" 2>/dev/null || true
      trusted_cleanup_uncertain=1
    fi
    local status=0
    wait "$trusted_active_pid" 2>/dev/null || status=$?
    case "$status" in 2|137|143) trusted_cleanup_uncertain=1;; esac
    trusted_active_pid=""
  fi
  if [ "$trusted_cleanup_uncertain" -ne 0 ]; then
    echo '::error::child cleanup acknowledgment is missing; private state retained' >&2
    return 2
  fi
}
