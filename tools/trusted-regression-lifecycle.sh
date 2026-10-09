#!/usr/bin/env bash
# Each controller owns one active child and forwards cancellation before cleanup.
trusted_active_pid=""
# Run one child asynchronously so controller cancellation can interrupt its wait.
trusted_wait() {
  "$@" &
  trusted_active_pid=$!
  local status=0
  wait "$trusted_active_pid" || status=$?
  trusted_active_pid=""
  return "$status"
}
# Stop only this controller's child, allowing its supervisor to retire descendants.
trusted_stop_child() {
  if [ -n "$trusted_active_pid" ]; then
    kill -TERM "$trusted_active_pid" 2>/dev/null || true
    # Preserve the full five-second phase grace plus one second for scheduling.
    # An acknowledged exit can release the controller before that upper bound.
    local tries=0
    while kill -0 "$trusted_active_pid" 2>/dev/null && [ "$tries" -lt 60 ]; do
      sleep 0.1
      tries=$((tries + 1))
    done
    if kill -0 "$trusted_active_pid" 2>/dev/null; then
      kill -KILL "$trusted_active_pid" 2>/dev/null || true
    fi
    wait "$trusted_active_pid" 2>/dev/null || true
    trusted_active_pid=""
  fi
}
