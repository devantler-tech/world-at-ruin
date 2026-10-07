#!/usr/bin/env bash
# Shared native build/proof owner. This file declares a function and starts no process by itself.

# run_native prints diagnostics and hard-bounds one native process to at most 180 seconds.
# Controlled hang regressions may lower the budget; an override cannot increase it.
run_native() {
 local log=$1 status=0 native_pid timer_pid
 local seconds=${CONTENTPACK_NATIVE_TIMEOUT_SECONDS:-180}
 shift
 if ! [[ "$seconds" =~ ^[1-9][0-9]{0,2}$ ]] || [ "$seconds" -gt 180 ]; then
  echo 'native time budget must be between 1 and 180 seconds' >&2; return 2
 fi
 godot "$@" > "$log" 2>&1 & native_pid=$!
 (
  trap 'kill "$!" 2>/dev/null || true; wait "$!" 2>/dev/null || true; exit 0' TERM
  sleep "$seconds" > /dev/null 2>&1 &
  wait "$!"
  : > "$log.timeout"
  kill -KILL "$native_pid" 2>/dev/null || true
 ) > /dev/null 2>&1 & timer_pid=$!
 wait "$native_pid" || status=$?
 kill "$timer_pid" 2>/dev/null || true
 wait "$timer_pid" 2>/dev/null || true
 cat "$log"
 if [ -e "$log.timeout" ]; then
  echo 'native process exceeded its time budget' >&2; return 1
 fi
 if [ "$status" -ne 0 ] || grep -qE 'SCRIPT ERROR|^ERROR:' "$log"; then return 1; fi
}
