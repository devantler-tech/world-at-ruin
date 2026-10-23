#!/usr/bin/env bash
# Each controller owns its bounded child handles and cancels them before cleanup.
trusted_active_pid=""
trusted_parallel_pids=()
trusted_cleanup_uncertain=0
trusted_launching=false
trusted_cancel_pending=false
trusted_cleanup_started=false
# shellcheck disable=SC2034 # EXIT traps and cleanup functions in sourced callers use this.
trusted_cleanup_status=0
# Latch controller cancellation until the active child's handle is available.
trusted_request_cancel() {
  trusted_cancel_pending=true
  if [ "$trusted_cleanup_started" = true ]; then return; fi
  if [ "$trusted_launching" != true ]; then exit 130; fi
}
# Run one child asynchronously and preserve both its status and any cleanup refusal.
trusted_wait() {
  trusted_launching=true
  "$@" &
  trusted_active_pid=$!
  trusted_launching=false
  if [ "$trusted_cancel_pending" = true ]; then exit 130; fi
  local status=0
  wait "$trusted_active_pid" || status=$?
  case "$status" in 2 | 127 | 137 | 143) trusted_cleanup_uncertain=1 ;; esac
  trusted_active_pid=""
  return "$status"
}
# Stop only this controller's child, allowing its supervisor to retire descendants.
trusted_stop_child() {
  local pid status tries=0 live
  local pids=("$trusted_active_pid" ${trusted_parallel_pids[@]+"${trusted_parallel_pids[@]}"})
  # Broadcast before waiting: each child retains the same eight-second join
  # budget, and siblings cannot multiply the controller's cancellation bound.
  for pid in "${pids[@]}"; do
    [ -n "$pid" ] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done
  if [ "${#pids[@]}" -gt 0 ]; then
    # Preserve five seconds of TERM grace, two seconds of exit observation
    # and one second for scheduling. Forced supervisor exit cannot acknowledge
    # retirement of a separate engine group.
    # An acknowledged exit can release the controller before that upper bound.
    while [ "$tries" -lt 80 ]; do
      live=false
      for pid in "${pids[@]}"; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then live=true; fi
      done
      [ "$live" = true ] || break
      sleep 0.1
      tries=$((tries + 1))
    done
    for pid in "${pids[@]}"; do
      [ -n "$pid" ] || continue
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
        trusted_cleanup_uncertain=1
      fi
      status=0
      wait "$pid" 2>/dev/null || status=$?
      case "$status" in 2 | 127 | 137 | 143) trusted_cleanup_uncertain=1 ;; esac
    done
    trusted_active_pid=""
    trusted_parallel_pids=()
  fi
  if [ "$trusted_cleanup_uncertain" -ne 0 ]; then
    echo '::error::child cleanup acknowledgment is missing; private state retained' >&2
    return 2
  fi
}
# shellcheck disable=SC2329 # Sourced controllers invoke this through their EXIT traps.
# Stop the owned child, remove recorded containers, and retain state on uncertain cleanup.
trusted_cleanup_controller() {
  local state="$1" phase="$2" records="$3" result=$trusted_cleanup_status
  trap - EXIT
  # Cleanup launches a bounded phase; its child must inherit normal TERM.
  trap ':' INT TERM
  trusted_stop_child || result=2
  if ! bash "$phase" "sandbox cleanup" bash "$phase" --cleanup-containers "$records"; then result=2; fi
  if [ "$trusted_cleanup_uncertain" -eq 0 ] && [ "$result" -ne 2 ]; then rm -rf "$state"; fi
  exit "$result"
}
