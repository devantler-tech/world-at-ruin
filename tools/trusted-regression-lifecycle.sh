#!/usr/bin/env bash
# Each controller owns one active child and forwards cancellation before cleanup.
trusted_active_pid=""
trusted_wait() {
  "$@" &
  trusted_active_pid=$!
  local status=0
  wait "$trusted_active_pid" || status=$?
  trusted_active_pid=""
  return "$status"
}
trusted_stop_child() {
  if [ -n "$trusted_active_pid" ]; then
    kill -TERM "$trusted_active_pid" 2>/dev/null || true
    # The phase supervisor gets its full five-second termination grace.
    sleep 6
    kill -KILL "$trusted_active_pid" 2>/dev/null || true
    wait "$trusted_active_pid" 2>/dev/null || true
    trusted_active_pid=""
  fi
}
